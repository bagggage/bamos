#include "buddy_page_alloc.h"

#include "assert.h"

#include "object_mem_alloc.h"
#include "logger.h"
#include "mem.h"

#define NODES_PER_MB_COVERAGE (MB_SIZE / PAGE_BYTE_SIZE)

static ObjectMemoryAllocator free_list_oma;
static BuddyPageAllocator bpa;

static uint64_t get_total_mem_size(const VMMemoryMap* memory_map) {
    return (uint64_t)memory_map->total_pages_count * PAGE_BYTE_SIZE;
}

static bool_t free_list_push_first(ListHead* free_list, const uint32_t first_page_number) {
    VMPageList* new_node = (VMPageList*)oma_alloc(&free_list_oma);

    if (new_node == NULL) return FALSE;

    new_node->phys_page_base = first_page_number;
    new_node->next = (VMPageList*)free_list->next;
    new_node->prev = NULL;

    if (free_list->next == NULL) {
        // If list is empty
        free_list->next = (ListHead*)new_node;
        free_list->prev = free_list->next;
    }
    else {
        free_list->next->prev = (ListHead*)new_node;
        free_list->next = (ListHead*)new_node;
    }

    return TRUE;
}

static void free_list_remove_first(ListHead* free_list) {
    kassert(free_list != NULL && free_list->next != NULL);

    VMPageList* temp_entry = (VMPageList*)free_list->next;

    if (free_list->next == free_list->prev) {
        // Only one entry
        free_list->next = NULL;
        free_list->prev = NULL;
    }
    else {
        temp_entry->next->prev = NULL;
        free_list->next = free_list->next->next;
    }

    oma_free((void*)temp_entry, &free_list_oma);
}

static void free_list_find_and_remove(ListHead* free_list, const uint32_t page_base) {
    kassert(free_list != NULL);

    VMPageList* head = (VMPageList*)free_list->next;
    VMPageList* tail = (VMPageList*)free_list->prev;
    VMPageList* entry = NULL;

    while (TRUE) {
        if (head->phys_page_base == page_base) {
            entry = head;
            break;
        }
        if (tail->phys_page_base == page_base) {
            entry = tail;
            break;
        }

        if (head == tail || (head->next == tail)) break;

        head = head->next;
        tail = tail->prev;
    }

    kassert(entry != NULL);

    // Only one element
    if (free_list->next == free_list->prev) {
        free_list->next = NULL;
        free_list->prev = NULL;
    }
    else if ((VMPageList*)free_list->next == entry) {
        entry->next->prev = NULL;
        free_list->next = (ListHead*)entry->next;
    }
    else if ((VMPageList*)free_list->prev == entry) {
        entry->prev->next = NULL;
        free_list->prev = (ListHead*)entry->prev;
    }
    else {
        entry->next->prev = entry->prev;
        entry->prev->next = entry->next;
    }

    oma_free((void*)entry, &free_list_oma);
}

static inline void bpa_clear_page_bit(const uint32_t page_base, const uint32_t rank) {
    const uint32_t bit_idx = page_base >> (rank + 1);

    bpa.bitmap[bit_idx / 8] &= ~(1 << (bit_idx % 8));
}

static inline void bpa_set_page_bit(const uint32_t page_base, const uint32_t rank) {
    const uint32_t bit_idx = page_base >> (rank + 1);

    bpa.bitmap[bit_idx / 8] |= (1 << (bit_idx % 8));
}

static inline void bpa_inverse_page_bit(const uint32_t page_base, const uint32_t rank) {
    const uint32_t bit_idx = page_base >> (rank + 1);

    bpa.bitmap[bit_idx / 8] ^= (1 << (bit_idx % 8));
}

static inline uint8_t bpa_get_page_bit(const uint32_t page_base, const uint32_t rank) {
    const uint32_t bit_idx = page_base >> (rank + 1);

    return bpa.bitmap[bit_idx / 8] & (1 << (bit_idx % 8));
}

