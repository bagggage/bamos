
pub fn find(comptime T: type, haystack: []const T, key: anytype, comptime eqlFn: fn(*const T, @TypeOf(key)) bool) ?*const T {
    for (haystack) |*item| {
        if (eqlFn(item, key)) return item;
    }

    return null;
}