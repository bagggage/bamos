#include "ps2_keyboard.h"

#include "io/tty.h"
#include "io/logger.h"
#include "keyboard.h"
#include "mem.h"

// for more info see PS/2 commands
typedef enum Commands {
    SET_LED                                                 = 0xED,  // response: 0xFA (ACK) or 0xFE (Resend)
    ECHO                                                    = 0xEE,  // response: 0xEE (Echo) or 0xFE (Resend) 
    GET_OR_SET_CURRENT_SCAN_CODE                            = 0xF0,  // response: 0xFA (ACK) or 0xFE (Resend) if scan code is being set
    IDENTIFY_KEYBOARD                                       = 0xF2,  // response: 0xFA (ACK) followed by none or more ID bytes
    SET_TYPEMATIC_RATE_AND_DELAY                            = 0xF3,  // response: 0xFA (ACK) or 0xFE (Resend) 
    ENABLE_SCANNING                                         = 0xF4,  // response: 0xFA (ACK) or 0xFE (Resend) 
    DISABLE_SCANNING                                        = 0xF5,  // response: 0xFA (ACK) or 0xFE (Resend) 
    SET_DEFAULT_PARAMETERS                                  = 0xF6,  // response: 0xFA (ACK) or 0xFE (Resend) 
    SET_ALL_TO_TYPEMATIC_AND_AUTOREPEAT                     = 0xF7,  // response: 0xFA (ACK) or 0xFE (Resend) 
    SET_ALL_TO_MAKE_AND_RELEASE                             = 0xF8,  // response: 0xFA (ACK) or 0xFE (Resend) 
    SET_ALL_TO_MAKE_ONLY                                    = 0xF9,  // response: 0xFA (ACK) or 0xFE (Resend) 
    SET_ALL_TO_MAKE_TYPEMATIC_AUTOREPEAT_MAKE_AND_RELEASE   = 0xFA,  // response: 0xFA (ACK) or 0xFE (Resend)
    SET_SPECIFIC_TO_TYPEMATIC_AND_AUTOREPEAT                = 0xFB,  // response: 0xFA (ACK) or 0xFE (Resend)
    SET_SPECIFIC_TO_MAKE_AND_RELEASE                        = 0xFC,  // response: 0xFA (ACK) or 0xFE (Resend)
    SET_SPECIFIC_TO_MAKE_ONLY                               = 0xFD,  // response: 0xFA (ACK) or 0xFE (Resend)
    RESEND_LAST_BYTE                                        = 0xFE,  // response: Previously sent byte or 0xFE (Resend) 
    RESET_AND_START_SELFTEST                                = 0xFF   // response: 0xFA (ACK) or 0xFE (Resend) followed by 0xAA (self-test passed)4
} Commands;

typedef enum SpecialBytes {
    ERROR            = 0x00,
    SELF_TEST_PASSED = 0xAA,
    ECHO_RESPONSE    = 0xEE,
    ACK              = 0xFA,
    SELF_TEST_FAILD  = 0xFC,
    RESEND           = 0xFE,
} SpecialBytes;

