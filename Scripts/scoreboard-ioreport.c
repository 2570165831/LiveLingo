/* Read-only, unprivileged IOReport bridge. No GPU work is submitted.
 * Build with clang -O2 -Wall -Wextra -Werror -framework CoreFoundation.
 * IOReport is a private OS API: unsupported channels remain unknown in Python.
 * This file contains declarations only; no third-party implementation is used.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef CFMutableDictionaryRef (*copy_group_fn)(CFStringRef, CFStringRef,
                                               uint64_t, uint64_t, uint64_t);
typedef CFTypeRef (*subscribe_fn)(CFTypeRef, CFMutableDictionaryRef,
                                  CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*samples_fn)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*delta_fn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*string_fn)(CFDictionaryRef);
typedef uint64_t (*id_fn)(CFDictionaryRef);
typedef int64_t (*integer_fn)(CFDictionaryRef, int);
typedef int (*count_fn)(CFDictionaryRef);
typedef CFStringRef (*state_name_fn)(CFDictionaryRef, int);

static copy_group_fn copy_group;
static subscribe_fn subscribe;
static samples_fn create_samples;
static delta_fn create_delta;
static string_fn get_group, get_subgroup, get_name, get_unit;
static id_fn get_id;
static integer_fn get_integer, get_residency;
static count_fn get_format, get_state_count;
static state_name_fn get_state_name;
static volatile sig_atomic_t stopping = 0;
static mach_timebase_info_data_t timebase;

static void stop_signal(int sig) { (void)sig; stopping = 1; }
static double mono(void) {
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

static void json_string(CFStringRef value) {
    if (!value) { fputs("null", stdout); return; }
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
                                                         kCFStringEncodingUTF8) + 1;
    char *buffer = malloc((size_t)capacity);
    if (!buffer || !CFStringGetCString(value, buffer, capacity, kCFStringEncodingUTF8)) {
        free(buffer); fputs("null", stdout); return;
    }
    putchar('"');
    for (const unsigned char *p = (unsigned char *)buffer; *p; ++p) {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"'); free(buffer);
}

static bool equals(CFStringRef value, CFStringRef expected) {
    return value && CFEqual(value, expected);
}

static bool is_energy(CFDictionaryRef ch) {
    if (!equals(get_group(ch), CFSTR("Energy Model"))) return false;
    CFStringRef name = get_name(ch);
    return equals(name, CFSTR("CPU Energy")) || equals(name, CFSTR("GPU Energy")) ||
           equals(name, CFSTR("ANE")) || equals(name, CFSTR("ANE Energy"));
}

static bool is_gpu_states(CFDictionaryRef ch) {
    return equals(get_group(ch), CFSTR("GPU Stats")) &&
           equals(get_subgroup(ch), CFSTR("GPU Performance States")) &&
           equals(get_name(ch), CFSTR("GPUPH"));
}

static CFArrayRef channels(CFDictionaryRef dictionary) {
    if (!dictionary) return NULL;
    CFTypeRef array = CFDictionaryGetValue(dictionary, CFSTR("IOReportChannels"));
    return array && CFGetTypeID(array) == CFArrayGetTypeID() ? array : NULL;
}

static void descriptor(CFDictionaryRef ch) {
    printf("{\"id\":\"%016" PRIx64 "\",\"group\":", get_id(ch));
    json_string(get_group(ch)); fputs(",\"subgroup\":", stdout);
    json_string(get_subgroup(ch)); fputs(",\"name\":", stdout);
    json_string(get_name(ch)); fputs(",\"unit\":", stdout);
    json_string(get_unit(ch)); printf(",\"format\":%d}", get_format(ch));
}

static void catalogue(CFDictionaryRef dictionary) {
    CFArrayRef array = channels(dictionary);
    putchar('[');
    for (CFIndex i = 0; array && i < CFArrayGetCount(array); ++i) {
        if (i) putchar(',');
        descriptor(CFArrayGetValueAtIndex(array, i));
    }
    putchar(']');
}

static int unavailable(const char *reason) {
    printf("{\"type\":\"unavailable\",\"source\":\"ioreport\",\"reason\":\"%s\"}\n", reason);
    return 2;
}

static bool load_api(void *lib) {
#define LOAD(var, symbol) do { \
    *(void **)(&(var)) = dlsym(lib, symbol); if (!(var)) return false; \
} while (0)
    LOAD(copy_group, "IOReportCopyChannelsInGroup");
    LOAD(subscribe, "IOReportCreateSubscription");
    LOAD(create_samples, "IOReportCreateSamples");
    LOAD(create_delta, "IOReportCreateSamplesDelta");
    LOAD(get_group, "IOReportChannelGetGroup");
    LOAD(get_subgroup, "IOReportChannelGetSubGroup");
    LOAD(get_name, "IOReportChannelGetChannelName");
    LOAD(get_unit, "IOReportChannelGetUnitLabel");
    LOAD(get_id, "IOReportChannelGetChannelID");
    LOAD(get_format, "IOReportChannelGetFormat");
    LOAD(get_integer, "IOReportSimpleGetIntegerValue");
    /* GPU residency is optional; its absence must not disable energy rails. */
    *(void **)(&get_state_count) = dlsym(lib, "IOReportStateGetCount");
    *(void **)(&get_residency) = dlsym(lib, "IOReportStateGetResidency");
    *(void **)(&get_state_name) = dlsym(lib, "IOReportStateGetNameForIndex");
