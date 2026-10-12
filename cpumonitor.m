// cpumonitor.m
// A12 / iPhone XS Max / iOS 12.3.1 jailbreak CPU & power monitor
//
// Build: theos `make package` (or `make`), run on device as root:
//   sudo cpumonitor
//
// What it reads:
//   - Per-core CPU utilization          (host_processor_info, always works)
//   - Battery voltage / current / temp  (IOKit AppleSmartBattery, stable on iOS)
//   - Whole-device power in Watts       (= |Amperage| * Voltage / 1e6, real silicon reading)
//   - CPU max nominal frequency         (sysctl hw.cpufrequency_max)
//   - Real-time P/E cluster freq        (IOReport private framework, best-effort)
//
// NOTE: iOS exposes no per-core power sensor (no RAPL). "CPU power" is therefore
// estimated from the whole-battery draw + DVFS table, never read directly.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - IOReport dynamic loading (private framework)

typedef CFTypeRef IOReportSubscriptionRef;
typedef CFTypeRef IOReportChannelRef;

static CFArrayRef  (*p_IOReportCopyChannelsInGroup)(CFStringRef group, CFStringRef subgroup, uint64_t, uint64_t, uint64_t options) = NULL;
static IOReportSubscriptionRef (*p_IOReportCreateSubscription)(void*, CFArrayRef chan, uint64_t* outFlags) = NULL;
static CFArrayRef  (*p_IOReportIterate)(IOReportSubscriptionRef sub, uint64_t* idx) = NULL;
static CFStringRef (*p_IOReportChannelGetChannelName)(IOReportChannelRef ch) = NULL;
static CFStringRef (*p_IOReportChannelGetGroup)(IOReportChannelRef ch) = NULL;
static CFStringRef (*p_IOReportChannelGetSubGroup)(IOReportChannelRef ch) = NULL;
static int64_t     (*p_IOReportChannelGetScale)(IOReportChannelRef ch) = NULL;
static CFStringRef (*p_IOReportChannelGetUnit)(IOReportChannelRef ch) = NULL;
static void        (*p_IOReportIterateReset)(IOReportSubscriptionRef sub) = NULL;

static BOOL loadIOReport(void) {
    static BOOL tried = NO;
    static BOOL ok = NO;
    if (tried) return ok;
    tried = YES;
    void* h = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_NOW);
    if (!h) h = dlopen("IOReport", RTLD_NOW);
    if (!h) return NO;
    p_IOReportCopyChannelsInGroup = (void*)dlsym(h, "IOReportCopyChannelsInGroup");
    p_IOReportCreateSubscription  = (void*)dlsym(h, "IOReportCreateSubscription");
    p_IOReportIterate             = (void*)dlsym(h, "IOReportIterate");
    p_IOReportChannelGetChannelName = (void*)dlsym(h, "IOReportChannelGetChannelName");
    p_IOReportChannelGetGroup     = (void*)dlsym(h, "IOReportChannelGetGroup");
    p_IOReportChannelGetSubGroup  = (void*)dlsym(h, "IOReportChannelGetSubGroup");
    p_IOReportChannelGetScale     = (void*)dlsym(h, "IOReportChannelGetScale");
    p_IOReportChannelGetUnit      = (void*)dlsym(h, "IOReportChannelGetUnit");
    p_IOReportIterateReset        = (void*)dlsym(h, "IOReportIterateReset");
    ok = (p_IOReportCopyChannelsInGroup && p_IOReportCreateSubscription && p_IOReportIterate);
    return ok;
}

#pragma mark - IOKit helpers

static id getIOKitProperty(io_service_t service, NSString* key) {
    id v = nil;
    CFTypeRef p = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    if (p) { v = (__bridge id)p; CFRelease(p); }
    return v;
}

static int intProp(NSDictionary* props, NSString* key, int fallback) {
    NSNumber* n = props[key];
    return n ? [n intValue] : fallback;
}

static NSDictionary* batteryProperties(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return nil;
    CFMutableDictionaryRef props = NULL;
    IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
    IOObjectRelease(svc);
    return (__bridge_transfer NSDictionary*)props;
}

#pragma mark - CPU utilization

typedef struct {
    double user, system, idle, nice;
} CoreLoad;

