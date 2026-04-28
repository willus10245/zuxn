const std = @import("std");
const cpu = @import("uxn-core");
const ascii = std.ascii;
const Io = std.Io;

pub const Limits = struct {
    identifier_length: usize = 64,
    word_length: usize = 64,
};

pub const ScanError = error{
    IdentifierTooLong,
    InvalidHexLiteral,
    PrematureEOF,
    UppercaseLabel,
};

pub fn Scanner(comptime lim: Limits) type {
    return struct {
        pub const limits = lim;

        pub const Literal = union(enum) { byte: u8, short: u16 };

        pub const LabelName = [limits.identifier_length:0]u8;

        pub const Label = union(enum) { parent: LabelName, child: LabelName };

        pub const AddressType = union(enum) {
            zero,
            relative,
            absolute,
            raw_zero,
            raw_relative,
            raw_absolute,
        };

        pub const Address = struct {
            type: AddressType,
            label: Label,
        };

        pub const Instruction = struct {
            mnemonic: []const u8,
            opcode: u8,
        };

        pub const Offset = union(enum) {
            literal: u16,
            label: Label,
        };

        pub const Padding = union(enum) {
            absolute: Offset,
            relative: Offset,
        };

        pub const Location = struct {
            line: usize,
            c: usize,
        };

        location: Location = .{ .line = 1, .c = 1 },

        pub const Token = union(enum) {
            instruction: Instruction,
            literal: Literal,
            raw_literal: Literal,
            address: Address,
            padding: Padding,
            label: Label,
            jci: Label,
            jmi: Label,
            jsi: Label,
            closing_curly: void,
            word: [limits.word_length:0]u8,
        };

        pub const SourceToken = struct {
            start: Location,
            end: Location,

            token: Token,
        };

        fn toLabel(label_name: LabelName) Label {
            if (label_name[0] == '&' or label_name[0] == '/') {
                var cpy = label_name;

                std.mem.copyForwards(u8, &cpy, cpy[1..]);

                return .{ .child = cpy };
            } else {
                return .{ .parent = label_name };
            }
        }

        fn parseHexDigit(byte: u8) !u4 {
            if (!ascii.isHex(byte) or (!ascii.isDigit(byte) and !ascii.isLower(byte))) {
                return ScanError.InvalidHexLiteral;
            }

            return @truncate(std.fmt.charToDigit(byte, 16) catch unreachable);
        }

        fn parseHexNumber(comptime T: type, raw: []const u8, fixed_width: bool) !T {
            if (fixed_width) {
                const w = if (T == u8) 2 else if (T == u16) 4 else unreachable;

                if (raw.len != w)
                    return error.InvalidHexLiteral;
            }

            for (raw) |byte| {
                if (!ascii.isHex(byte) or (!ascii.isDigit(byte) and !ascii.isLower(byte))) {
                    return ScanError.InvalidHexLiteral;
                }
            }

            const result = std.fmt.parseInt(T, raw, 16) catch unreachable;
            return result;
        }

        fn readByte(self: *@This(), input: *Io.Reader) ?u8 {
            const byte = input.takeByte() catch return null;

            if (byte == '\n') {
                self.location.line += 1;
                self.location.c = 1;
            } else {
                self.location.c += 1;
            }

            return byte;
        }

        fn readHexDigit(self: *@This(), input: *Io.Reader) ScanError!?u4 {
            const byte = self.readByte(input) orelse return null;
            return try parseHexDigit(byte);
        }

        fn readLabel(self: *@This(), input: *Io.Reader) ScanError!LabelName {
            const label = try self.readToWhitespace(limits.identifier_length, input);

            for (label) |byte| {
                if (ascii.isLower(byte) or !ascii.isAlphanumeric(byte)) {
                    break;
                } else return ScanError.UppercaseLabel;
            }

            return label;
        }

        fn readLiteral(self: *@This(), input: *Io.Reader) ScanError!Literal {
            const h_byte_0: u8 = try self.readHexDigit(input) orelse return ScanError.PrematureEOF;
            const l_byte_0: u8 = try self.readHexDigit(input) orelse return ScanError.PrematureEOF;

            const next = self.readByte(input) orelse ' ';

            const h_byte_1: u8 = if (ascii.isWhitespace(next))
                return Literal{ .byte = @as(u8, h_byte_0 << 4) | l_byte_0 }
            else
                try parseHexDigit(next);

            const l_byte_1: u8 = try self.readHexDigit(input) orelse return ScanError.PrematureEOF;

            return Literal{ .short = @as(u16, h_byte_0) << 12 |
                @as(u16, l_byte_0) << 8 |
                @as(u16, h_byte_1) << 4 |
                @as(u16, l_byte_1) };
        }

        fn readToWhitespace(self: *@This(), comptime max: usize, input: *Io.Reader) ScanError![max:0]u8 {
            var output = [1:0]u8{0} ** max;
            var output_writer = Io.Writer.fixed(&output);

            while (true) {
                const byte = self.readByte(input) orelse ' ';

                if (ascii.isWhitespace(byte))
                    break;

                output_writer.writeByte(byte) catch {
                    return ScanError.IdentifierTooLong;
                };
            }

            return output;
        }

        pub fn readToken(self: *@This(), input: *Io.Reader) ScanError!?SourceToken {
            var comment_depth: usize = 0;

            while (self.readByte(input)) |b| {
                if (comment_depth > 0 and b != '(' and b != ')')
                    continue;

                if (ascii.isWhitespace(b))
                    continue;

                var start = self.location;
                start.c -= 1;

                var end: Location = undefined;

                const token: Token = switch (b) {
                    '(' => {
                        comment_depth += 1;
                        continue;
                    },
                    ')' => {
                        comment_depth -= 1;
                        continue;
                    },

                    '[', ']' => continue,

                    '@', '&' => blk: {
                        const label_name = try self.readLabel(input);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&label_name, 0).len };

                        break :blk if (b == '@')
                            .{ .label = .{ .parent = label_name } }
                        else
                            .{ .label = .{ .child = label_name } };
                    },

                    '#' => blk: {
                        const literal = try self.readLiteral(input);
                        const length: usize = switch (literal) {
                            .byte => 2,
                            .short => 4,
                        };

                        end = Location{ .line = start.line, .c = start.c + length };

                        break :blk .{ .literal = literal };
                    },

                    '|', '$' => blk: {
                        const pad = try self.readToWhitespace(limits.identifier_length, input);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&pad, 0).len };

                        const offset: Offset = if (parseHexNumber(u16, std.mem.sliceTo(&pad, 0), false) catch null) |lit|
                            .{ .literal = lit }
                        else
                            .{ .label = toLabel(pad) };

                        break :blk if (b == '|')
                            .{ .padding = .{ .absolute = offset } }
                        else
                            .{ .padding = .{ .relative = offset } };
                    },

                    ',', '.', ';', '_', '-', '=' => blk: {
                        const label_name = try self.readLabel(input);
                        const label = toLabel(label_name);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&label_name, 0).len };

                        break :blk .{ .address = .{ .label = label, .type = switch (b) {
                            ',' => .relative,
                            '.' => .zero,
                            ';' => .absolute,
                            '_' => .raw_relative,
                            '-' => .raw_zero,
                            '=' => .raw_absolute,
                            else => unreachable,
                        } } };
                    },

                    '?' => blk: {
                        const label_name = try self.readLabel(input);
                        const label = toLabel(label_name);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&label_name, 0).len };

                        break :blk .{ .jci = label };
                    },

                    '!' => blk: {
                        const label_name = try self.readLabel(input);
                        const label = toLabel(label_name);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&label_name, 0).len };

                        break :blk .{ .jmi = label };
                    },

                    '}' => blk: {
                        end = Location{ .line = start.line, .c = start.c + 1 };

                        break :blk .closing_curly;
                    },

                    '"' => blk: {
                        var word = [1:0]u8{0x00} ** limits.word_length;
                        var i: usize = 0;

                        while (self.readByte(input)) |byte| : (i += 1) {
                            if (ascii.isWhitespace(byte)) break;

                            word[i] = byte;
                        }

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&word, 0).len };

                        break :blk .{ .word = word };
                    },

                    else => blk: {
                        var needle_buffer = [1:0]u8{b} ++ [1:0]u8{0x00} ** (limits.identifier_length - 1);
                        const rest = try self.readToWhitespace(limits.identifier_length, input);

                        end = Location{ .line = start.line, .c = start.c + std.mem.sliceTo(&rest, 0).len };

                        for (std.mem.sliceTo(&rest, 0), 1..) |byte, i|
                            needle_buffer[i] = byte;

                        if (std.meta.stringToEnum(cpu.opcodes.Opcode, std.mem.sliceTo(&needle_buffer, 0))) |opcode| {
                            break :blk .{ .instruction = .{ .mnemonic = @tagName(opcode), .opcode = @intFromEnum(opcode) } };
                        } else {
                            const needle = std.mem.sliceTo(&needle_buffer, 0);

                            break :blk if (parseHexNumber(u8, needle, true) catch null) |byte|
                                .{ .raw_literal = .{ .byte = byte } }
                            else if (parseHexNumber(u16, needle, true) catch null) |short|
                                .{ .raw_literal = .{ .short = short } }
                            else
                                unreachable;
                        }
                    },
                };

                return .{ .start = start, .end = end, .token = token };
            }

            return null;
        }
    };
}

