#ifndef _INPUT_H
#define _INPUT_H

#include <stdint.h>

#define PS2_PORT 0x60

// for more info see PS/2 commands
enum Commands
{
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
    RESET_AND_START_SELFTEST                                = 0xFF  // response: 0xFA (ACK) or 0xFE (Resend) followed by 0xAA (self-test passed)4
};

enum Special_Bytes
{
    ERROR            = 0x00,
    SELF_TEST_PASSED = 0xAA,
    ECHO_RESPONSE    = 0xEE,
    ACK              = 0xFA,
    SELF_TEST_FAILD  = 0xFC & 0xFD,
    RESEND           = 0xFE,
};

uint8_t init_keyboard();
uint32_t get_scan_code();

#endif // _INPUT_H