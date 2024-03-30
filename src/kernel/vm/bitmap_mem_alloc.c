#include "bitmap_mem_alloc.h"

#include "assert.h"

BitmapMemoryAllocator bma_create(void* memory_block, const size_t block_size, const uint32_t object_size) {
    kassert(memory_block != NULL && block_size > 0 && object_size > 0);

    BitmapMemoryAllocator bma = { NULL, NULL, 0, 0 };

    if (object_size >= block_size) return bma;

    bma.memory_pool = memory_block;
    bma.object_size = object_size;
    bma.capacity = block_size / object_size;
    bma.allocated_count = 0;

    size_t bitmap_byte_size = block_size % object_size;

    while ((bitmap_byte_size * 8) < bma.capacity) {
        --bma.capacity;
        bitmap_byte_size = block_size - (bma.capacity * bma.object_size);
    }

    bma.bitmap = (uint8_t*)(((uint64_t)bma.memory_pool + block_size) - bitmap_byte_size);

    return bma;
}

void* bma_alloc(BitmapMemoryAllocator* bma) {
    kassert(bma != NULL);

    const uint32_t bitmap_size = (bma->capacity / 8) + (bma->capacity % 8 == 0 ? 0 : 1);

    for(uint32_t i = 0; i < bitmap_size; ++i) {
        if (bma->bitmap[i] == 0xFF) continue;

        uint8_t bitmask = 1;

        for (uint8_t j = 0; j < 8; ++j) {
            if ((bma->bitmap[i] & bitmask) == 0) {
                const uint32_t idx = (i * 8) + j;

                if (idx >= bma->capacity) return NULL;

                bma->bitmap[i] |= bitmask;
                bma->allocated_count++;

                return (void*)((uint64_t)bma->memory_pool + (idx * bma->object_size));
            } 

            bitmask <<= 1;
        }
    }

    return NULL;
}

void bma_free(void* memory_block, BitmapMemoryAllocator* bma) {
    kassert(bma != NULL);

    if (memory_block == NULL) return FALSE;

    kassert(memory_block >= bma->memory_pool);

    const uint32_t idx = (memory_block - bma->memory_pool) / bma->object_size;

    kassert(idx < bma->capacity);
    kassert((bma->bitmap[idx / 8] & (1 << (idx % 8))) != 0);

    bma->bitmap[idx / 8] &= ~(1 << (idx % 8)); // Create inverse bitmask to set bit to zero
    bma->allocated_count--;

    return TRUE;
}