const testing = std.testing;

test "readByte returns next byte of input" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("LIT #68");
    try testing.expectEqual('L', scanner.readByte(&r));
}

test "readByte returns null at end of stream" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("");
    try testing.expectEqual(@as(?u8, null), scanner.readByte(&r));
}

test "readByte advances column" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("LIT #68");
    _ = scanner.readByte(&r);
    try testing.expectEqual(S.Location{ .line = 1, .c = 2 }, scanner.location);
}

test "readByte increments line and reset column on newline" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("\n");
    _ = scanner.readByte(&r);
    try testing.expectEqual(S.Location{ .line = 2, .c = 1 }, scanner.location);
}

test "readToken skips whitespace" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed(" ");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(@as(?S.SourceToken, null), token);
}

test "readToken skips comments" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("( i'm a comment )");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(@as(?S.SourceToken, null), token);
}

test "readToken handles nested comments" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("( ( i'm a comment in a comment ) )");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(@as(?S.SourceToken, null), token);
}

test "readToken skips square brackets" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("[]");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(@as(?S.SourceToken, null), token);
}

test "readToken reads literal hex numbers" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("#78 #9abc");
    const first = try scanner.readToken(&r);
    const second = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .literal = S.Literal{ .byte = 0x78 } }, first.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, first.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 3 }, first.?.end);
    try testing.expectEqual(S.Token{ .literal = S.Literal{ .short = 0x9ABC } }, second.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 5 }, second.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 9 }, second.?.end);
}

