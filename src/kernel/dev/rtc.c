#include "rtc.h"

#include "math.h"
#include "mem.h"

#include "logger.h"

#include "cpu/io.h"

#define CMOS_RAM 0x20

static const char* const weekday_map[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char* const month_map[] = {
    "JANUARY",
    "FEBRUARY",
    "MARCH",
    "APRIL",
    "MAY",
    "JUNE",
    "JULY",
    "AUGUST",
    "SEPTEMBER",
    "OCTOBER",
    "NOVEMBER",
    "DECEMBER"
};

typedef enum RtcPorts {
    RTC_ADDRESS_PORT = 0x70,
    RTC_DATA_PORT = 0x71
} RtcPorts;

typedef enum RtcRegisters {
    RTC_A_REGISTER = 0x0A,
    RTC_B_REGISTER = 0x0B,
    RTC_C_REGISTER = 0x0C
} RtcRegisters;

typedef enum RtcTimeRegisters {
    RTC_SECOND_REGISTER = 0x00,
    RTC_MINUTE_REGISTER = 0x02,
    RTC_HOUR_REGISTER = 0x04,
    RTC_DAY_REGISTER = 0x07,
    RTC_MONTH_REGISTER = 0x08,
    RTC_YEAR_REGISTER = 0x09
} RtcTimeRegisters;

static uint32_t is_rtc_used() {
    outb(RTC_ADDRESS_PORT, RTC_A_REGISTER);

    return (inb(RTC_DATA_PORT) & 0x80);
}

static uint8_t get_rtc_register(const uint8_t register_index) {
    outb(RTC_ADDRESS_PORT, register_index);

    return inb(RTC_DATA_PORT);
}

static void set_rtc_register(const uint8_t register_index, const uint8_t value) {
    outb(RTC_ADDRESS_PORT, register_index);
    outb(RTC_DATA_PORT, value);
}

static uint8_t get_day_of_week(uint16_t year, const uint8_t month, const uint8_t day) {
    const uint8_t month_offset[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    year -= month < 3;
    return (year + year / 4 - year / 100 + year / 400 + month_offset[month - 1] + day) % 7;
}

static void get_rtc_current_time(ClockDevice* const clock_device) {
    asm("cli");

    while (is_rtc_used());

    clock_device->date_and_time.second = get_rtc_register(RTC_SECOND_REGISTER);
    clock_device->date_and_time.minute = get_rtc_register(RTC_MINUTE_REGISTER);
    clock_device->date_and_time.hour = get_rtc_register(RTC_HOUR_REGISTER);
    clock_device->date_and_time.day = get_rtc_register(RTC_DAY_REGISTER);
    clock_device->date_and_time.month = get_rtc_register(RTC_MONTH_REGISTER);
    clock_device->date_and_time.year = get_rtc_register(RTC_YEAR_REGISTER);

    uint8_t registerB = get_rtc_register(RTC_B_REGISTER);

    // Convert BCD to decimal values if necessary
    if (!(registerB & 0x04)) {
        clock_device->date_and_time.second = bcd_to_decimal(clock_device->date_and_time.second);
        clock_device->date_and_time.minute = bcd_to_decimal(clock_device->date_and_time.minute);
        clock_device->date_and_time.day = bcd_to_decimal(clock_device->date_and_time.day);
        clock_device->date_and_time.month = bcd_to_decimal(clock_device->date_and_time.month);
        clock_device->date_and_time.year = bcd_to_decimal(clock_device->date_and_time.year);
        clock_device->date_and_time.hour = ((clock_device->date_and_time.hour & 0x0F) +
                                           (((clock_device->date_and_time.hour & 0x70) / 16) * 10)) | 
                                           (clock_device->date_and_time.hour & 0x80); // convert to bcd + save info about 12/24 hour type
    }

    // Convert 12 hour clock to 24 hour clock if necessary
    if (!(registerB & 0x02) && (clock_device->date_and_time.hour & 0x80)) {
        clock_device->date_and_time.hour = ((clock_device->date_and_time.hour & 0x7F) + 12) % 24;
    }

    clock_device->date_and_time.year += 2000;

    strcpy(clock_device->date_and_time.day_of_week, weekday_map[get_day_of_week(clock_device->date_and_time.year, 
                                                                                clock_device->date_and_time.month,
                                                                                clock_device->date_and_time.day)]);

    strcpy(clock_device->date_and_time.month_str, month_map[clock_device->date_and_time.month - 1]);

    // to prevent blocking IRQ8, just read the register C
    get_rtc_register(RTC_C_REGISTER);

    asm("sti");
}

static void set_rtc_current_time(const DateAndTime* const date_and_time) {
    if (date_and_time == NULL) return;
    if (date_and_time->day == 0 || date_and_time->day > 31 ||
        date_and_time->hour > 24 || date_and_time->minute > 59 || 
        date_and_time->month == 0 || date_and_time->month > 12 ||
        date_and_time->second > 59) return;

    uint32_t year_last_two_digits = 0;

    // because rtc stores last 2 digits of the year
    if (date_and_time->year > 99) {
        year_last_two_digits = date_and_time->year % 100;
    } else {
        year_last_two_digits = date_and_time->year;
    }

    asm("cli");

    while(is_rtc_used());

    uint8_t registerB = get_rtc_register(RTC_B_REGISTER);
    
    registerB |= (1 << 7); // disable rtc updating

    set_rtc_register(RTC_B_REGISTER, registerB);
    
    // Convert decimal to BCD values if necessary
    if (!(registerB & 0x04)) {
        set_rtc_register(RTC_SECOND_REGISTER, decimal_to_bcd(date_and_time->second));
        set_rtc_register(RTC_MINUTE_REGISTER, decimal_to_bcd(date_and_time->minute));
        set_rtc_register(RTC_DAY_REGISTER, decimal_to_bcd(date_and_time->day));
        set_rtc_register(RTC_MONTH_REGISTER, decimal_to_bcd(date_and_time->month));
        set_rtc_register(RTC_YEAR_REGISTER, decimal_to_bcd(year_last_two_digits));

        // Convert 24 hour format to 12 if necessary
        if (!(registerB & 0x02) && date_and_time->hour > 12) {
             uint32_t twelve_hour_format  = date_and_time->hour - 12;

            set_rtc_register(RTC_HOUR_REGISTER, decimal_to_bcd(twelve_hour_format ) | 0x80);
        } else {
            set_rtc_register(RTC_HOUR_REGISTER, decimal_to_bcd(date_and_time->hour));
        }
    }

    registerB &= ~(1 << 7); // enable rtc updating

    set_rtc_register(RTC_B_REGISTER, registerB);

    // to prevent blocking IRQ8, just read the register C
    get_rtc_register(RTC_C_REGISTER);

    asm("sti");
}

Status init_rtc(ClockDevice* const clock_device) {
    if (clock_device == NULL) return KERNEL_INVALID_ARGS;

    asm("cli");

    // select Status Register A, and disable NMI (by setting the 7 bit)
    outb(0x70, RTC_A_REGISTER + 0x80);
    outb(0x71, CMOS_RAM);	

    asm("sti");

    clock_device->interface.get_current_time = &get_rtc_current_time;
    clock_device->interface.set_current_time = &set_rtc_current_time;

    return KERNEL_OK;
}

