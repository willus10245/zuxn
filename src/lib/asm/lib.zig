pub const scanner = @import("scanner.zig");
pub const assembler = @import("assembler.zig");
pub const Assembler = assembler.Assembler;

test {
    _ = scanner;
    _ = assembler;
}
