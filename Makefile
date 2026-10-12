TARGET := iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = cpumonitor

include $(THEOS)/makefiles/common.mk

TOOL_NAME = cpumonitor
cpumonitor_FILES = cpumonitor.m
cpumonitor_CFLAGS = -fobjc-arc
cpumonitor_FRAMEWORKS = IOKit Foundation CoreFoundation
cpumonitor_PRIVATE_FRAMEWORKS = IOKit
cpumonitor_LDFLAGS = -framework IOKit -framework Foundation -framework CoreFoundation

include $(THEOS_MAKE_PATH)/tool.mk
