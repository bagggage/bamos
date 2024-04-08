#include "vector.h"

#include "mem.h"

Vector vector_make() {
    return (Vector){ NULL, 0 };
}

//Status vector_resize(Vector* vector, size_t new_size, uint32_t sizeof_element) {
//    return KERNEL_OK; 
//}

Status vector_push_back(Vector* vector, const void* src, uint32_t sizeof_element) {
    void* new_buffer = kmalloc((vector->size + 1) * sizeof_element);

    if (new_buffer == NULL) return KERNEL_ERROR;

    if (vector->data != NULL) {
        for (size_t i = 0; i < vector->size * sizeof_element; ++i) {
            ((uint8_t*)new_buffer)[i] = ((const uint8_t*)vector->data)[i];
        }
    }

    kfree(vector->data);

    vector->data = new_buffer;
    ++vector->size;

    for (uint32_t i = 0; i < sizeof_element && src != NULL; ++i) {
        ((uint8_t*)vector->data + ((vector->size - 1) * sizeof_element))[i] = ((const uint8_t*)src)[i];
    }

    return KERNEL_OK;
}

//void vector_pop_back(Vector* vector, uint32_t sizeof_element) {
//    
//}

void vector_remove(Vector* vector, size_t idx, uint32_t sizeof_element) {
}

void vector_clear(Vector* vector) {
    kfree(vector->data);

    vector->size = 0;
}