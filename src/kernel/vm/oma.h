#pragma once

#include "arch.h"
#include "definitions.h"

#include "utils/math.h"
#include "utils/bitmap.h"
#include "utils/list.h"

class OMA {
private:
    class Bucket {
    public:
        Bucket(void* pool, uint8_t* bitmap)
        : pool(pool), bitmap(bitmap)
        {}

        void* pool = nullptr;
        Bitmap bitmap;

        uint32_t allocated_count = 0;

        inline bool is_containing_addr(const void* address) const {
            return (address >= pool && address < bitmap.get_map());
        }
    };

    uint32_t obj_size = 0;
    uint32_t bucket_capacity = 0;
    uint32_t bucket_pages = 0;

    List<Bucket> buckets;

    using BucketNode = decltype(buckets)::Node;

    friend class UMA;
private:
    static constexpr uint32_t calc_bucket_capacity(const uint32_t pages_number, const uint32_t obj_size) {
        uint32_t capacity = ((pages_number * Arch::page_size) - sizeof(BucketNode)) / obj_size;
        uint32_t bitmap_size = div_roundup(capacity, BYTE_SIZE);

        while (((capacity * obj_size) + bitmap_size + sizeof(BucketNode)) > (pages_number * Arch::page_size)) {
            capacity--;
            bitmap_size = div_roundup(capacity, BYTE_SIZE);
        }

        return capacity;
    }

    BucketNode* make_bucket(void* bucket_pool);

    Bucket* new_bucket();
    void free_bucket(BucketNode* const node);
public:
    constexpr OMA() = default;
    constexpr OMA(const uint32_t obj_size, const uint32_t capacity = 128)
    : obj_size(obj_size) {
        const uint32_t max_pages = 1 << log2(div_roundup(obj_size * capacity, Arch::page_size));

        bucket_capacity = calc_bucket_capacity(max_pages, obj_size);
        bucket_pages = max_pages;
    }

    OMA(const uint32_t obj_size, void* bucket_pool, const uint32_t pages_number);

    void* alloc();
    void free(void* const obj);

    void log();
};

template<typename T>
class OmaAllocator {
public:
    static OMA& _get_oma() {
        static OMA oma = OMA(sizeof(T));
        return oma;
    }

    static inline T* alloc() {
        return reinterpret_cast<T*>(_get_oma().alloc());
    }

    static inline void free(T* const obj) {
        _get_oma().free(reinterpret_cast<void*>(obj));
    }
};