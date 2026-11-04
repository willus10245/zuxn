pub const Uxn = @import("uxn.zig").Uxn;
pub const opcodes = @import("opcodes.zig");

test {
    _ = @import("uxn.zig");
    _ = opcodes;
}
