// vcamgrader —— 独立运行的调色程序（不注入任何进程，避免崩溃）
//
//   vcamgrader                    守护模式：盯着 vcam.mp4，被换掉就自动调色
//   vcamgrader 输入 输出           单次模式
//
// 原理：Virtual Cam 内部按 gamma 1.83 压暗画面（实测），这里用 CIGammaAdjust(1/1.83)
//       预先抬起来，它压完正好回到原值。

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

#define SRC   @"/var/mobile/Media/DCIM/vcam.mp4"
#define TMP   @"/var/mobile/Media/DCIM/.vcamgrader-tmp.mp4"
#define PLIST @"/var/mobile/Media/DCIM/vcam.plist"
#define STATE @"/var/mobile/Library/vcamgrader.state"
#define LOGF  @"/var/mobile/Library/vcamgrader.log"
#define GAMMA 0.5464   /* = 1 / 1.83 */

static void LOG(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOGF];
    if (!fh) {
        [line writeToFile:LOGF atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @finally { [fh closeFile]; }
    }
}

static NSString *sigOf(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!a) return nil;
    return [NSString stringWithFormat:@"%llu-%.0f", [a fileSize],
            [[a fileModificationDate] timeIntervalSince1970]];
}

static void bumpGeneration(void) {
    NSData *d = [NSData dataWithContentsOfFile:PLIST];
    if (!d) return;
    NSMutableDictionary *cfg =
        [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers
                                                   format:NULL error:nil];
    if (![cfg isKindOfClass:[NSMutableDictionary class]]) return;
    NSInteger gen = [cfg[@"generation"] integerValue] + 1;
    cfg[@"generation"] = @(gen);
    cfg[@"enabled"] = @YES;
    cfg[@"masterEnabled"] = @YES;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:cfg
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0 error:nil];
    if (out) {
        [out writeToFile:PLIST atomically:YES];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = @{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile"};
        [fm setAttributes:attr ofItemAtPath:PLIST error:nil];
        LOG(@"generation -> %ld", (long)gen);
    }
}

// 同步转码（守护进程里用，不着急）
static BOOL grade(NSString *src, NSString *dst) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
    if ([[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0) {
        LOG(@"没有视频轨，跳过");
        return NO;
    }
    AVMutableVideoComposition *comp =
        [AVMutableVideoComposition videoCompositionWithAsset:asset
                                   applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *req) {
        CIImage *img = req.sourceImage;
        @try {
            CIFilter *g = [CIFilter filterWithName:@"CIGammaAdjust"];
            [g setValue:@(GAMMA) forKey:@"inputPower"];
            [g setValue:img forKey:kCIInputImageKey];
            if (g.outputImage) img = g.outputImage;
        } @catch (NSException *e) {}
        [req finishWithImage:img context:nil];
    }];
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:asset
                                                             presetName:AVAssetExportPresetHighestQuality];
    if (!ex) { LOG(@"无法创建导出会话"); return NO; }
    ex.videoComposition = comp;
    ex.outputURL = [NSURL fileURLWithPath:dst];
    ex.outputFileType = AVFileTypeMPEG4;
    ex.shouldOptimizeForNetworkUse = YES;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (ex.status != AVAssetExportSessionStatusCompleted) {
        LOG(@"导出失败 status=%ld err=%@", (long)ex.status, ex.error);
        [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:src error:NULL];
    NSError *err = nil;
    if (![fm moveItemAtPath:dst toPath:src error:&err]) {
        LOG(@"替换失败 %@", err);
        return NO;
    }
    [fm setAttributes:@{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile"}
         ofItemAtPath:src error:nil];
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL watch = YES;
        NSString *in = nil, *out = nil;
        if (argc >= 3) {
            watch = NO;
            in = [NSString stringWithUTF8String:argv[1]];
            out = [NSString stringWithUTF8String:argv[2]];
        }

        if (!watch) {
            BOOL ok = grade(in, out);
            printf("%s\n", ok ? "ok" : "fail");
            return ok ? 0 : 1;
        }

        LOG(@"grader started (pid=%d)", getpid());
        NSString *saved = [NSString stringWithContentsOfFile:STATE encoding:NSUTF8StringEncoding error:nil];
        NSString *cur = sigOf(SRC);
        if (!saved && cur) {
            [cur writeToFile:STATE atomically:YES encoding:NSUTF8StringEncoding error:nil];
            saved = cur;
        }
        LOG(@"初始签名=%@", saved);

        while (YES) {
            @autoreleasepool {
                NSString *now = sigOf(SRC);
                NSString *last = [NSString stringWithContentsOfFile:STATE
                                                           encoding:NSUTF8StringEncoding error:nil];
                if (now && ![now isEqualToString:(last ?: @"")]) {
                    [NSThread sleepForTimeInterval:3.0];
                    NSString *check = sigOf(SRC);
                    if ([check isEqualToString:now]) {
                        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:SRC error:nil];
                        unsigned long long size = [a fileSize];
                        if (size > 20000) {
                            LOG(@"检测到新视频 %llu bytes，开始调色", size);
                            if (grade(SRC, TMP)) {
                                bumpGeneration();
                                LOG(@"调色完成");
                            }
                        } else {
                            LOG(@"文件太小 %llu，跳过", size);
                        }
                        NSString *after = sigOf(SRC);
                        [after writeToFile:STATE atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    }
                }
                [NSThread sleepForTimeInterval:2.0];
            }
        }
    }
    return 0;
}