test "readToken reads raw hex numbers" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("78 9abc");
    const first = try scanner.readToken(&r);
    const second = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .raw_literal = S.Literal{ .byte = 0x78 } }, first.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, first.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 2 }, first.?.end);
    try testing.expectEqual(S.Token{ .raw_literal = S.Literal{ .short = 0x9ABC } }, second.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 4 }, second.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 7 }, second.?.end);
}

test "readToken reads absolute padding with literal" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("|100");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .padding = S.Padding{ .absolute = S.Offset{ .literal = 0x0100 } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 4 }, token.?.end);
}

test "readToken reads relative padding with literal" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("$1c");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .padding = S.Padding{ .relative = S.Offset{ .literal = 0x01c } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 3 }, token.?.end);
}

test "readToken reads relative padding with label" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("$label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .padding = S.Padding{ .relative = S.Offset{ .label = .{ .parent = labelName("label") } } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads relative address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed(",label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .relative, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads relative address with sublabel" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed(",&sublabel");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .relative, .label = .{ .child = labelName("sublabel") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 10 }, token.?.end);
}

test "readToken reads zero-page address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed(".label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .zero, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads absolute address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed(";label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .absolute, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads raw relative address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("_label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .raw_relative, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads raw zero-page address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("-label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .raw_zero, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads raw absolute address" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("=label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .address = S.Address{ .type = .raw_absolute, .label = .{ .parent = labelName("label") } } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads parent label" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("@label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .label = .{ .parent = labelName("label") } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads child label" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("&sublabel");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .label = .{ .child = labelName("sublabel") } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 9 }, token.?.end);
}

test "readToken reads jci instruction" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("?label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .jci = .{ .parent = labelName("label") } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads jmi instruction" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("!label");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .jmi = .{ .parent = labelName("label") } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads end of lambda" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("}");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token.closing_curly, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 2 }, token.?.end);
}

test "readToken reads word" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("\"hello");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .word = makeWord("hello") }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 6 }, token.?.end);
}

test "readToken reads instructions" {
    const S = Scanner(.{});
    var scanner: S = .{};
    var r: Io.Reader = .fixed("DEO");
    const token = try scanner.readToken(&r);
    try testing.expectEqual(S.Token{ .instruction = .{ .mnemonic = "DEO", .opcode = 0x17 } }, token.?.token);
    try testing.expectEqual(S.Location{ .line = 1, .c = 1 }, token.?.start);
    try testing.expectEqual(S.Location{ .line = 1, .c = 3 }, token.?.end);
}

fn labelName(comptime s: []const u8) Scanner(.{}).LabelName {
    var buf = std.mem.zeroes(Scanner(.{}).LabelName);
    @memcpy(buf[0..s.len], s);
    return buf;
}

fn makeWord(comptime s: []const u8) [Scanner(.{}).limits.word_length:0]u8 {
    var buf = std.mem.zeroes([Scanner(.{}).limits.word_length:0]u8);
    @memcpy(buf[0..s.len], s);
    return buf;
}
