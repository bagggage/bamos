#include "buddy_page_alloc.h"

#include "assert.h"

#include "bitmap_mem_alloc.h"
#include "logger.h"
#include "mem.h"

#define NODES_PER_MB_COVERAGE (MB_SIZE / PAGE_BYTE_SIZE)

static BitmapMemoryAllocator free_list_bma;
static BuddyPageAllocator bpa;

static uint64_t get_total_mem_size(const VMMemoryMap* memory_map) {
    const VMMemoryMapEntry* last_entry = &memory_map->entries[memory_map->count - 1];

    return ((uint64_t)last_entry->compact_phys_address + last_entry->pages_count) * PAGE_BYTE_SIZE;
}

static bool_t free_list_push_first(ListHead* free_list, const uint32_t first_page_number) {
    VMPageList* new_node = (VMPageList*)bma_alloc(&free_list_bma);

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

    bma_free((void*)temp_entry, &free_list_bma);
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

    bma_free((void*)entry, &free_list_bma);
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
        VMPageList* temp_entry = bpa.free_list[i].next;

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

Status init_buddy_page_allocator(const VMMemoryMap* memory_map) {
    kassert(memory_map != NULL && memory_map->count > 0);

    // Search for free memory pool for free list bma
    const uint64_t total_mem_size = get_total_mem_size(memory_map);

#ifdef KDEBUG
    kernel_warn("Total memory size: %u KB; %u MB; %u GB\n",
        div_with_roundup(total_mem_size, KB_SIZE),
        div_with_roundup(total_mem_size, MB_SIZE),
        total_mem_size / GB_SIZE);
#endif

    const uint64_t required_bma_mem_pool_size = ((total_mem_size / MB_SIZE) * NODES_PER_MB_COVERAGE) * sizeof(VMPageList);
    const uint64_t required_bitmap_pool_size = (div_with_roundup(total_mem_size, PAGE_BYTE_SIZE) / 8);

    kernel_warn("BPA: Bitmap size: %u KB; %u MB\n", required_bitmap_pool_size / KB_SIZE, required_bitmap_pool_size / MB_SIZE);

    const uint64_t required_mem_pool_pages_count =
        div_with_roundup(required_bma_mem_pool_size + required_bitmap_pool_size, PAGE_BYTE_SIZE);

    uint64_t bma_memory_block = INVALID_ADDRESS;

    for (uint32_t i = 0; i < memory_map->count; ++i) {
        if (memory_map->entries[i].type != VMMEM_TYPE_FREE ||
            memory_map->entries[i].pages_count < required_mem_pool_pages_count) continue;

        bma_memory_block = ((uint64_t)memory_map->entries[i].compact_phys_address << 12);
    }

    if (bma_memory_block == INVALID_ADDRESS) {
        error_str = "There is no available memory for buddy page allocator";
        return KERNEL_ERROR;
    }

    is_virt_addr_mapped(bma_memory_block);

    free_list_bma = bma_create(bma_memory_block, required_bma_mem_pool_size, sizeof(VMPageList));

    if (free_list_bma.capacity == 0) {
        error_str = "BPA: Free list initialization failed";
        return KERNEL_ERROR;
    }

#ifdef KDEBUG
    kernel_warn("BPA: Free list pool size: %u KB\n", required_mem_pool_pages_count * (PAGE_BYTE_SIZE / KB_SIZE));
    kernel_warn("BPA: Free list capacity: %u\n", free_list_bma.capacity);
#endif

    bpa.bitmap = bma_memory_block + required_bma_mem_pool_size;
    
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
    VMPageList* free_entry = bpa.free_list[rank].next;

    if (free_entry == NULL) {
        uint8_t temp_rank = rank + 1;

        while (temp_rank < BPA_MAX_BLOCK_RANK)
        {
            if (bpa.free_list[temp_rank].next != NULL) {
                free_entry = bpa.free_list[temp_rank].next;
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