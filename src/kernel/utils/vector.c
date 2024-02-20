#include "vector.h"

#include "mem.h"

Vector vector_make() {

}

Status vector_resize(Vector* vector, size_t new_size, size_t sizeof_element) {
    return KERNEL_OK; 
}

Status vector_push_back(Vector* vector, const void* src, size_t sizeof_element) {
    void* new_buffer = kmalloc((vector->size + 1) * sizeof_element);

    if (new_buffer == NULL) return KERNEL_ERROR;

    if (vector->data != NULL) {
        for (size_t i = 0; i < vector->size; ++i) {
            ((uint8_t*)new_buffer)[i] = ((uint8_t*)vector->data)[i];
        }
    }

    kfree(vector->data);

    vector->data = new_buffer;
    ++vector->size;

    return KERNEL_OK;
}

void vector_pop_back(Vector* vector, size_t sizeof_element) {
    
}

void vector_remove(Vector* vector, size_t idx, size_t sizeof_element) {
}

void vector_clear(Vector* vector) {
    kfree(vector->data);
    vector->size = 0;
}