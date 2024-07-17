#include "oma.h"

#include "arch.h"
#include "assert.h"
#include "bpa.h"
#include "vm.h"

#include "utils/math.h"
#include "utils/mem.h"

OMA::OMA(const uint32_t obj_size, void* bucket_pool, const uint32_t pages_number) : obj_size(obj_size) {
    kassert(bucket_pool != nullptr && pages_number > 0 && log2(pages_number) == log2upper(pages_number));

    bucket_capacity = calc_bucket_capacity(pages_number, obj_size);

    BucketNode* bucket = make_bucket(bucket_pool);

    buckets.push_front(bucket);
}

OMA::BucketNode* OMA::make_bucket(void* bucket_pool) {
    const uint32_t bitmap_size = div_roundup(bucket_capacity, BYTE_SIZE);
    uint8_t* const bitmap = reinterpret_cast<uint8_t*>(bucket_pool) + (bucket_capacity * obj_size);

    fill(bitmap, 0, bitmap_size);

    BucketNode* result = reinterpret_cast<BucketNode*>(bitmap + bitmap_size);
    result->value = Bucket(bucket_pool, bitmap);
    result->next = result->prev = nullptr;

    return result;
}

OMA::Bucket* OMA::new_bucket() {
    const uintptr_t bucket_base = BPA::alloc_pages(log2(bucket_pages));

    if (bucket_base == BPA::alloc_fail) return nullptr;

    BucketNode* node = make_bucket(reinterpret_cast<void*>(VM::get_virt_dma(bucket_base)));

    buckets.push_front(node);

    return &node->value;
}

void OMA::free_bucket(BucketNode* const node) {
    const auto node_base = reinterpret_cast<uintptr_t>(node);

    BPA::free_pages(VM::get_phys_dma(node_base), log2(bucket_pages));
}

void* OMA::alloc() {
    Bucket* bucket = nullptr;

    for (auto& buck : buckets) {
        if (buck.allocated_count < bucket_capacity) {
            bucket = &buck;
            break;
        }
    }

    if (bucket == nullptr) {
        bucket = new_bucket();

        if (bucket == nullptr) return nullptr;
    }

    const uint32_t bit_idx = bucket->bitmap.find_clear();
    bucket->bitmap.set(bit_idx);
    bucket->allocated_count++;

    return reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(bucket->pool) + (bit_idx * obj_size));
}

void OMA::free(void* const obj) {
    kassert(
        (reinterpret_cast<uintptr_t>(obj) % obj_size) ==
        ((reinterpret_cast<uintptr_t>(obj) & (~0xFFF)) % obj_size) && "Invalid address"
    );

    for (auto iter = buckets.begin(); iter != buckets.end(); ++iter) {
        if (iter->is_containing_addr(obj) == false) continue;

        //debug(iter.get_node());

        const auto bit_idx = (reinterpret_cast<uintptr_t>(obj) - reinterpret_cast<uintptr_t>(iter->pool)) / obj_size;

        //debug(iter->pool, ' ', iter->bitmap.get_map(), ' ', iter->allocated_count, ' ', bit_idx);

        iter->bitmap.clear(bit_idx);
        iter->allocated_count--;

        if (iter->allocated_count == 0 &&
            &buckets.get_head() != &buckets.get_tail()) {

            auto node = buckets.remove(iter);
            free_bucket(node);
        }

        return;
    }

    kassert(false && "The object is not managed by current OMA");
}

void OMA::log() {
    info("OMA: ", this);
    info("obj size: ", obj_size, ": bucket capacity: ", bucket_capacity);

    for (const auto& bucket : buckets) {
        info(" Bucket[", &bucket, "]:");
        info(" pool: ", bucket.pool, ": allocated: ", bucket.allocated_count);
    }
}