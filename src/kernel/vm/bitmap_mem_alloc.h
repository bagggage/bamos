#pragma once

#include "definitions.h"

/*
Bitmap memory allocator.
*/

typedef struct BitmapMemoryAllocator {
    void* memory_pool;

    uint8_t* bitmap;

    uint32_t object_size;
    uint32_t capacity;

    uint32_t allocated_count;
} BitmapMemoryAllocator;

BitmapMemoryAllocator bma_create(void* memory_block, const size_t block_size, const uint32_t object_size);

void* bma_alloc(BitmapMemoryAllocator* bma);
void bma_free(void* memory_block, BitmapMemoryAllocator* bma);