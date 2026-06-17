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

#endif
