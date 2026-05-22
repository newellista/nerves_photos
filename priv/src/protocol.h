#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>

#define CMD_INIT           0x01
#define CMD_LOAD_IMAGE     0x02
#define CMD_FREE_SLOT      0x03
#define CMD_RENDER_FRAME   0x04
#define CMD_GET_DIMENSIONS 0x05
#define CMD_PING           0x06

#define RESP_OK            0xA0
#define RESP_ERROR         0xA1
#define RESP_IMAGE_LOADED  0xA2
#define RESP_DIMENSIONS    0xA3
#define RESP_PONG          0xA4

#define ERR_UNKNOWN_CMD    0x01
#define ERR_BAD_PAYLOAD    0x02
#define ERR_DECODE_FAILED  0x03
#define ERR_NOT_INIT       0x04
#define ERR_DISPLAY_FAILED 0x05

int read_command(uint8_t **buf);
void write_response(const uint8_t *data, uint32_t len);
void write_ok(void);
void write_error(uint8_t code, const char *msg);
void write_pong(void);

#endif
