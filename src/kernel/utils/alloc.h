#pragma once

template<typename T>
class NullAllocator {
public:
    static inline T* alloc() {
        return reinterpret_cast<T*>(nullptr);
    }

    static inline void free(T* const obj) {}
};

template<typename T>
class NewAllocator {
public:
    static inline T* alloc() {
        return new T;
    }

    static inline void free(T* const obj) {
        delete obj;
    }
};

template<typename T>
using DefaultAllocator = NullAllocator<T>;