typedef enum PS2ScanCode {
    PS2_SCAN_CODE_ESC = 0x01,
    PS2_SCAN_CODE_1 = 0x02,
    PS2_SCAN_CODE_2 = 0x03,
    PS2_SCAN_CODE_3 = 0x04,
    PS2_SCAN_CODE_4 = 0x05,
    PS2_SCAN_CODE_5 = 0x06,
    PS2_SCAN_CODE_6 = 0x07,
    PS2_SCAN_CODE_7 = 0x08,
    PS2_SCAN_CODE_8 = 0x09,
    PS2_SCAN_CODE_9 = 0x0A,
    PS2_SCAN_CODE_0 = 0x0B,
    PS2_SCAN_CODE_MINUS = 0x0C,
    PS2_SCAN_CODE_EQUAL = 0x0D,
    PS2_SCAN_CODE_BACKSPACE = 0x0E,
    PS2_SCAN_CODE_TAB = 0x0F,
    PS2_SCAN_CODE_Q = 0x10,
    PS2_SCAN_CODE_W = 0x11,
    PS2_SCAN_CODE_E = 0x12,
    PS2_SCAN_CODE_R = 0x13,
    PS2_SCAN_CODE_T = 0x14,
    PS2_SCAN_CODE_Y = 0x15,
    PS2_SCAN_CODE_U = 0x16,
    PS2_SCAN_CODE_I = 0x17,
    PS2_SCAN_CODE_O = 0x18,
    PS2_SCAN_CODE_P = 0x19,
    PS2_SCAN_CODE_LEFT_SQUARE_BRACKET = 0x1A,
    PS2_SCAN_CODE_RIGHT_SQUARE_BRACKET = 0x1B,
    PS2_SCAN_CODE_ENTER = 0x1C,
    PS2_SCAN_CODE_LEFT_CONTROL = 0x1D,
    PS2_SCAN_CODE_A = 0x1E,
    PS2_SCAN_CODE_S = 0x1F,
    PS2_SCAN_CODE_D = 0x20,
    PS2_SCAN_CODE_F = 0x21,
    PS2_SCAN_CODE_G = 0x22,
    PS2_SCAN_CODE_H = 0x23,
    PS2_SCAN_CODE_J = 0x24,
    PS2_SCAN_CODE_K = 0x25,
    PS2_SCAN_CODE_L = 0x26,
    PS2_SCAN_CODE_SEMICOLON = 0x27,
    PS2_SCAN_CODE_SINGLE_QUOTE = 0x28,
    PS2_SCAN_CODE_BACK_TICK = 0x29,
    PS2_SCAN_CODE_LEFT_SHIFT = 0x2A,
    PS2_SCAN_CODE_BACKSLASH = 0x2B,
    PS2_SCAN_CODE_Z = 0x2C,
    PS2_SCAN_CODE_X = 0x2D,
    PS2_SCAN_CODE_C = 0x2E,
    PS2_SCAN_CODE_V = 0x2F,
    PS2_SCAN_CODE_B = 0x30,
    PS2_SCAN_CODE_N = 0x31,
    PS2_SCAN_CODE_M = 0x32,
    PS2_SCAN_CODE_COMMA = 0x33,
    PS2_SCAN_CODE_PERIOD = 0x34,
    PS2_SCAN_CODE_SLASH = 0x35,
    PS2_SCAN_CODE_RIGHT_SHIFT = 0x36,
    PS2_SCAN_CODE_KEYPAD_ASTERISK = 0x37,
    PS2_SCAN_CODE_LEFT_ALT = 0x38,
    PS2_SCAN_CODE_SPACE = 0x39,
    PS2_SCAN_CODE_CAPSLOCK = 0x3A,
    PS2_SCAN_CODE_F1 = 0x3B,
    PS2_SCAN_CODE_F2 = 0x3C,
    PS2_SCAN_CODE_F3 = 0x3D,
    PS2_SCAN_CODE_F4 = 0x3E,
    PS2_SCAN_CODE_F5 = 0x3F,
    PS2_SCAN_CODE_F6 = 0x40,
    PS2_SCAN_CODE_F7 = 0x41,
    PS2_SCAN_CODE_F8 = 0x42,
    PS2_SCAN_CODE_F9 = 0x43,
    PS2_SCAN_CODE_F10 = 0x44,
    PS2_SCAN_CODE_NUMLOCK = 0x45,
    PS2_SCAN_CODE_SCROLLLOCK = 0x46,
    PS2_SCAN_CODE_KEYPAD_7 = 0x47,
    PS2_SCAN_CODE_KEYPAD_8 = 0x48,
    PS2_SCAN_CODE_KEYPAD_9 = 0x49,
    PS2_SCAN_CODE_KEYPAD_MINUS = 0x4A,
    PS2_SCAN_CODE_KEYPAD_4 = 0x4B,
    PS2_SCAN_CODE_KEYPAD_5 = 0x4C,
    PS2_SCAN_CODE_KEYPAD_6 = 0x4D,
    PS2_SCAN_CODE_KEYPAD_PLUS = 0x4E,
    PS2_SCAN_CODE_KEYPAD_1 = 0x4F,
    PS2_SCAN_CODE_KEYPAD_2 = 0x50,
    PS2_SCAN_CODE_KEYPAD_3 = 0x51,
    PS2_SCAN_CODE_KEYPAD_0 = 0x52,
    PS2_SCAN_CODE_KEYPAD_PERIOD = 0x53,
    PS2_SCAN_CODE_F11 = 0x57,
    PS2_SCAN_CODE_F12 = 0x58,
    PS2_SCAN_CODE_RELEASE_PREFIX = 0x80,

    PS2_SCAN_CODE_ESC_RELEASE = 0x81,
    PS2_SCAN_CODE_1_RELEASE = 0x82,
    PS2_SCAN_CODE_2_RELEASE = 0x83,
    PS2_SCAN_CODE_3_RELEASE = 0x84,
    PS2_SCAN_CODE_4_RELEASE = 0x85,
    PS2_SCAN_CODE_5_RELEASE = 0x86,
    PS2_SCAN_CODE_6_RELEASE = 0x87,
    PS2_SCAN_CODE_7_RELEASE = 0x88,
    PS2_SCAN_CODE_8_RELEASE = 0x89,
    PS2_SCAN_CODE_9_RELEASE = 0x8A,
    PS2_SCAN_CODE_0_RELEASE = 0x8B,
    PS2_SCAN_CODE_MINUS_RELEASE = 0x8C,
    PS2_SCAN_CODE_EQUAL_RELEASE = 0x8D,
    PS2_SCAN_CODE_BACKSPACE_RELEASE = 0x8E,
    PS2_SCAN_CODE_TAB_RELEASE = 0x8F,
    PS2_SCAN_CODE_Q_RELEASE = 0x90,
    PS2_SCAN_CODE_W_RELEASE = 0x91,
    PS2_SCAN_CODE_E_RELEASE = 0x92,
    PS2_SCAN_CODE_R_RELEASE = 0x93,
    PS2_SCAN_CODE_T_RELEASE = 0x94,
    PS2_SCAN_CODE_Y_RELEASE = 0x95,
    PS2_SCAN_CODE_U_RELEASE = 0x96,
    PS2_SCAN_CODE_I_RELEASE = 0x97,
    PS2_SCAN_CODE_O_RELEASE = 0x98,
    PS2_SCAN_CODE_P_RELEASE = 0x99,
    PS2_SCAN_CODE_LEFT_SQUARE_BRACKET_RELEASE = 0x9A,
    PS2_SCAN_CODE_RIGHT_SQUARE_BRACKET_RELEASE = 0x9B,
    PS2_SCAN_CODE_ENTER_RELEASE = 0x9C,
    PS2_SCAN_CODE_LEFT_CONTROL_RELEASE = 0x9D,
    PS2_SCAN_CODE_A_RELEASE = 0x9E,
    PS2_SCAN_CODE_S_RELEASE = 0x9F,
    PS2_SCAN_CODE_D_RELEASE = 0xA0,
    PS2_SCAN_CODE_F_RELEASE = 0xA1,
    PS2_SCAN_CODE_G_RELEASE = 0xA2,
    PS2_SCAN_CODE_H_RELEASE = 0xA3,
    PS2_SCAN_CODE_J_RELEASE = 0xA4,
    PS2_SCAN_CODE_K_RELEASE = 0xA5,
    PS2_SCAN_CODE_L_RELEASE = 0xA6,
    PS2_SCAN_CODE_SEMICOLON_RELEASE = 0xA7,
    PS2_SCAN_CODE_SINGLE_QUOTE_RELEASE = 0xA8,
    PS2_SCAN_CODE_BACK_TICK_RELEASE = 0xA9,
    PS2_SCAN_CODE_LEFT_SHIFT_RELEASE = 0xAA,
    PS2_SCAN_CODE_BACKSLASH_RELEASE = 0xAB,
    PS2_SCAN_CODE_Z_RELEASE = 0xAC,
    PS2_SCAN_CODE_X_RELEASE = 0xAD,
    PS2_SCAN_CODE_C_RELEASE = 0xAE,
    PS2_SCAN_CODE_V_RELEASE = 0xAF,
    PS2_SCAN_CODE_B_RELEASE = 0xB0,
    PS2_SCAN_CODE_N_RELEASE = 0xB1,
    PS2_SCAN_CODE_M_RELEASE = 0xB2,
    PS2_SCAN_CODE_COMMA_RELEASE = 0xB3,
    PS2_SCAN_CODE_PERIOD_RELEASE = 0xB4,
    PS2_SCAN_CODE_SLASH_RELEASE = 0xB5,
    PS2_SCAN_CODE_RIGHT_SHIFT_RELEASE = 0xB6,
    PS2_SCAN_CODE_KEYPAD_ASTERISK_RELEASE = 0xB7,
    PS2_SCAN_CODE_LEFT_ALT_RELEASE = 0xB8,
    PS2_SCAN_CODE_SPACE_RELEASE = 0xB9,
    PS2_SCAN_CODE_CAPSLOCK_RELEASE = 0xBA,
    PS2_SCAN_CODE_F1_RELEASE = 0xBB,
    PS2_SCAN_CODE_F2_RELEASE = 0xBC,
    PS2_SCAN_CODE_F3_RELEASE = 0xBD,
    PS2_SCAN_CODE_F4_RELEASE = 0xBE,
    PS2_SCAN_CODE_F5_RELEASE = 0xBF,
    PS2_SCAN_CODE_F6_RELEASE = 0xC0,
    PS2_SCAN_CODE_F7_RELEASE = 0xC1,
    PS2_SCAN_CODE_F8_RELEASE = 0xC2,
    PS2_SCAN_CODE_F9_RELEASE = 0xC3,
    PS2_SCAN_CODE_F10_RELEASE = 0xC4,
    PS2_SCAN_CODE_NUMLOCK_RELEASE = 0xC5,
    PS2_SCAN_CODE_SCROLLLOCK_RELEASE = 0xC6,
    PS2_SCAN_CODE_KEYPAD_7_RELEASE = 0xC7,
    PS2_SCAN_CODE_KEYPAD_8_RELEASE = 0xC8,
    PS2_SCAN_CODE_KEYPAD_9_RELEASE = 0xC9,
    PS2_SCAN_CODE_KEYPAD_MINUS_RELEASE = 0xCA,
    PS2_SCAN_CODE_KEYPAD_4_RELEASE = 0xCB,
    PS2_SCAN_CODE_KEYPAD_5_RELEASE = 0xCC,
    PS2_SCAN_CODE_KEYPAD_6_RELEASE = 0xCD,
    PS2_SCAN_CODE_KEYPAD_PLUS_RELEASE = 0xCE,
    PS2_SCAN_CODE_KEYPAD_1_RELEASE = 0xCF,
    PS2_SCAN_CODE_KEYPAD_2_RELEASE = 0xD0,
    PS2_SCAN_CODE_KEYPAD_3_RELEASE = 0xD1,
    PS2_SCAN_CODE_KEYPAD_0_RELEASE = 0xD2,
    PS2_SCAN_CODE_KEYPAD_PERIOD_RELEASE = 0xD3,
    PS2_SCAN_CODE_F11_RELEASE = 0xD7,
    PS2_SCAN_CODE_F12_RELEASE = 0xD8,

    PS2_SCAN_CODE_MULTIMEDIA_PREV_TRACK = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_NEXT_TRACK = 0xE0,
    PS2_SCAN_CODE_KEYPAD_ENTER = 0xE0,
    PS2_SCAN_CODE_RIGHT_CONTROL = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_MUTE = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_CALCULATOR = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_PLAY = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_STOP = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_VOLUME_DOWN = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_VOLUME_UP = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_HOME = 0xE0,
    PS2_SCAN_CODE_KEYPAD_SLASH = 0xE0,
    PS2_SCAN_CODE_RIGHT_ALT = 0xE0,
    PS2_SCAN_CODE_HOME = 0xE0,
    PS2_SCAN_CODE_CURSOR_UP = 0xE0,
    PS2_SCAN_CODE_PAGE_UP = 0xE0,
    PS2_SCAN_CODE_CURSOR_LEFT = 0xE0,
    PS2_SCAN_CODE_CURSOR_RIGHT = 0xE0,
    PS2_SCAN_CODE_END = 0xE0,
    PS2_SCAN_CODE_CURSOR_DOWN = 0xE0,
    PS2_SCAN_CODE_PAGE_DOWN = 0xE0,
    PS2_SCAN_CODE_INSERT = 0xE0,
    PS2_SCAN_CODE_DELETE = 0xE0,
    PS2_SCAN_CODE_LEFT_GUI = 0xE0,
    PS2_SCAN_CODE_RIGHT_GUI = 0xE0,
    PS2_SCAN_CODE_APPS = 0xE0,
    PS2_SCAN_CODE_ACPI_POWER = 0xE0,
    PS2_SCAN_CODE_ACPI_SLEEP = 0xE0,
    PS2_SCAN_CODE_ACPI_WAKE = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_SEARCH = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_FAVORITES = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_REFRESH = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_STOP = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_FORWARD = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_WWW_BACK = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_MY_COMPUTER = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_EMAIL = 0xE0,
    PS2_SCAN_CODE_MULTIMEDIA_MEDIA_SELECT = 0xE0,
    PS2_SCAN_CODE_PRINT_SCREEN = 0xE0,
    PS2_SCAN_CODE_PAUSE = 0xE1,
    PS2_SCAN_CODE_NONE = 0xFA
} PS2ScanCode;