#undef LOAD
    return true;
}

static void print_delta(CFDictionaryRef delta, double start, double end,
                        double uncertainty, double read_seconds) {
    printf("{\"type\":\"sample\",\"source\":\"ioreport\",\"is_delta\":true,"
           "\"start_mono\":%.9f,\"end_mono\":%.9f,\"time_uncertainty_s\":%.9f,"
           "\"read_seconds\":%.9f,\"raw_channels\":[", start, end, uncertainty, read_seconds);
    CFArrayRef array = channels(delta);
    bool first = true;
    for (CFIndex i = 0; array && i < CFArrayGetCount(array); ++i) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(array, i);
        if (!is_energy(ch)) continue;
        if (!first) putchar(','); first = false;
        printf("{\"id\":\"%016" PRIx64 "\",\"group\":", get_id(ch));
        json_string(get_group(ch)); fputs(",\"name\":", stdout);
        json_string(get_name(ch)); fputs(",\"unit\":", stdout);
        json_string(get_unit(ch)); printf(",\"format\":%d,\"value\":", get_format(ch));
        /* Format 1 is a simple integer counter. Never call the simple accessor
         * on state/histogram channels or reinterpret a power value as energy. */
        if (get_format(ch) == 1) printf("%" PRId64, get_integer(ch, 0));
        else fputs("null", stdout);
        putchar('}');
    }
    fputs("],\"gpu_state_channels\":[", stdout); first = true;
    for (CFIndex i = 0; array && i < CFArrayGetCount(array); ++i) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(array, i);
        if (!is_gpu_states(ch) || get_format(ch) != 2 || !get_state_count ||
            !get_residency || !get_state_name) continue;
        if (!first) putchar(','); first = false;
        printf("{\"id\":\"%016" PRIx64 "\",\"unit\":", get_id(ch));
        json_string(get_unit(ch)); fputs(",\"states\":[", stdout);
        int n = get_state_count(ch);
        for (int k = 0; k < n; ++k) {
            if (k) putchar(','); fputs("{\"name\":", stdout);
            json_string(get_state_name(ch, k));
            printf(",\"residency\":%" PRId64 "}", get_residency(ch, k));
        }
        fputs("]}", stdout);
    }
    fputs("]}\n", stdout);
}

