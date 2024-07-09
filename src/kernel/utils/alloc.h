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
class OmaAllocator {
private:
    static OMA& get_oma() {
        static OMA oma = OMA(sizeof(T));
        return oma;
    }
public:
    static inline T* alloc() {
        return reinterpret_cast<T*>(get_oma().alloc());
    }

    static inline void free(T* const obj) {
        get_oma().free(reinterpret_cast<void*>(obj));
    }
};

template<typename T>
using DefaultAllocator = NullAllocator;