static void wait() {
    for (size_t i = 0; i < 0xFF000000; ++i) {
        asm volatile("");
    }
}

Status init_ps2_keyboard(KeyboardDevice* keyboard_device) {
    if (keyboard_device == NULL) return KERNEL_ERROR;

    outb(PS2_DATA_PORT, SET_DEFAULT_PARAMETERS);

    uint8_t result;

    if ((result = inb(PS2_DATA_PORT)) != ACK) {
        for (size_t i = 0; i < 10; ++i) {
            outb(PS2_DATA_PORT, SET_DEFAULT_PARAMETERS);

            wait();

            if (result = inb(PS2_DATA_PORT) == ACK) goto init_interface; 
        }

        if (result != ACK) {
            error_str = "PS/2 Keyboard uninitialized successfull";
            return result == RESEND ? KERNEL_ERROR : KERNEL_PANIC;
        }
    }

init_interface:
    keyboard_device->interface.get_scan_code = &ps2_get_scan_code;

    return KERNEL_OK;
}

uint8_t ps2_get_scan_code() {
    PS2ScanCode scancode = PS2_SCAN_CODE_NONE;
    
    if (inb(PS2_STATUS_PORT) & 1) scancode = inb(PS2_DATA_PORT);

    return scancode == PS2_SCAN_CODE_NONE ? SCAN_CODE_NONE : scancode;
}
