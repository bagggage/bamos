#pragma once

#include "definitions.h"

// Dynamic array
typedef struct Vector {
    void* data;
    size_t size;
} Vector;

Vector vector_make();

Status vector_resize    (Vector* vector, size_t new_size, uint32_t sizeof_element);
Status vector_push_back (Vector* vector, const void* src, uint32_t sizeof_element);
void   vector_pop_back  (Vector* vector, uint32_t sizeof_element);
void   vector_remove    (Vector* vector, size_t idx, uint32_t sizeof_element);
void   vector_clear     (Vector* vector);