static NSArray<NSValue*>* cpuLoads(void) {
    natural_t numCpus = 0;
    processor_cpu_load_info_t loadInfo = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &numCpus, (processor_info_array_t*)&loadInfo, &count);
    if (kr != KERN_SUCCESS) return nil;
    NSMutableArray* arr = [NSMutableArray array];
    for (natural_t i = 0; i < numCpus; i++) {
        CoreLoad c;
        c.user   = loadInfo[i].cpu_ticks[CPU_STATE_USER];
        c.system = loadInfo[i].cpu_ticks[CPU_STATE_SYSTEM];
        c.idle   = loadInfo[i].cpu_ticks[CPU_STATE_IDLE];
        c.nice   = loadInfo[i].cpu_ticks[CPU_STATE_NICE];
        [arr addValue:[NSValue valueWithBytes:&c objCType:@encode(CoreLoad)]];
    }
    return arr;
}

static double pctBetween(NSArray<NSValue*>* prev, NSArray<NSValue*>* curr, int core) {
    if (core >= (int)prev.count || core >= (int)curr.count) return 0;
    CoreLoad a, b;
    [prev[core] getValue:&a];
    [curr[core] getValue:&b];
    double dt = (b.user+b.system+b.idle+b.nice) - (a.user+a.system+a.idle+a.nice);
    if (dt <= 0) return 0;
    double busy = (b.user+b.system+b.nice) - (a.user+a.system+a.nice);
    return busy/dt*100.0;
}

#pragma mark - sysctl helpers

static int64_t sysctlInt64(const char* name) {
    int64_t v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    return v;
}

static NSString* sysctlString(const char* name) {
    char buf[256] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

#pragma mark - IOReport CPU freq sampling

// Try to build a subscription on "CPU Stats" group and read frequency channels.
// Returns dictionary: { @"P0": MHz, @"P1": MHz, @"E0".."E3": MHz } or empty dict.
static NSDictionary* sampleCPUFrequencies(void) {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    if (!loadIOReport()) return result;

    // A12: group "CPU Stats", subgroups "P-CORE" and "E-CORE" (older iOS 12 may use "GPU" too)
    NSArray* subgroups = @[@"P-CORE", @"E-CORE", @"Per-Cluster"];
    for (NSString* sg in subgroups) {
        CFArrayRef chans = p_IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), (__bridge CFStringRef)sg, 0, 0, 0);
        if (!chans) continue;
        uint64_t flags = 0;
        IOReportSubscriptionRef sub = p_IOReportCreateSubscription(NULL, (CFArrayRef)chans, &flags);
        if (!sub) { CFRelease(chans); continue; }
        uint64_t idx = 0;
        while (true) {
            CFArrayRef samples = p_IOReportIterate(sub, &idx);
            if (!samples) break;
            // each sample is a dict with channel name + value
            for (CFTypeRef item in (NSArray*)samples) {
                if (!CFDictionaryContainsKey(item, CFSTR("IOReport Channel Name"))) continue;
                CFStringRef chName = CFDictionaryGetValue(item, CFSTR("IOReport Channel Name"));
                CFNumberRef chVal = CFDictionaryGetValue(item, CFSTR("IOReport Channel Value"));
                if (!chVal) continue;
                int64_t v = 0;
                CFNumberGetValue(chVal, kCFNumberSInt64Type, &v);
                // scale: freq channels usually report in Hz or scaled by 1e6; divide heuristically
                double mhz = (v > 100000000) ? (v/1000000.0) : (double)v;
                NSString* key = [NSString stringWithFormat:@"%@/%@", sg, (__bridge NSString*)chName];
                result[key] = @((int)round(mhz));
            }
        }
        CFRelease(sub);
        CFRelease(chans);
    }
    return result;
}

