const std = @import("std");
const cpu = @import("uxn-core");
const scan = @import("scanner.zig");
const Io = std.Io;

pub fn Assembler(comptime lim: scan.Limits) type {
    return struct {
        pub const Scanner = scan.Scanner(lim);

        pub fn assemble(self: *@This(), input: *Io.Reader, output: []u8) !void {
            var scanner = Scanner{};

            var output_writer: Io.Writer = .fixed(output);

            while (try scanner.readToken(input)) |token| {
                try self.processToken(token, &output_writer);
            }
        }

        fn processToken(self: *@This(), token: Scanner.SourceToken, output: *Io.Writer) !void {
            switch (token.token) {
                .instruction => |instr| {
                    try output.writeByte(instr.opcode);
                },
                .literal => |lit| {
                    switch (lit) {
                        .byte => |byte| {
                            try output.writeByte(0x80); // LIT
                            try output.writeByte(byte);
                        },
                        .short => |short| {
                            try output.writeByte(0xa0); // LIT2
                            try output.writeInt(u16, short, .big);
                        },
                    }
                },
                .raw_literal => |lit| {
                    switch (lit) {
                        .byte => |byte| try output.writeByte(byte),
                        .short => |short| try output.writeInt(u16, short, .big),
                    }
                },
                .padding => |pad| {
                    switch (pad) {
                        .absolute => |offset| output.end = @intCast(try self.resolveOffset(offset)),
                        .relative => |offset| output.end += @intCast(try self.resolveOffset(offset)),
                    }
                },
                .word => |word| try output.writeAll(std.mem.sliceTo(&word, 0)),
                else => unreachable,
            }
        }

        fn resolveOffset(self: *@This(), offset: Scanner.Offset) !u16 {
            _ = self;
            return switch (offset) {
                .literal => |lit| lit,
                .label => unreachable,
            };
        }
    };
}

const testing = std.testing;

test "assemble can assemble" {
    const A = Assembler(.{});
    var assembler: A = .{};
    var input: Io.Reader = .fixed("( hello.tal )\n|0100 LIT 68 LIT 18 DEO LIT 0a LIT 18 DEO\n");
    const expected_rom: [0x10a]u8 = [1]u8{0x00} ** 0x100 ++ [_]u8{ 0x80, 0x68, 0x80, 0x18, 0x17, 0x80, 0x0a, 0x80, 0x18, 0x17 };
    var output: [0x10a]u8 = [1]u8{0x00} ** 0x10a;
    try assembler.assemble(&input, &output);
    try testing.expect(std.mem.eql(u8, &output, &expected_rom));
}