static bool_t bpa_push_mem_block_recurcive(uint32_t first_page_number, uint32_t pages_count, const uint32_t rank) {
    kassert(pages_count > 0 && rank < BPA_MAX_BLOCK_RANK);

    const uint32_t rank_pages_count = 1 << rank;

    if (rank_pages_count > pages_count) return bpa_push_mem_block_recurcive(first_page_number, pages_count, rank - 1);

    const uint32_t modulo = pages_count % rank_pages_count;

    while (pages_count > modulo) {
        if (free_list_push_first(&bpa.free_list[rank], first_page_number) != TRUE) return FALSE;

        bpa_set_page_bit(first_page_number, rank);

        first_page_number += rank_pages_count;
        pages_count -= rank_pages_count;
    }

    if (modulo != 0) {
        return bpa_push_mem_block_recurcive(first_page_number, modulo, rank - 1);
    }

    return TRUE;
}

static inline bool_t bpa_push_free_mem_block(const uint32_t first_page_number, const uint32_t pages_count) {
    uint16_t rank = BPA_MAX_BLOCK_RANK - 1;
    uint32_t rank_pages_count = 1 << rank;

    while (rank > 0 && rank_pages_count > pages_count) {
        rank--;
        rank_pages_count >>= 1;
    }

    return bpa_push_mem_block_recurcive(first_page_number, pages_count, rank);
}

void bpa_log_free_lists() {
    for (int i = 0; i < BPA_MAX_BLOCK_RANK; ++i) {
        VMPageList* temp_entry = (VMPageList*)(void*)bpa.free_list[i].next;

        kernel_msg("Free list[%i]: ", i);

        while (temp_entry != NULL) {
            Color temp_color = kernel_logger_get_color();
            kernel_logger_set_color(COLOR_LYELLOW);
            raw_print_number((uint64_t)temp_entry->phys_page_base * PAGE_BYTE_SIZE, FALSE, 16);
            kernel_logger_set_color_struct(temp_color);
            raw_puts(" -> ");

            temp_entry = temp_entry->next;
        }

        raw_putc('\n');
    }
}

static bool_t init_bpa_free_lists(const VMMemoryMap* memory_map) {
    for (uint32_t i = 0; i < BPA_MAX_BLOCK_RANK; ++i) {
        bpa.free_list[i].next = NULL;
        bpa.free_list[i].prev = NULL;
    }

    for (uint32_t i = 0; i < memory_map->count; ++i) {
        if (memory_map->entries[i].type == VMMEM_TYPE_FREE) {
            const VMMemoryMapEntry* entry = &memory_map->entries[i];

            if (bpa_push_free_mem_block(entry->compact_phys_address, entry->pages_count) != TRUE) {
                return FALSE;
            }
        }
    }

    return TRUE;
}

void debug_trace();

static VMPageList oma_phys_page = { NULL, NULL, 0 };

