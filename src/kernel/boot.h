#pragma once

#include "definitions.h"

#include "utils/math.h"

class Framebuffer;
struct DebugSymbolTable;

struct BootMemMap {
    enum Type : uint8_t {
        MEM_FREE,
        MEM_DEV,
        MEM_USED
    };

    struct Entry {
        uint32_t base;
        uint32_t pages;
        Type type : 3;
    };

    Entry* entries = nullptr;
    uint32_t size = 0;

    inline bool is_empty() const { return size == 0; }

    inline uint32_t get_max_page() const {
        for (auto i = size - 1; i > 0; --i) {
            if (entries[i].type != MEM_FREE) continue;

            return entries[i].base + entries[i].pages - 1;
        }

        return 0;
    }

    void remove(const uint32_t idx);
};

struct BootMemMapping {
    uintptr_t phys;
    uintptr_t virt;
    uint32_t pages;
    uint8_t flags;
};

class Boot {
private:
    static BootMemMap mem_map;

    static uint32_t calc_mmap_size();
    static void init_mem_map();

    static void* early_alloc(const uint32_t size);
public:
    static inline auto alloc_fail = reinterpret_cast<void*>(0xF000000000000000);
public:
    static void get_fb(Framebuffer* const fb);

    static uint32_t get_cpus_num();
    static const DebugSymbolTable* get_dbg_table();

    static inline BootMemMap& get_mem_map() {
        return mem_map;
    }

    static BootMemMapping* get_mem_mappings();

    static void* alloc(const uint32_t pages_num);

    static void switch_to_dma();
};