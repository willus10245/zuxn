const std = @import("std");
const cpu = @import("uxn-core");
const scan = @import("scanner.zig");
const Io = std.Io;
const mem = std.mem;

pub const AssemblerError = error{
    MissingParentLabel,
    UndefinedLabel,
    ReferenceTooFar,
};

pub fn Assembler(comptime lim: scan.Limits) type {
    return struct {
        pub const Scanner = scan.Scanner(lim);

        pub const LabelDef = struct {
            label: Scanner.LabelName,
            addr: u16,
            refs: std.ArrayListUnmanaged(Reference),
        };

        pub const Reference = struct {
            addr: u16,
            offset: u16,
            type: Scanner.AddressType,
        };

        alloc: mem.Allocator,

        labels: std.ArrayListUnmanaged(LabelDef) = .empty,

        last_parent_label: ?Scanner.LabelName = null,

        pub fn init(alloc: mem.Allocator) @This() {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *@This()) void {
            for (self.labels.items) |*lbl| {
                lbl.refs.deinit(self.alloc);
            }

            self.labels.deinit(self.alloc);
        }

        pub fn assemble(self: *@This(), input: *Io.Reader, output: []u8) !void {
            var scanner = Scanner{};

            var output_writer: Io.Writer = .fixed(output);

            while (try scanner.readToken(input)) |token| {
                try self.processToken(token, &output_writer);
            }

            try self.resolveReferences(output);
        }

        fn defineLabel(self: *@This(), label: Scanner.Label, addr: u16) !void {
            const label_name = try self.resolveLabelName(label);

            const def = LabelDef{ .addr = addr, .label = label_name, .refs = .empty };
            try self.labels.append(self.alloc, def);
        }

        fn lookupLabel(self: *@This(), label: Scanner.Label) !?*LabelDef {
            const label_name = try self.resolveLabelName(label);

            for (self.labels.items) |*lbl| {
                if (mem.eql(u8, &label_name, &lbl.label)) {
                    return lbl;
                }
            }

            return null;
        }

        fn processToken(self: *@This(), token: Scanner.SourceToken, output: *Io.Writer) !void {
            // std.debug.print("token: {any}\n", .{token.token});
            switch (token.token) {
                .instruction => |instr| {
                    try output.writeByte(instr.opcode);
                },
                .label => |lbl| {
                    try self.defineLabel(lbl, @truncate(output.end));

                    if (lbl == .parent) {
                        self.last_parent_label = lbl.parent;
                    }
                },
                .address => |address| {
                    const def = try self.lookupLabel(address.label) orelse return AssemblerError.UndefinedLabel;

                    const ref = try def.refs.addOne(self.alloc);

                    ref.* = .{
                        .addr = @truncate(output.end),
                        .offset = 0,
                        .type = address.type,
                    };

                    switch (address.type) {
                        .zero => try output.writeInt(u16, 0x80db, .big),
                        .raw_zero => try output.writeByte(0xdb),
                        .relative => try output.writeInt(u16, 0x80db, .big),
                        .raw_relative => try output.writeByte(0xdb),
                        .absolute => try output.writeInt(u24, 0xa0dbdb, .big),
                        .raw_absolute => try output.writeInt(u16, 0xdbdb, .big),
                    }
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

        fn resolveLabelName(self: *@This(), label: Scanner.Label) !Scanner.LabelName {
            switch (label) {
                .parent => {
                    return label.parent;
                },
                .child => |chld| {
                    const parent = mem.sliceTo(&(self.last_parent_label orelse return AssemblerError.MissingParentLabel), 0);
                    const stripped_parent = mem.sliceTo(parent, '/');
                    const child = mem.sliceTo(&chld, 0);

                    var full_label = [1:0]u8{0x00} ** Scanner.limits.identifier_length;

                    @memcpy(full_label[0..stripped_parent.len], stripped_parent);
                    @memcpy(full_label[stripped_parent.len + 1 .. stripped_parent.len + 1 + child.len], child);
                    full_label[stripped_parent.len] = '/';

                    return full_label;
                },
            }
        }

        fn resolveOffset(self: *@This(), offset: Scanner.Offset) !u16 {
            return switch (offset) {
                .literal => |lit| lit,
                .label => |lbl| if (try self.lookupLabel(try self.resolveLabelName(lbl))) |l| l.addr orelse AssemblerError.UndefinedLabel else AssemblerError.UndefinedLabel,
            };
        }

        fn resolveReferences(self: *@This(), output: []u8) !void {
            for (self.labels.items) |label| {
                for (label.refs.items) |ref| {
                    const position = switch (ref.type) {
                        // After the LIT opcode
                        .zero, .relative, .absolute => ref.addr + 1,

                        // No opcode to skip
                        .raw_zero, .raw_relative, .raw_absolute => ref.addr,
                    };

                    switch (ref.type) {
                        .zero, .raw_zero => {
                            output[position] = @truncate(label.addr);
                        },
                        .relative, .raw_relative => {
                            const offset: i32 = @as(i32, label.addr) - @as(i32, ref.addr) - 2;
                            const offset_byte = std.math.cast(i8, offset) orelse return AssemblerError.ReferenceTooFar;

                            output[position] = @bitCast(offset_byte);
                        },
                        .absolute, .raw_absolute => {
                            mem.writeInt(u16, @ptrCast(output[position .. position + 2]), label.addr, .big);
                        },
                    }
                }
            }
        }
    };
}

const testing = std.testing;

test "assemble can assemble" {
    const alloc = testing.allocator;
    const A = Assembler(.{});
    var assembler: A = .init(alloc);
    defer assembler.deinit();
    var input: Io.Reader = .fixed("( hello.tal )\n|0100 LIT 68 LIT 18 DEO LIT 0a LIT 18 DEO\n");
    const expected_rom: [0x10a]u8 = [1]u8{0x00} ** 0x100 ++ [_]u8{ 0x80, 0x68, 0x80, 0x18, 0x17, 0x80, 0x0a, 0x80, 0x18, 0x17 };
    var output: [0x10a]u8 = [1]u8{0x00} ** 0x10a;
    try assembler.assemble(&input, &output);
    try testing.expect(std.mem.eql(u8, &output, &expected_rom));
}

test "assemble can assemble labels" {
    const alloc = testing.allocator;
    const A = Assembler(.{});
    var assembler: A = .init(alloc);
    defer assembler.deinit();
    var input: Io.Reader = .fixed("|10 @Console &vector $2 &read $1 &pad $5 &write $1 &error $1\n|0100 LIT 68 .Console/write DEO LIT 0a .Console/write DEO\n");
    const expected_rom: [0x10a]u8 = [1]u8{0x00} ** 0x100 ++ [_]u8{ 0x80, 0x68, 0x80, 0x18, 0x17, 0x80, 0x0a, 0x80, 0x18, 0x17 };
    var output: [0x10a]u8 = [1]u8{0x00} ** 0x10a;
    try assembler.assemble(&input, &output);
    try testing.expect(std.mem.eql(u8, &output, &expected_rom));
}
