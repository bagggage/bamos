#pragma once

#include "definitions.h"

#include <cpuid.h>

#define CPUID_GET_FEATURE 1

typedef enum CpuFeature {
    CPUID_FEAT_ECX_SSE3         = (1 << 0),  // streaming SIMD extensions 3 (SSE3)
    CPUID_FEAT_ECX_MONITOR      = (1 << 3),  // monitor/mwait
    CPUID_FEAT_ECX_DS_CPL       = (1 << 4),  // CPL qualified debug store
    CPUID_FEAT_ECX_VMX          = (1 << 5),  // virtual machine extensions
    CPUID_FEAT_ECX_SMX          = (1 << 6),  // safer mode extensions
    CPUID_FEAT_ECX_EST          = (1 << 7),  // enhanced Intel SpeedStep(R) technology
    CPUID_FEAT_ECX_TM2          = (1 << 8),  // thermal monitor 2
    CPUID_FEAT_ECX_SSSE3        = (1 << 9),  // supplemental streaming SIMD extensions 3 (SSSSE3)
    CPUID_FEAT_ECX_CNXT_ID      = (1 << 10), // L1 context ID
    CPUID_FEAT_ECX_CMPXCHG16B   = (1 << 13), // cmpxchg16b available (obviously)
    CPUID_FEAT_ECX_xTPR_UPDATE  = (1 << 14), // xTPR update control
    CPUID_FEAT_ECX_PDCM         = (1 << 15), // performance and debug capability
    CPUID_FEAT_ECX_DCA          = (1 << 18), // memory-mapped device prefetching
    CPUID_FEAT_ECX_SSE4_1       = (1 << 19), // SSE4.1
    CPUID_FEAT_ECX_SSE4_2       = (1 << 20), // SSE4.2
    CPUID_FEAT_ECX_x2APIC       = (1 << 21), // x2APIC available
    CPUID_FEAT_ECX_MOVBE        = (1 << 22), // movbe available
    CPUID_FEAT_ECX_POPCNT       = (1 << 23), // popcnt available (sounds rude)
    CPUID_FEAT_ECX_XSAVE        = (1 << 26), // xsave/xrstor/xsetbv/xgetbv supported
    CPUID_FEAT_ECX_OSXSAVE      = (1 << 27), // xsetbv/xgetbv has been enabled

    CPUID_FEAT_EDX_BEGIN        = (1ull << 27),

    CPUID_FEAT_EDX_x87          = CPUID_FEAT_EDX_BEGIN + (1 << 0),  // x86 FPU on chip
    CPUID_FEAT_EDX_VME          = CPUID_FEAT_EDX_BEGIN + (1 << 1),  // virtual-8086 mode enhancement
    CPUID_FEAT_EDX_DE           = CPUID_FEAT_EDX_BEGIN + (1 << 2),  // debugging extensions
    CPUID_FEAT_EDX_PSE          = CPUID_FEAT_EDX_BEGIN + (1 << 3),  // page size extensions
    CPUID_FEAT_EDX_TSC          = CPUID_FEAT_EDX_BEGIN + (1 << 4),  // timestamp counter
    CPUID_FEAT_EDX_MSR          = CPUID_FEAT_EDX_BEGIN + (1 << 5),  // rdmsr/wrmsr
    CPUID_FEAT_EDX_PAE          = CPUID_FEAT_EDX_BEGIN + (1 << 6),  // page address extensions
    CPUID_FEAT_EDX_MCE          = CPUID_FEAT_EDX_BEGIN + (1 << 7),  // machine check exception
    CPUID_FEAT_EDX_CX8          = CPUID_FEAT_EDX_BEGIN + (1 << 8),  // cmpxchg8b supported
    CPUID_FEAT_EDX_APIC         = CPUID_FEAT_EDX_BEGIN + (1 << 9),  // APIC on a chip
    CPUID_FEAT_EDX_SEP          = CPUID_FEAT_EDX_BEGIN + (1 << 11), // sysenter/sysexit
    CPUID_FEAT_EDX_MTRR         = CPUID_FEAT_EDX_BEGIN + (1 << 12), // memory type range registers
    CPUID_FEAT_EDX_PGE          = CPUID_FEAT_EDX_BEGIN + (1 << 13), // PTE global bit (PTE_GLOBAL)
    CPUID_FEAT_EDX_MCA          = CPUID_FEAT_EDX_BEGIN + (1 << 14), // machine check architecture
    CPUID_FEAT_EDX_CMOV         = CPUID_FEAT_EDX_BEGIN + (1 << 15), // conditional move/compare instructions
    CPUID_FEAT_EDX_PAT          = CPUID_FEAT_EDX_BEGIN + (1 << 16), // page attribute table
    CPUID_FEAT_EDX_PSE36        = CPUID_FEAT_EDX_BEGIN + (1 << 17), // page size extension
    CPUID_FEAT_EDX_PSN          = CPUID_FEAT_EDX_BEGIN + (1 << 18), // processor serial number
    CPUID_FEAT_EDX_CLFSH        = CPUID_FEAT_EDX_BEGIN + (1 << 19), // cflush instruction
    CPUID_FEAT_EDX_DS           = CPUID_FEAT_EDX_BEGIN + (1 << 21), // debug store
    CPUID_FEAT_EDX_ACPI         = CPUID_FEAT_EDX_BEGIN + (1 << 22), // thermal monitor and clock control
    CPUID_FEAT_EDX_MMX          = CPUID_FEAT_EDX_BEGIN + (1 << 23), // MMX technology
    CPUID_FEAT_EDX_FXSR         = CPUID_FEAT_EDX_BEGIN + (1 << 24), // fxsave/fxrstor
    CPUID_FEAT_EDX_SSE          = CPUID_FEAT_EDX_BEGIN + (1 << 25), // SSE extensions
    CPUID_FEAT_EDX_SSE2         = CPUID_FEAT_EDX_BEGIN + (1 << 26), // SSE2 extensions, obviously
    CPUID_FEAT_EDX_SS           = CPUID_FEAT_EDX_BEGIN + (1 << 27), // self-snoop
    CPUID_FEAT_EDX_HTT          = CPUID_FEAT_EDX_BEGIN + (1 << 28), // multi-threading (hyper-threading, I think - the afterburner of Intel CPUs)
    CPUID_FEAT_EDX_TM           = CPUID_FEAT_EDX_BEGIN + (1 << 29), // thermal monitor
    CPUID_FEAT_EDX_PBE          = CPUID_FEAT_EDX_BEGIN + (1 << 31), // Pend. Brk. EN. (wtf?)
} CpuFeature;

static inline uint32_t cpu_get_idx() {
    uint32_t eax, ebx = 0, ecx, edx;

    __get_cpuid(CPUID_GET_FEATURE, &eax, &ebx, &ecx, &edx);

    // Get logical core ID (31-24 bit)
    ebx = ebx >> 24;

    return ebx;
}

static inline bool_t cpu_is_feature_supported(const CpuFeature feature) {
    uint32_t eax, ebx = 0, ecx, edx;

    __get_cpuid(CPUID_GET_FEATURE, &eax, &ebx, &ecx, &edx);

    if (feature > CPUID_FEAT_EDX_BEGIN) {
        return (ebx & (feature - CPUID_FEAT_EDX_BEGIN)) != 0 ? TRUE : FALSE;
    }
    else {
        return (ecx & feature) != 0 ? TRUE : FALSE;
    }
}