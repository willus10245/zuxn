pub const std = @import("std");

pub const uxn = @import("uxn.zig");
pub const Uxn = uxn.Uxn;
pub const opcodes = @import("opcodes.zig");

pub fn loadRom(alloc: std.mem.Allocator, input_reader: *std.Io.Reader) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(alloc);
    errdefer writer.deinit();

    // fill zero page
    _ = try writer.writer.splatByte(0x00, 0x100);

    _ = try input_reader.streamRemaining(&writer.writer);
    const bytes_written = writer.written().len;
    const total_bytes = uxn.page_size * uxn.page_count;
    const remaining = total_bytes - bytes_written;

    // fill remaining memory
    _ = try writer.writer.splatByte(0x00, remaining);

    return writer.toOwnedSlice();
}

const testing = std.testing;

test "loadRom loads the input program starting at 0x100" {
    var rom_bytes = [_]u8{ 0x80, 0x01, 0x80, 0x02, 0x18 };
    var input_reader = std.Io.Reader.fixed(&rom_bytes);
    const ram = try loadRom(testing.allocator, &input_reader);
    defer testing.allocator.free(ram);
    try testing.expectEqualSlices(u8, &rom_bytes, ram[0x100 .. 0x100 + rom_bytes.len]);
}

test "loadRom zeroes the zero page" {
    var rom_bytes = [_]u8{ 0x80, 0x01, 0x80, 0x02, 0x18 };
    var input_reader = std.Io.Reader.fixed(&rom_bytes);
    const ram = try loadRom(testing.allocator, &input_reader);
    defer testing.allocator.free(ram);
    const zeroes: [0x100]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeroes, ram[0..0x100]);
}

test "loadRom returns correct amount of memory" {
    var rom_bytes = [_]u8{ 0x80, 0x01, 0x80, 0x02, 0x18 };
    var input_reader = std.Io.Reader.fixed(&rom_bytes);
    const ram = try loadRom(testing.allocator, &input_reader);
    defer testing.allocator.free(ram);
    try testing.expectEqual(uxn.page_count * uxn.page_size, ram.len);
}

test {
    _ = @import("uxn.zig");
    _ = opcodes;
}
