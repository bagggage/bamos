#include "fmt.h"

char* Fmt::num_to_str(char* buffer, uint64_t num, const bool is_signed, const uint8_t notation) {
    const auto digits = "0123456789abcdef";
    char out_buffer[32] = { '\0' };

    char* cursor = &out_buffer[sizeof(out_buffer) - 1];

    bool is_negative = is_signed && (static_cast<int64_t>(num)) < 0;

    if (is_negative) num = -num;

    do {
        *(--cursor) = digits[num % notation];
        num /= notation;
    } while (num > 0);

    if (is_negative) *(--cursor) = '-';

    const size_t length = (reinterpret_cast<size_t>(out_buffer) + sizeof(out_buffer) - 1) - reinterpret_cast<size_t>(cursor);

    for (size_t i = 0; i < length; ++i) buffer[i] = cursor[i];

    return buffer + length;
}

template<>
char* Fmt::to_str<uint16_t>(char* buffer, const uint16_t num) {
    return num_to_str(buffer, num, false, 10);
}

template<>
char* Fmt::to_str<uint32_t>(char* buffer, const uint32_t num) {
    return num_to_str(buffer, num, false, 10);
}

template<>
char* Fmt::to_str<uint64_t>(char* buffer, const uint64_t num) {
    return num_to_str(buffer, num, false, 16);
}

template<>
char* Fmt::to_str<unsigned long long>(char* buffer, const unsigned long long num) {
    return num_to_str(buffer, num, false, 16);
}

template<>
char* Fmt::to_str<int16_t>(char* buffer, const int16_t num) {
    return num_to_str(buffer, num, true, 10);
}

template<>
char* Fmt::to_str<int32_t>(char* buffer, const int32_t num) {
    return num_to_str(buffer, num, true, 10);
}

template<>
char* Fmt::to_str<int64_t>(char* buffer, const int64_t num) {
    return num_to_str(buffer, num, true, 16);
}

template<>
char* Fmt::to_str<bool>(char* buffer, const bool val) {
    return val ? to_str(buffer, "true") : to_str(buffer, "false");
}

template<>
char* Fmt::to_str<char>(char* buffer, const char c) {
    *(buffer++) = c;
    return buffer;
}

template<>
char* Fmt::to_str<decltype(nullptr)>(char* buffer, decltype(nullptr)) {
    return to_str(buffer, "nullptr");
}