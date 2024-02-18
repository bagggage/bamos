#pragma once

#include "definitions.h"

// Dynamic array
typedef struct Vector {
    void* data;
    size_t size;
} Vector;

Vector vector_make();

Status vector_resize    (Vector* vector, size_t new_size, size_t sizeof_element);
Status vector_push_back (Vector* vector, const void* src, size_t sizeof_element);
Status vector_pop_back  (Vector* vector, size_t sizeof_element);
Status vector_remove    (Vector* vector, size_t idx, size_t sizeof_element);
Status vector_clear     (Vector* vector);