Status init_buddy_page_allocator(VMMemoryMap* memory_map) {
    kassert(memory_map != NULL && memory_map->count > 0);

    // Search for free memory pool for free list bma
    const uint64_t total_mem_size = get_total_mem_size(memory_map);

#ifdef KDEBUG
    kernel_warn("Total memory size: %u KB; %u MB; %u GB\n",
        div_with_roundup(total_mem_size, KB_SIZE),
        div_with_roundup(total_mem_size, MB_SIZE),
        total_mem_size / GB_SIZE);
#endif
    const uint64_t requited_nodes_count = ((total_mem_size / MB_SIZE) * NODES_PER_MB_COVERAGE);
    const uint64_t required_oma_mem_pool_size = requited_nodes_count * sizeof(VMPageList) / 2;
    const uint64_t required_bitmap_pool_size = div_with_roundup(requited_nodes_count, 8);
    const uint64_t required_mem_pool_pages_count =
        div_with_roundup(required_oma_mem_pool_size, PAGE_BYTE_SIZE) +
        div_with_roundup(required_bitmap_pool_size, PAGE_BYTE_SIZE);

    kernel_warn("BPA: Bitmap size: %u KB; %u MB\n", required_bitmap_pool_size / KB_SIZE, required_bitmap_pool_size / MB_SIZE);

    VMPageFrame oma_page_frame;
    VMMemoryMapEntry* bpa_memory_block = _vm_boot_alloc(memory_map, required_mem_pool_pages_count);

    if (bpa_memory_block == NULL) {
        error_str = "There is no available memory for buddy page allocator";
        return KERNEL_ERROR;
    }

    kernel_warn("BPA: Memory block allocated: %x\n", (uint64_t)bpa_memory_block->compact_phys_address * PAGE_BYTE_SIZE);

    oma_phys_page.phys_page_base = bpa_memory_block->compact_phys_address;

    oma_page_frame.phys_pages.next = &oma_phys_page;
    oma_page_frame.phys_pages.prev = &oma_phys_page;
    oma_page_frame.count = bpa_memory_block->pages_count - div_with_roundup(required_bitmap_pool_size, PAGE_BYTE_SIZE);
    oma_page_frame.virt_address = vm_find_free_virt_address(vm_get_kernel_pml4(), bpa_memory_block->pages_count);
    oma_page_frame.flags = (VMMAP_FORCE | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES);

    if (oma_page_frame.virt_address == INVALID_ADDRESS) {
        error_str = "BPA: Pool can't be mapped";
        return KERNEL_ERROR;
    }

    kernel_warn("BPA: Virtual addresses rage found: %x\n", oma_page_frame.virt_address);
    kassert(is_virt_address_valid(oma_page_frame.virt_address));

    if (vm_map_phys_to_virt((uint64_t)oma_phys_page.phys_page_base * PAGE_BYTE_SIZE,
        oma_page_frame.virt_address,
        bpa_memory_block->pages_count,
        oma_page_frame.flags) != KERNEL_OK) {
        error_str = "BPA: Mapping failed";
        return KERNEL_ERROR;
    }

    free_list_oma = _oma_manual_init(&oma_page_frame, sizeof(VMPageList));

    if (free_list_oma.bucket_capacity == 0) {
        error_str = "BPA: Free list initialization failed";
        return KERNEL_ERROR;
    }

    kernel_msg("BPA: Oma initialized\n");

    bpa.bitmap = (uint8_t*)(oma_page_frame.virt_address +
        (div_with_roundup(required_oma_mem_pool_size, PAGE_BYTE_SIZE) * PAGE_BYTE_SIZE));

#ifdef KDEBUG
    kernel_warn("BPA: Memory pool: %x (%x)\n",
        oma_page_frame.virt_address,
        (uint64_t)bpa_memory_block->compact_phys_address * PAGE_BYTE_SIZE);
    kernel_warn("BPA: Memory pool size: %u KB\n", required_mem_pool_pages_count * (PAGE_BYTE_SIZE / KB_SIZE));
    kernel_warn("BPA: Free list capacity: %u (was requested: %u)\n",
        free_list_oma.bucket_capacity,
        required_oma_mem_pool_size / sizeof(VMPageList));
    kernel_warn("BPA: Bitmap: %x\n", (uint64_t)bpa.bitmap);
#endif

    if (init_bpa_free_lists(memory_map) == FALSE) {
        error_str = "BPA: Failed to fill free lists according to memory map";
        return KERNEL_ERROR;
    }

    return KERNEL_OK;
}

