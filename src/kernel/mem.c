#include "mem.h"

#define MEM_RAW_PATCH
#ifdef MEM_RAW_PATCH
typedef struct MemBlock {
    void* ptr;
    uint64_t size;
} MemBlock;

#define MAX_BLOCKS 1024

MemBlock allocated_blocks[MAX_BLOCKS] = { 0 }; 
size_t allocated_blocks_count = 0;

uint8_t mem_buffer[MB_SIZE] = { 0 };
uint8_t* buffer_ptr = mem_buffer;

MemBlock* get_next_allocated_block(size_t i) {
    MemBlock* last_block = NULL;

    ++i;

    while (i < MAX_BLOCKS && allocated_blocks[i].size == 0) {
        last_block = &allocated_blocks[i];
        ++i;
    }

    return NULL;
}

void* kmalloc(size_t size) {
    if (allocated_blocks_count >= MAX_BLOCKS || size == 0) return NULL;

    size_t allocated_i = 0;

    for (size_t i = 0; i < MAX_BLOCKS; ++i) {
        if (allocated_blocks[i].size == 0) {
            bool_t is_last = FALSE;

            if (allocated_blocks[i].ptr == NULL) {
                is_last = TRUE;
            }
            else {
                MemBlock* next_block = get_next_allocated_block(i);

                if (next_block->ptr == NULL) {
                    is_last = TRUE;
                }
                else {
                    size_t max_block_size = next_block->ptr - allocated_blocks[i].ptr;

                    if (max_block_size >= size) {
                        next_block->ptr = allocated_blocks[i].ptr + size;
                        
                        allocated_blocks[i].size = size;
                        ++allocated_blocks_count;

                        return allocated_blocks[i].ptr;
                    }

                    continue;
                }
            }

            if (is_last) {
                if ((buffer_ptr - mem_buffer) + size >= sizeof(mem_buffer)) return NULL;

                allocated_blocks[i].ptr = buffer_ptr;
                allocated_blocks[i].size = size;

                buffer_ptr += size;
                ++allocated_blocks_count;

                return allocated_blocks[i].ptr;
            }
        }
        else {
            ++allocated_i;
        }
    }

    return NULL;
}

MemBlock* find_block(void* allocated_mem) {
    for (size_t i = 0; i < MAX_BLOCKS; ++i) {
        if (allocated_blocks[i].ptr == allocated_mem) return &allocated_blocks[i];
    }

    return NULL;
}

void kfree(void* allocated_mem) {
    if (allocated_mem == NULL) return;

    MemBlock* block = find_block(allocated_mem);

    if (block == NULL) return;

    block->size = 0;
    --allocated_blocks_count;
}
#else
void* kmalloc(size_t size) {
    return NULL;
}

void kfree(void* allocated_mem) {
}
#endif