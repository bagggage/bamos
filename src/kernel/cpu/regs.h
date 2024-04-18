#pragma once

#include "definitions.h"

#define MSR_EFER    0xC0000080
#define MSR_STAR    0xC0000081
#define MSR_LSTAR   0xC0000082
#define MSR_CSTAR   0xC0000083
#define MSR_SFMASK  0xC0000084

#define MSR_APIC_BASE 0x1B
#define MSR_APIC_BASE_BSP 0x100

typedef struct EFER {
    uint64_t syscall_ext                : 1;
    uint64_t reserved_1                 : 7;
    uint64_t long_mode_enable           : 1;
    uint64_t reserved_2                 : 1;
    uint64_t long_mode_active           : 1;
    uint64_t noexec_enable              : 1;
    uint64_t secure_vm_enable           : 1;
    uint64_t long_mode_seg_limit_enable : 1;
    uint64_t fast_fxsave_restor_enable  : 1;
    uint64_t translation_cache_ext      : 1;
    uint64_t reserved_3                 : 48;
} EFER;

typedef struct STAR {
    uint32_t syscall_eip;
    uint16_t kernel_segment_base;
    uint16_t user_segment_base;
} ATTR_PACKED STAR;

// Syscall RIP for long mode
typedef uint64_t LSTAR;

// Syscall RIP for compat. mode
typedef uint64_t CSTAR;

typedef struct IDTR64 {
    uint16_t limit;
    uint64_t base;
} ATTR_PACKED IDTR64;

static inline uint64_t cpu_get_rsp() {
    uint64_t rsp;

    asm volatile("mov %%rsp,%0":"=a"(rsp));

    return rsp;
}

static inline void cpu_set_rsp(uint64_t rsp) {
    asm volatile("mov %0,%%rsp"::"a"(rsp));
}

static inline uint64_t cpu_get_rbp() {
    uint64_t rbp;

    asm volatile("movq %%rbp,%0":"=r"(rbp));

    return rbp;
}

static inline uint64_t cpu_get_cr2() {
    uint64_t cr2;

    asm volatile("mov %%cr2,%0":"=a"(cr2));

    return cr2;
}

static inline uint64_t cpu_get_cr3() {
    uint64_t cr3;

    asm volatile("mov %%cr3,%0":"=a"(cr3));

    return cr3;
}

static inline IDTR64 cpu_get_idtr() {
    IDTR64 idtr_64;

    asm volatile("sidt %0":"=memory"(idtr_64));

    return idtr_64;
}

static inline IDTR64 cpu_set_idtr(IDTR64 idtr_64) {
    asm volatile("lidt %0"::"memory"(idtr_64));
}

static inline uint64_t cpu_get_msr(uint32_t msr) {
    uint64_t value = 0;

    asm volatile("rdmsr":"=a"(*(uint32_t*)&value),"=d"(*(((uint32_t*)&value) + 1)):"c"(msr));

    return value;
}

static inline void cpu_set_msr(uint32_t msr, uint64_t value) {
    asm volatile("wrmsr"::"a"(*(uint32_t*)&value), "d"(*(((uint32_t*)&value) + 1)), "c"(msr));
}

// Get extended feature enable register
static inline EFER cpu_get_efer() {
    uint64_t efer = cpu_get_msr(MSR_EFER);

    return *(EFER*)(void*)&efer;
}

// Set extended feature enable register
static inline void cpu_set_efer(EFER efer) {
    cpu_set_msr(MSR_EFER, *(uint64_t*)(void*)&efer);
}

static inline uint64_t cpu_get_cs() {
    uint64_t cs;

    asm volatile("mov %%cs,%0":"=a"(cs));

    return cs;
}

static inline uint64_t cpu_get_ds() {
    uint64_t ds;

    asm volatile("mov %%ds,%0":"=a"(ds));

    return ds;
}

static inline uint64_t cpu_get_ss() {
    uint64_t ss;

    asm volatile("mov %%ss,%0":"=a"(ss));

    return ss;
}

static inline uint64_t cpu_get_fs() {
    uint64_t fs;

    asm volatile("mov %%fs,%0":"=a"(fs));

    return fs;
}

static inline uint64_t cpu_get_gs() {
    uint64_t gs;

    asm volatile("mov %%gs,%0":"=a"(gs));

    return gs;
}