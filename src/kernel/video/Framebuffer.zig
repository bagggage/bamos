pub const ColorFormat = enum {
    ARGB,
    ARBG,
    ABGR,
    ABRG,

    RGBA,
    RBGA,
    BGRA,
    BRGA,
};

pub const Color = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const black     = Color{ .r=0,      .g=0,      .b=0   };
    pub const white     = Color{ .r=255,    .g=255,    .b=255 };
    pub const gray      = Color{ .r=128,    .g=128,    .b=128 };
    pub const lgray     = Color{ .r=165,    .g=165,    .b=165 };
    pub const red       = Color{ .r=255,    .g=0,      .b=0   };
    pub const lred      = Color{ .r=250,    .g=5,      .b=50  };
    pub const green     = Color{ .r=0,      .g=255,    .b=0   };
    pub const lgreen    = Color{ .r=5,      .g=250,    .b=70  };
    pub const blue      = Color{ .r=0,      .g=0,      .b=255 };
    pub const lblue     = Color{ .r=5,      .g=70,     .b=250 };
    pub const yellow    = Color{ .r=250,    .g=240,    .b=5   };
    pub const lyellow   = Color{ .r=255,    .g=235,    .b=75  };
    pub const orange    = Color{ .r=255,    .g=165,    .b=0   };
    pub const magenta   = Color{ .r=150,    .g=57,     .b=184 };
    pub const lmagenta  = Color{ .r=184,    .g=53,     .b=232 };
    pub const cyan      = Color{ .r=66,     .g=139,    .b=184 };
    pub const lcyan     = Color{ .r=53,     .g=164,    .b=232 };

    pub fn pack(self: *const Color, format: ColorFormat) u32 {
        var result: u32 = undefined;
        const col: [*]u8 = @ptrCast(&result);

        switch (format) {
            .ABGR => { col[0] = self.r; col[1] = self.g; col[2] = self.b; col[3] = self.a; },
            .ARGB => { col[2] = self.r; col[1] = self.g; col[0] = self.b; col[3] = self.a; },
            .BGRA => { col[1] = self.r; col[2] = self.g; col[3] = self.b; col[0] = self.a; },
            .RGBA => { col[3] = self.r; col[2] = self.g; col[1] = self.b; col[0] = self.a; },
            else => unreachable
        }

        return result;
    }

    pub fn unpack(format: ColorFormat, color_value: u32) Color {
        const col: [*]const u8 = @ptrCast(color_value);

        return switch (format) {
            .ABGR => Color{ .r = col[0], .g = col[1], .b = col[2], .a = col[3] },
            .ARGB => Color{ .r = col[2], .g = col[1], .b = col[0], .a = col[3] },
            .BGRA => Color{ .r = col[1], .g = col[2], .b = col[3], .a = col[0] },
            .RGBA => Color{ .r = col[3], .g = col[2], .b = col[1], .a = col[0] },
            else => unreachable
        };
    }
};

base: [*]u32,
scanline: u32,
width: u32,
height: u32,

format: ColorFormat