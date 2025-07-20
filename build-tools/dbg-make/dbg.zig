pub const Header = packed struct {
    entries_num: u32 = undefined,
    strtab_offset: u32 = undefined,
};

pub const Entry = packed struct {
    addr: u32 = undefined,
    size: u32 = undefined,
    name_offset: u32 = undefined,
};