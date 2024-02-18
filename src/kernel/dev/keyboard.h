#pragma once

#include "device.h"

// TODO: Scancodes enum
typedef enum Scancode {
    NONE = 0
} Scancode;

// TODO: interface
typedef struct KeyboardInterface {
//read_scancode()
//read_ascii() special func only for ascii in case of optimization for deferent keyboards
//...
} KeyboardInterface;

// TODO
typedef struct KeyboardDevice {
   DEVICE_STRUCT_IMPL(Keyboard);
};