#pragma mark - main loop

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        BOOL once = (argc > 1 && strcmp(argv[1], "-1") == 0);

        NSString* machine = sysctlString("hw.machine") ?: @"?";
        NSString* model   = sysctlString("hw.model")   ?: @"?";
        int64_t maxFreqMHz = sysctlInt64("hw.cpufrequency_max") / 1000000;
        int64_t minFreqMHz = sysctlInt64("hw.cpufrequency_min") / 1000000;
        int nCpu = (int)[NSProcessInfo processInfo].activeProcessorCount;

        NSLog(@"[cpumonitor] device=%@ model=%@ logicalCores=%@ maxFreq=%lldMHz minFreq=%lldMHz",
              machine, model, @(nCpu), maxFreqMHz, minFreqMHz);

        NSArray<NSValue*>* prevLoad = cpuLoads();
        if (!prevLoad) { fprintf(stderr, "host_processor_info failed\n"); return 1; }

        while (true) {
            NSDate* t0 = [NSDate date];

            NSArray<NSValue*>* currLoad = cpuLoads();
            NSDictionary* batt = batteryProperties();
            NSDictionary* freqs = sampleCPUFrequencies();

            // Battery / whole-device power
            int voltMv   = batt ? intProp(batt, @"Voltage", 0) : 0;
            int ampMa    = batt ? intProp(batt, @"Amperage", 0) : 0;   // negative = discharging
            int battTempC10 = batt ? intProp(batt, @"Temperature", 0) : 0; // 0.1°C
            int curCap   = batt ? intProp(batt, @"CurrentCapacity", 0) : 0;
            int maxCap   = batt ? intProp(batt, @"MaxCapacity", 0) : 0;
            int designCap= batt ? intProp(batt, @"DesignCapacity", 0) : 0;
            int cycle    = batt ? intProp(batt, @"CycleCount", 0) : 0;
            NSNumber* isCharging = batt[@"IsCharging"];
            NSNumber* externalPower = batt[@"ExternalChargeCapable"];

            // Whole-device power (W). |amp| is drawn from battery.
            double drawW = fabs((double)ampMa) * (double)voltMv / 1e6;
            double battTempC = battTempC10 / 10.0;

            // Per-core busy %
            NSMutableString* coreLine = [NSMutableString string];
            for (int i = 0; i < (int)currLoad.count; i++) {
                double p = pctBetween(prevLoad, currLoad, i);
                [coreLine appendFormat:@" C%d:%5.1f%%", i, p];
            }

            // Build freq line
            NSMutableString* freqLine = [NSMutableString string];
            for (NSString* k in freqs) {
                [freqLine appendFormat:@"  %@=%@MHz", k, freqs[k]];
            }
            if (freqLine.length == 0) [freqLine appendString:@"  (IOReport not available; sysctl max=%lldMHz)", maxFreqMHz];

            // Clear screen and print
            printf("\033[2J\033[H");
            printf("=== cpumonitor  %@  (%@) ===\n", machine, model);
            printf("time: %s\n\n", [[NSDate date].description UTF8String]);

            printf("-- CPU --\n");
            printf("logical cores : %d\n", nCpu);
            printf("nominal range : %lld - %lld MHz\n", minFreqMHz, maxFreqMHz);
            printf("real-time freq:%s\n", freqLine.UTF8String);
            printf("busy %%        :%s\n\n", coreLine.UTF8String);

            printf("-- Battery / whole-device power --\n");
            printf("voltage       : %d mV\n", voltMv);
            printf("current       : %d mA  (%@)\n", ampMa,
                   ampMa < 0 ? @"discharging" : (ampMa > 0 ? @"charging" : @"idle"));
            printf("power draw    : %.2f W   <-- THIS is the real silicon power reading (whole phone)\n", drawW);
            printf("battery temp   : %.1f C\n", battTempC);
            printf("capacity      : %d / %d mAh  (design %d mAh)\n", curCap, maxCap, designCap);
            printf("cycle count   : %d\n", cycle);
            printf("isCharging    : %@\n", isCharging ? (isCharging.boolValue?@"YES":@"NO") : @"?");

            printf("\n-- notes --\n");
            printf("* CPU has no per-core power sensor on A12; 'power draw' above = whole phone.\n");
            printf("* To attribute CPU share: use busy%% * freq table * C_eff (see README).\n");
            printf("* Press Ctrl-C to exit.\n");
            fflush(stdout);

            prevLoad = currLoad;

            if (once) break;
            // Pace to ~1s
            while ([t0 timeIntervalSinceNow] > -1.0) { usleep(50000); }
        }
    }
    return 0;
}
