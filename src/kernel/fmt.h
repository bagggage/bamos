#pragma once

#include "definitions.h"

#include "utils/string.h"

class Fmt {
private:
    static char* num_to_str(char* buffer, uint64_t num, const bool is_signed, const uint8_t notation);

    template<typename T>
    static char* to_str(char* buffer, const T);

    template<typename T>
    static char* to_str(char* buffer, const T* ptr) {
        buffer[0] = '0';
        buffer[1] = 'x';
        return num_to_str(buffer + 2, reinterpret_cast<uint64_t>(ptr), false, 16);
    }

    template<typename T>
    static char* to_str(char* buffer, T* ptr) { return to_str(buffer, const_cast<const T*>(ptr)); }
public:
    template<bool IsLast = true, typename Arg, typename... Args>
    static char* str(char* buffer, const Arg arg, const Args... args) {
        char* cursor = to_str(buffer, arg);

        if constexpr (sizeof...(Args) > 0) {
            cursor = str<false>(cursor, args...);
        }

        if constexpr (IsLast) *cursor = '\0';

        return cursor;
    }
};

template<>
inline char* Fmt::to_str<char>(char* buffer, const char* str) {
    const size_t length = String::len(str);

    for (size_t i = 0; i < length; ++i) buffer[i] = str[i];

    return buffer + length;
}