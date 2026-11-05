TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamvol
vcamvol_FILES = Tweak.x
vcamvol_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
vcamvol_FRAMEWORKS = UIKit Foundation AVFoundation PhotosUI CoreImage CoreMedia CoreVideo
vcamvol_LIBRARIES = substrate
vcamvol_PRIVATE_FRAMEWORKS =

TOOL_NAME = vcamgrader
vcamgrader_FILES = tool/main.m
vcamgrader_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
vcamgrader_FRAMEWORKS = Foundation AVFoundation CoreImage CoreMedia CoreVideo
vcamgrader_INSTALL_PATH = /usr/libexec
vcamgrader_CODESIGN_FLAGS = -Stool/entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
