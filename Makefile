TARGET := iphone:clang:latest:14.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FarmChestAuto

FarmChestAuto_FILES = FarmChestAuto.m
FarmChestAuto_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FarmChestAuto_FRAMEWORKS = UIKit CoreGraphics
FarmChestAuto_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