int main(int argc, char **argv) {
    double interval = 1.0;
    long count = 0;
    bool list_only = false;
    for (int i = 1; i < argc; ++i) {
        char *end = NULL;
        if (!strcmp(argv[i], "--list")) list_only = true;
        else if (!strcmp(argv[i], "--interval") && i + 1 < argc) {
            interval = strtod(argv[++i], &end);
            if (!end || *end || !isfinite(interval) || interval < 0.01 || interval > 3600) return 64;
        } else if (!strcmp(argv[i], "--count") && i + 1 < argc) {
            count = strtol(argv[++i], &end, 10);
            if (!end || *end || count < 0) return 64;
        } else {
            fputs("usage: scoreboard-ioreport [--list] [--interval seconds] [--count N]\n", stderr);
            return 64;
        }
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    mach_timebase_info(&timebase);
    signal(SIGTERM, stop_signal); signal(SIGINT, stop_signal);
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib || !load_api(lib)) return unavailable("api_unavailable");
    CFMutableDictionaryRef energy = copy_group(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef gpu = copy_group(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    if (list_only) {
        printf("{\"type\":\"catalogue\",\"uid\":%u,\"energy_channels\":", (unsigned)geteuid());
        catalogue(energy); fputs(",\"gpu_channels\":", stdout); catalogue(gpu); fputs("}\n", stdout);
        if (energy) CFRelease(energy); if (gpu) CFRelease(gpu); dlclose(lib); return 0;
    }
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionaryRef groups[] = {energy, gpu};
    for (int g = 0; g < 2; ++g) {
        CFArrayRef array = channels(groups[g]);
        for (CFIndex i = 0; array && i < CFArrayGetCount(array); ++i) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(array, i);
            if (is_energy(ch) || is_gpu_states(ch)) CFArrayAppendValue(selected, ch);
        }
    }
    if (!CFArrayGetCount(selected)) return unavailable("no_supported_channels");
    CFMutableDictionaryRef requested = CFDictionaryCreateMutableCopy(NULL, 0, energy ? energy : gpu);
    CFDictionarySetValue(requested, CFSTR("IOReportChannels"), selected);
    CFMutableDictionaryRef subscribed_channels = NULL;
    CFTypeRef subscription = subscribe(NULL, requested, &subscribed_channels, 0, NULL);
    if (!subscription || !subscribed_channels) return unavailable("subscription_unavailable");
    double read_start = mono();
    CFDictionaryRef previous = create_samples(subscription, subscribed_channels, NULL);
    double read_end = mono();
    if (!previous) return unavailable("initial_snapshot_unavailable");
    double previous_mono = (read_start + read_end) / 2;
    double previous_read_seconds = read_end - read_start;
    printf("{\"type\":\"ready\",\"source\":\"ioreport\",\"uid\":%u,"
           "\"clock\":\"mach_absolute_time_seconds\",\"ready_mono\":%.9f,"
           "\"initial_cumulative_snapshot_discarded\":true,\"channels\":",
           (unsigned)geteuid(), previous_mono);
    catalogue(subscribed_channels); fputs("}\n", stdout);
    long emitted = 0;
    int result_code = 0;
    while (!count || emitted < count) {
        struct timespec request = {(time_t)interval, (long)((interval - floor(interval)) * 1e9)};
        if (!stopping) {
            while (nanosleep(&request, &request) && errno == EINTR && !stopping) {}
        }
        read_start = mono();
        CFDictionaryRef current = create_samples(subscription, subscribed_channels, NULL);
        read_end = mono();
        if (!current) { unavailable("snapshot_unavailable"); result_code = 2; break; }
        double current_mono = (read_start + read_end) / 2;
        CFDictionaryRef delta = create_delta(previous, current, NULL);
        if (!delta) { CFRelease(current); unavailable("delta_unavailable"); result_code = 2; break; }
        print_delta(delta, previous_mono, current_mono,
                    (previous_read_seconds + read_end - read_start) / 2,
                    read_end - read_start);
        CFRelease(delta); CFRelease(previous); previous = current;
        previous_mono = current_mono; previous_read_seconds = read_end - read_start;
        ++emitted;
        if (stopping) break;
    }
    CFRelease(previous); CFRelease(subscription); CFRelease(subscribed_channels);
    CFRelease(requested); CFRelease(selected);
    if (energy) CFRelease(energy); if (gpu) CFRelease(gpu); dlclose(lib);
    return result_code;
}
