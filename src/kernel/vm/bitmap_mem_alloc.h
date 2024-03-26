#pragma once

#include "definitions.h"

/*
Bitmap memory allocator.
*/

typedef struct BitmapMemoryAllocator {
    void* memory_pool;

    uint8_t* bitmap;

    uint32_t item_size;
    uint32_t capacity;
} BitmapMemoryAllocator;

BitmapMemoryAllocator bma_create(void* memory_block, const size_t block_size, const uint32_t item_size);

void* bma_alloc(BitmapMemoryAllocator* bma);
void bma_free(void* memory_block, BitmapMemoryAllocator* bma);