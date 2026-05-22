#include "protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>

int read_command(uint8_t **buf) {
    uint8_t len_buf[4];
    ssize_t n;
    size_t got = 0;

    while (got < 4) {
        n = read(0, len_buf + got, 4 - got);
        if (n <= 0) return -1;
        got += n;
    }

    uint32_t len;
    memcpy(&len, len_buf, 4);
    len = ntohl(len);

    if (len == 0) {
        *buf = NULL;
        return 0;
    }

    *buf = malloc(len);
    if (!*buf) return -1;

    got = 0;
    while (got < len) {
        n = read(0, *buf + got, len - got);
        if (n <= 0) {
            free(*buf);
            *buf = NULL;
            return -1;
        }
        got += n;
    }

    return (int)len;
}

void write_response(const uint8_t *data, uint32_t len) {
    uint32_t net_len = htonl(len);
    write(1, &net_len, 4);
    if (len > 0) write(1, data, len);
}

void write_ok(void) {
    uint8_t buf[1] = { RESP_OK };
    write_response(buf, 1);
}

void write_error(uint8_t code, const char *msg) {
    size_t msg_len = msg ? strlen(msg) : 0;
    if (msg_len > 255) msg_len = 255;
    uint8_t buf[3 + 255];
    buf[0] = RESP_ERROR;
    buf[1] = code;
    buf[2] = (uint8_t)msg_len;
    if (msg_len > 0) memcpy(buf + 3, msg, msg_len);
    write_response(buf, 3 + msg_len);
}

void write_pong(void) {
    uint8_t buf[1] = { RESP_PONG };
    write_response(buf, 1);
}
