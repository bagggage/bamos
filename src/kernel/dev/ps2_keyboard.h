#pragma once

#include "keyboard.h"
#include "definitions.h"

#define PS2_DATA_PORT 0x60
#define PS2_STATUS_PORT 0x64
#define PS2_COMMAND_PORT 0x64

Status init_ps2_keyboard(KeyboardDevice* keyboard_device);

uint8_t ps2_get_scan_code();