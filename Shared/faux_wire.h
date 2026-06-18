#ifndef FAUX_WIRE_H
#define FAUX_WIRE_H

#include <stdint.h>

#define FAUX_MAGIC 0x46415558u
#define FAUX_PROTO_VERSION 1

typedef enum {
    FAUX_MSG_HELLO  = 1,
    FAUX_MSG_DEMAND = 2,
    FAUX_MSG_FRAME  = 3,
    FAUX_MSG_BYE    = 4
} faux_msg_type;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t bodyLen;
} faux_header;

// Multi-byte integers are host byte order; host and guest run on the same
// machine. Revisit with explicit byte-swapping if the protocol ever crosses
// machines of differing endianness.

#define FAUX_SOCKET_DIR "/private/tmp/com.fauxcam"

typedef enum {
    FAUX_POSITION_UNSPECIFIED = 0,
    FAUX_POSITION_BACK        = 1,
    FAUX_POSITION_FRONT       = 2
} faux_position;

typedef enum {
    FAUX_PIXEL_FORMAT_BGRA32 = 0x42475241u
} faux_pixel_format;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t reserved;
} faux_hello_body;

typedef struct __attribute__((packed)) {
    uint32_t position;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t pixelFormat;
} faux_demand_body;

typedef struct __attribute__((packed)) {
    uint32_t position;
    uint32_t seq;
    uint64_t ptsNanos;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    uint32_t payloadLen;
} faux_frame_body;

#endif
