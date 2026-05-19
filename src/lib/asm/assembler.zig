const std = @import("std");
const cpu = @import("uxn-core");
const scan = @import("scanner.zig");
const Io = std.Io;
const mem = std.mem;

pub const AssemblerError = error{
    MissingParentLabel,
    UndefinedLabel,
    TooManyLabels,
    LabelAlreadyDefined,
    ReferenceTooFar,
    TooManyMacros,
    InvalidMacro,
    UndefinedMacro,
};

pub fn Assembler(comptime lim: scan.Limits) type {
    return struct {
        pub const Scanner = scan.Scanner(lim);

        pub const LabelDef = struct {
            label: Scanner.LabelName,
            addr: ?u16,
            refs: std.ArrayListUnmanaged(Reference),
        };

        pub const ReferenceType = union(enum) { address: Scanner.AddressType, jump: void };

        pub const Reference = struct {
            addr: u16,
            type: ReferenceType,
        };

        pub const Macro = struct {
            name: Scanner.LabelName,
            body: std.ArrayListUnmanaged(Scanner.SourceToken),
        };

        alloc: mem.Allocator,
        rom_length: usize = 0,

        labels: std.ArrayListUnmanaged(LabelDef) = .empty,
        macros: std.ArrayListUnmanaged(Macro) = .empty,

        last_parent_label: ?Scanner.LabelName = null,

        pub fn init(alloc: mem.Allocator) @This() {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *@This()) void {
            for (self.labels.items) |*lbl| lbl.refs.deinit(self.alloc);
            for (self.macros.items) |*m| m.body.deinit(self.alloc);

            self.labels.deinit(self.alloc);
            self.macros.deinit(self.alloc);
        }

        pub fn assemble(self: *@This(), input: *Io.Reader, output: []u8) !void {
            var scanner = Scanner{};

            var output_writer: Io.Writer = .fixed(output);

            while (try scanner.readToken(input)) |token| {
                try self.processToken(&scanner, token, input, &output_writer);
            }

            self.rom_length = @truncate(output_writer.end);

            // std.debug.print("pre-resolve: {any}\n", .{output});

            try self.resolveReferences(output);
        }

        fn defineLabel(self: *@This(), label: Scanner.Label, addr: u16) !void {
            const def = try self.lookupOrCreateLabel(label);

            if (def.addr != null) {
                return AssemblerError.LabelAlreadyDefined;
            }

            def.addr = addr;
        }

        fn lookupLabel(self: *@This(), label_name: Scanner.LabelName) ?*LabelDef {
            for (self.labels.items) |*lbl| {
                if (mem.eql(u8, &label_name, &lbl.label)) {
                    return lbl;
                }
            }

            return null;
        }

        fn lookupOrCreateLabel(self: *@This(), label: Scanner.Label) !*LabelDef {
            const label_name = try self.resolveLabelName(label);

            if (self.lookupLabel(label_name)) |label_def| {
                return label_def;
            }

            const def = self.labels.addOne(self.alloc) catch return AssemblerError.TooManyLabels;

            def.* = LabelDef{ .addr = null, .label = label_name, .refs = .empty };

            return def;
        }

        fn processToken(self: *@This(), scanner: *Scanner, token: Scanner.SourceToken, input: *Io.Reader, output: *Io.Writer) !void {
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
                    const def = try self.lookupOrCreateLabel(address.label);

                    const ref = try def.refs.addOne(self.alloc);

                    const ref_addr: u16 = switch (address.type) {
                        .zero, .relative, .absolute => @truncate(output.end + 1),
                        .raw_zero, .raw_relative, .raw_absolute => @truncate(output.end),
                    };

                    ref.* = .{
                        .addr = ref_addr,
                        .type = ReferenceType{ .address = address.type },
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
                .macro_definition => |name| {
                    // Open curly after macro name declaration gets scanned as a JSI with label '{'
                    const open_curly = try scanner.readToken(input) orelse return AssemblerError.InvalidMacro;
                    if (open_curly.token != .jsi) return AssemblerError.InvalidMacro;

                    var body = std.ArrayListUnmanaged(Scanner.SourceToken).empty;

                    while (try scanner.readToken(input)) |tkn| {
                        if (tkn.token == .closing_curly)
                            break;

                        body.append(self.alloc, tkn) catch return AssemblerError.InvalidMacro;
                    }

                    self.macros.append(self.alloc, .{ .name = name, .body = body }) catch return AssemblerError.TooManyMacros;
                },
                .macro_usage => |name| {
                    const macro_def = for (self.macros.items) |mac| {
                        if (mem.eql(u8, &mac.name, &name))
                            break mac;
                    } else return AssemblerError.UndefinedMacro;

                    for (macro_def.body.items) |body_token| {
                        try self.processToken(scanner, body_token, input, output);
                    }
                },
                .jci => |label| {
                    const def = try self.lookupOrCreateLabel(label);
                    const ref = try def.refs.addOne(self.alloc);

                    try output.writeByte(0x20);

                    ref.* = .{
                        .addr = @truncate(output.end),
                        .type = .jump,
                    };

                    try output.writeInt(u16, 0xdbdb, .big);
                },
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
                .label => |lbl| if (self.lookupLabel(try self.resolveLabelName(lbl))) |l| l.addr orelse AssemblerError.UndefinedLabel else AssemblerError.UndefinedLabel,
            };
        }

        fn resolveReferences(self: *@This(), output: []u8) !void {
            for (self.labels.items) |label| {
                // std.debug.print("label: {any}\n", .{label});
                if (label.addr) |addr| {
                    for (label.refs.items) |ref| {
                        // std.debug.print("  ref: {any}\n", .{ref});
                        switch (ref.type) {
                            .address => |address| switch (address) {
                                .zero, .raw_zero => {
                                    output[ref.addr] = @truncate(addr);
                                },
                                .relative, .raw_relative => {
                                    const offset: i32 = @as(i32, addr) - @as(i32, ref.addr) - 2;
                                    const offset_byte = std.math.cast(i8, offset) orelse return AssemblerError.ReferenceTooFar;

                                    output[ref.addr] = @bitCast(offset_byte);
                                },
                                .absolute, .raw_absolute => {
                                    mem.writeInt(u16, @ptrCast(output[ref.addr .. ref.addr + 2]), addr, .big);
                                },
                            },
                            .jump => {
                                const offset: i32 = @as(i32, addr) - @as(i32, ref.addr) - 2;
                                const offset_short = std.math.cast(i16, offset) orelse return AssemblerError.ReferenceTooFar;

                                mem.writeInt(u16, @ptrCast(output[ref.addr .. ref.addr + 2]), @bitCast(offset_short), .big);
                            },
                        }
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

test "assemble can assemble macros" {
    const alloc = testing.allocator;
    const A = Assembler(.{});
    var assembler: A = .init(alloc);
    defer assembler.deinit();
    const program =
        \\|10 @Console &vector $2 &read $1 &pad $5 &write $1 &error $1
        \\%EMIT { .Console/write DEO }
        \\|0100 LIT "h EMIT
    ;
    var input: Io.Reader = .fixed(program);
    const expected_rom: [0x105]u8 = [1]u8{0x00} ** 0x100 ++ [_]u8{ 0x80, 0x68, 0x80, 0x18, 0x17 };
    var output: [0x105]u8 = [1]u8{0x00} ** 0x105;
    try assembler.assemble(&input, &output);
    try testing.expect(std.mem.eql(u8, &output, &expected_rom));
}

test "assemble can assemble jci with label" {
    const alloc = testing.allocator;
    const A = Assembler(.{});
    var assembler: A = .init(alloc);
    defer assembler.deinit();
    var input: Io.Reader = .fixed("#0a DUP ?label INC @label\n");
    const expected_rom: [0x07]u8 = [_]u8{ 0x80, 0x0a, 0x06, 0x20, 0x00, 0x01, 0x01 };
    var output: [0x07]u8 = [1]u8{0x00} ** 0x07;
    try assembler.assemble(&input, &output);
    // std.debug.print("output: {any}\n", .{output});
    try testing.expect(std.mem.eql(u8, &output, &expected_rom));
}
