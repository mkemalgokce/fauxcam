#ifndef FAUX_CONFIG_H
#define FAUX_CONFIG_H

#include <stdint.h>
#include <stdlib.h>

/// Camera geometry shared by the device-format swizzle and the frame pump, so the
/// advertised format always matches the delivered frames. Overridable per launch via
/// FAUXCAM_WIDTH / FAUXCAM_HEIGHT / FAUXCAM_FPS (e.g. SIMCTL_CHILD_FAUXCAM_WIDTH=1920).

static inline int32_t faux_config_int(const char *name, int32_t fallback, int32_t minValue, int32_t maxValue) {
    const char *value = getenv(name);
    if (!value || value[0] == '\0') return fallback;
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || parsed < (long)minValue || parsed > (long)maxValue) return fallback;
    return (int32_t)parsed;
}

static inline int32_t faux_config_width(void)  { return faux_config_int("FAUXCAM_WIDTH",  1280, 16, 8192); }
static inline int32_t faux_config_height(void) { return faux_config_int("FAUXCAM_HEIGHT", 720,  16, 8192); }
static inline int32_t faux_config_fps(void)    { return faux_config_int("FAUXCAM_FPS",    30,   1,  120); }

#endif
