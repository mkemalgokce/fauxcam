#include "FrameClient.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

struct faux_frame_client {
    int descriptor;
};

static const size_t kFauxMaxPayloadBytes = 256u * 1024u * 1024u;

static int faux_write_fully(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t total = 0;
    while (total < length) {
        ssize_t written = write(descriptor, cursor + total, length - total);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (written == 0) return -1;
        total += (size_t)written;
    }
    return 0;
}

static int faux_read_fully(int descriptor, void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    size_t total = 0;
    while (total < length) {
        ssize_t received = read(descriptor, cursor + total, length - total);
        if (received < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (received == 0) return -1;
        total += (size_t)received;
    }
    return 0;
}

faux_frame_client *faux_frame_client_create(void) {
    faux_frame_client *client = calloc(1, sizeof(*client));
    if (client) client->descriptor = -1;
    return client;
}

int faux_frame_client_connect(faux_frame_client *client, const char *path) {
    if (!client || !path) return -1;
    size_t pathLength = strlen(path);
    struct sockaddr_un address;
    if (pathLength + 1 > sizeof(address.sun_path)) return -1;

    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, pathLength + 1);

    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(descriptor);
        return -1;
    }
    int suppressSignalPipe = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignalPipe, sizeof(suppressSignalPipe));
    client->descriptor = descriptor;
    return 0;
}

static int faux_send_message(faux_frame_client *client, uint16_t type, const void *body, uint32_t bodyLength) {
    faux_header header;
    header.magic = FAUX_MAGIC;
    header.version = FAUX_PROTO_VERSION;
    header.type = type;
    header.bodyLen = bodyLength;
    if (faux_write_fully(client->descriptor, &header, sizeof(header)) != 0) return -1;
    if (bodyLength > 0 && faux_write_fully(client->descriptor, body, bodyLength) != 0) return -1;
    return 0;
}

int faux_frame_client_send_hello(faux_frame_client *client) {
    if (!client || client->descriptor < 0) return -1;
    faux_hello_body body;
    body.magic = FAUX_MAGIC;
    body.version = FAUX_PROTO_VERSION;
    body.reserved = 0;
    return faux_send_message(client, FAUX_MSG_HELLO, &body, sizeof(body));
}

int faux_frame_client_send_demand(faux_frame_client *client,
                                  uint32_t position, uint32_t width, uint32_t height,
                                  uint32_t fps, uint32_t pixelFormat) {
    if (!client || client->descriptor < 0) return -1;
    faux_demand_body body;
    body.position = position;
    body.width = width;
    body.height = height;
    body.fps = fps;
    body.pixelFormat = pixelFormat;
    return faux_send_message(client, FAUX_MSG_DEMAND, &body, sizeof(body));
}

int faux_frame_client_recv_frame(faux_frame_client *client, faux_received_frame *out) {
    if (!client || client->descriptor < 0 || !out) return -1;

    faux_header header;
    if (faux_read_fully(client->descriptor, &header, sizeof(header)) != 0) return -1;
    if (header.magic != FAUX_MAGIC || header.version != FAUX_PROTO_VERSION) return -1;
    if (header.type != FAUX_MSG_FRAME) return -1;
    if (header.bodyLen < sizeof(faux_frame_body)) return -1;

    faux_frame_body body;
    if (faux_read_fully(client->descriptor, &body, sizeof(body)) != 0) return -1;

    uint32_t payloadLength = body.payloadLen;
    if ((size_t)payloadLength + sizeof(faux_frame_body) != header.bodyLen) return -1;
    if (payloadLength > kFauxMaxPayloadBytes) return -1;

    uint8_t *payload = NULL;
    if (payloadLength > 0) {
        payload = malloc(payloadLength);
        if (!payload) return -1;
        if (faux_read_fully(client->descriptor, payload, payloadLength) != 0) {
            free(payload);
            return -1;
        }
    }
    out->header = body;
    out->payload = payload;
    return 0;
}

void faux_received_frame_free(faux_received_frame *frame) {
    if (frame && frame->payload) {
        free(frame->payload);
        frame->payload = NULL;
    }
}

void faux_frame_client_close(faux_frame_client *client) {
    if (client && client->descriptor >= 0) {
        close(client->descriptor);
        client->descriptor = -1;
    }
}

void faux_frame_client_destroy(faux_frame_client *client) {
    if (!client) return;
    faux_frame_client_close(client);
    free(client);
}
