#pragma once

class NullAllocator {
public:
    template<typename T>
    static inline T* alloc() {
        return reinterpret_cast<T*>(nullptr);
    }

    template<typename T>
    static inline void free(T* const obj) {}
};