uint64_t bpa_allocate_pages(const uint32_t rank) {
    kassert(rank < BPA_MAX_BLOCK_RANK);

    spin_lock(&bpa.lock);

    uint64_t result = INVALID_ADDRESS;

    // Get first entry
    VMPageList* free_entry = (VMPageList*)(void*)bpa.free_list[rank].next;

    if (free_entry == NULL) {
        uint8_t temp_rank = rank + 1;

        while (temp_rank < BPA_MAX_BLOCK_RANK)
        {
            if (bpa.free_list[temp_rank].next != NULL) {
                free_entry = (VMPageList*)(void*)bpa.free_list[temp_rank].next;
                break;
            }

            temp_rank++;
        }

        if (free_entry == NULL) {
            spin_release(&bpa.lock);
            return result;
        }

        uint32_t temp_pages_count = (1 << (temp_rank - 1));
        uint32_t temp_page_base = free_entry->phys_page_base + temp_pages_count;

        // Divide first large entry
        {
            if (free_list_push_first(&bpa.free_list[temp_rank - 1], free_entry->phys_page_base) != TRUE) {
                spin_release(&bpa.lock);
                return result;
            }

            bpa_set_page_bit(free_entry->phys_page_base, temp_rank - 1);
            bpa_inverse_page_bit(free_entry->phys_page_base, temp_rank);
            free_list_remove_first(&bpa.free_list[temp_rank]);

            temp_rank--;
            temp_pages_count >>= 1;
        }

        // Divide large entry on smaller
        while (temp_rank > rank) {
            if (free_list_push_first(&bpa.free_list[temp_rank - 1], temp_page_base) != TRUE) {
                spin_release(&bpa.lock);
                return result;
            }

            bpa_set_page_bit(temp_page_base, temp_rank - 1);

            temp_rank--;
            temp_page_base += temp_pages_count;
            temp_pages_count <<= 1;
        }

        spin_release(&bpa.lock);

        return (uint64_t)temp_page_base * PAGE_BYTE_SIZE;
    }
    
    result = (uint64_t)free_entry->phys_page_base * PAGE_BYTE_SIZE;

    bpa_inverse_page_bit(free_entry->phys_page_base, rank);
    free_list_remove_first(&bpa.free_list[rank]);
    spin_release(&bpa.lock);

    return result;
}

void bpa_free_pages(const uint64_t phys_page_address, const uint32_t rank) {
    kassert((phys_page_address & 0xFFF) == 0 && rank < BPA_MAX_BLOCK_RANK);

    uint32_t page_base = (uint32_t)(phys_page_address / PAGE_BYTE_SIZE);

    spin_lock(&bpa.lock);

    // Check if buddy is used
    if (bpa_get_page_bit(page_base, rank) == 0 || rank == (BPA_MAX_BLOCK_RANK - 1)) {
        if (free_list_push_first(&bpa.free_list[rank], page_base) != TRUE) {
            // KERNEL PANIC
            kernel_error("BPA: Failed to insert new entry while freeing pages: %x\n", phys_page_address);
            spin_release(&bpa.lock);
            return;
        }

        bpa_inverse_page_bit(page_base, rank);
        spin_release(&bpa.lock);

        return;
    }

    uint32_t temp_rank = rank;

    // Buddies can be combined
    while (bpa_get_page_bit(page_base, temp_rank) != 0 && temp_rank < BPA_MAX_BLOCK_RANK - 1) {
        const uint32_t rank_pages_count = 1 << temp_rank;

        uint32_t combine_page_base = page_base;
        uint32_t buddy_page_base = page_base;

        if (page_base % (rank_pages_count << 1) == 0) {
            buddy_page_base += rank_pages_count;
        }
        else {
            buddy_page_base -= rank_pages_count;
            combine_page_base = buddy_page_base;
        }

        free_list_find_and_remove(&bpa.free_list[temp_rank], buddy_page_base);

        page_base = combine_page_base;
        temp_rank++;
    }

    if (free_list_push_first(&bpa.free_list[temp_rank], page_base) != TRUE) {
        // KERNEL PANIC
        kernel_error("BPA: Failed to insert new entry while freeing pages: %x\n", phys_page_address);
        spin_release(&bpa.lock);
        return;
    }

    bpa_set_page_bit(page_base, temp_rank);
    spin_release(&bpa.lock);
}