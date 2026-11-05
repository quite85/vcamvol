# VCam Volume Panel

给 **551UK Virtual Cam** 加一个"按音量减弹面板"的触发器。

- 不改 Virtual Cam 的核心（帧替换、解码全在它自己那边）
- 只在 SpringBoard 里挂音量键 + 弹面板
- 面板两个动作：
  - **选择视频** → 发 `com.551uk.virtualcam.choose`，让 Virtual Cam 弹它自己的相册选择器
  - **禁止替换 / 恢复替换** → 直接改 `/var/mobile/Media/DCIM/vcam.plist` 的 `enabled` 并递增 `generation`

## 为什么要云端编译

SpringBoard 是 **arm64e** 进程，dylib 必须带 arm64e 切片。Windows 上的 lld 不支持 arm64e 的认证指针重定位，所以用 GitHub Actions 的 macOS runner 编。

## 构建

推送到 main 即自动构建，或手动 `workflow_dispatch`。产物在 Actions → 运行记录 → Artifacts → `vcamvol-deb`。

## 安装

1. 解压 artifact 得到 `com.local.vcamvol_1.0.0_iphoneos-arm64.deb`
2. 传到手机，Filza 点开 → 安装
3. respring（`killall -9 SpringBoard` 或 Dopamine 里的 Respring）

## 用法

按音量减 → 面板：

```
Virtual Cam
当前：已替换 / 当前：使用手机摄像头
  选择视频
  禁止替换（或 恢复替换）
  取消
```

## 调试

日志在 `/var/mobile/Library/vcamvol.log`：

```
===== vcamvol loaded (pid 1234) =====
hooked SBVolumeHardwareButton -_volumeDownButtonDown:
volume hook bound=1
poll start volume=0.50
volume down -> panel
posted com.551uk.virtualcam.choose
```

如果 `bound=0`，说明这台机器上音量键的私有类名又变了，靠 `poll start` 那条轮询兜底（音量不为 0 时有效）。
