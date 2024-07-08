#include "fb.h"

uint32_t Color::pack(const ColorFormat format) const {
    uint8_t col[4];

    switch (format) {
    case ABGR: col[0] = r; col[1] = g; col[2] = b; col[3] = a; break;
    case ARGB: col[2] = r; col[1] = g; col[0] = b; col[3] = a; break;
    case BGRA: col[1] = r; col[2] = g; col[3] = b; col[0] = a; break;
    case RGBA: col[3] = r; col[2] = g; col[1] = b; col[0] = a; break;
    default: break;
    }

    return *reinterpret_cast<uint32_t*>(col);
}

Color Color::unpack(const ColorFormat format, const uint32_t color) {
    const uint8_t* col = reinterpret_cast<const uint8_t*>(&color);

    switch (format) {
    case ABGR: return { col[0], col[1], col[2], col[3] };
    case ARGB: return { col[2], col[1], col[0], col[3] };
    case BGRA: return { col[1], col[2], col[3], col[0] };
    case RGBA: return { col[3], col[2], col[1], col[0] };
    default:
        break;
    }

    return Color();
}