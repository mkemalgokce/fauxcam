#ifndef FAUX_FRAME_CLIENT_H
#define FAUX_FRAME_CLIENT_H

#include <stdint.h>
#include "../Shared/faux_wire.h"

typedef struct faux_frame_client faux_frame_client;

typedef struct {
    faux_frame_body header;
    uint8_t *payload;
} faux_received_frame;

faux_frame_client *faux_frame_client_create(void);
int faux_frame_client_connect(faux_frame_client *client, const char *path);
int faux_frame_client_send_hello(faux_frame_client *client);
int faux_frame_client_send_demand(faux_frame_client *client,
                                  uint32_t position, uint32_t width, uint32_t height,
                                  uint32_t fps, uint32_t pixelFormat);
int faux_frame_client_recv_frame(faux_frame_client *client, faux_received_frame *out);
void faux_received_frame_free(faux_received_frame *frame);
void faux_frame_client_close(faux_frame_client *client);
void faux_frame_client_destroy(faux_frame_client *client);

#endif
