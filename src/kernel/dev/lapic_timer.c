#include "lapic_timer.h"

#include "assert.h"
#include "device.h"
#include "logger.h"
#include "math.h"

#include "intr/apic.h"
#include "intr/intr.h"

#define LAPIC_TIMER_INT_VECTOR 32

// Divider configuration register
typedef struct DCR {
    uint32_t divider_low    : 2;
    uint32_t reserved0      : 1;
    uint32_t divider_high   : 1;
    uint32_t reserved1      : 28;
} ATTR_PACKED DCR;

static uint8_t divider_value_table[] = {
    0b111, // 1
    0b000, // 2
    0b001, // 4
    0b010, // 8
    0b011, // 16
    0b100, // 32
    0b101, // 64
    0b110, // 128
};

static ATTR_INTRRUPT void intr_lapic_timer_handler(InterruptFrame64* frame) {
    lapic_write(LAPIC_EOI_REG, 1);
}

static void lapic_timer_set_divider(const uint32_t value) {
    kassert(value <= 128);

    const uint8_t converted_value = divider_value_table[log2(value)];
    const uint32_t dsr = lapic_read(LAPIC_DIVIDER_CONFIG_REG);

    lapic_write(LAPIC_DIVIDER_CONFIG_REG, ((converted_value & 0x3) | ((converted_value << 1) & 0x8)));
}

static uint64_t lapic_timer_get_clock_counter_impl(TimerDevice*) {
    return lapic_read(LAPIC_CURR_COUNTER_REG);
}

static void lapic_timer_set_divider_impl(TimerDevice*, const uint32_t value) {
    lapic_timer_set_divider(value > 128 ? 128 : value);
}

void configure_lapic_timer() {
    lapic_timer_set_divider(1);
    lapic_write(LAPIC_INIT_COUNTER_REG, 0);

    LVTTimerReg lvt_timer;

    lvt_timer.delivery_status = 0;
    lvt_timer.mask = 1;
    lvt_timer.timer_mode = APIC_TIMER_MODE_PERIODIC;
    lvt_timer.vector = LAPIC_TIMER_INT_VECTOR;
    lvt_timer.reserved0 = 0;
    lvt_timer.reserved1 = 0;
    lvt_timer.reserved2 = 0;

    lapic_write(LAPIC_LVT_TIMER_REG, *(uint32_t*)&lvt_timer);
}

Status init_lapic_timer(TimerDevice* dev) {
    intr_set_idt_descriptor(LAPIC_TIMER_INT_VECTOR, &intr_lapic_timer_handler, INTERRUPT_GATE_FLAGS);

    // For current cpu
    configure_lapic_timer();

    dev->common.type = DEV_TIMER;

    dev->interface.get_clock_counter = &lapic_timer_get_clock_counter_impl;
    dev->interface.set_divider = &lapic_timer_set_divider_impl;

    return KERNEL_OK;
}