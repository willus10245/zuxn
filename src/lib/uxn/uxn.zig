const std = @import("std");
const Opcode = @import("opcodes.zig").Opcode;

const logger = std.log.scoped(.uxn_cpu);

pub const Stack = struct {
    data: [0x100]u8 = @splat(0),
    sp: u8 = 0, // points to next empty slot

    pub fn pushByte(self: *Stack, val: u8) void {
        self.data[self.sp] = val;
        self.sp +%= 1;
    }

    pub fn popByte(self: *Stack) u8 {
        self.sp -%= 1;
        return self.data[self.sp];
    }

    pub fn peekByte(self: *Stack) u8 {
        return self.data[self.sp -% 1];
    }

    pub fn pushShort(self: *Stack, val: u16) void {
        self.pushByte(@intCast(val >> 8));
        self.pushByte(@intCast(val & 0xFF));
    }

    pub fn popShort(self: *Stack) u16 {
        const lsb = self.popByte();
        const msb = self.popByte();
        return (@as(u16, msb) << 8) | lsb;
    }

    pub fn peekShort(self: *Stack) u16 {
        const lsb = self.data[self.sp -% 1];
        const msb = self.data[self.sp -% 2];
        return (@as(u16, msb) << 8) | lsb;
    }

    pub fn push(self: *Stack, comptime T: type, val: T) void {
        switch (T) {
            u8 => self.pushByte(val),
            u16 => self.pushShort(val),
            else => unreachable,
        }
    }

    pub fn pop(self: *Stack, comptime T: type) T {
        return switch (T) {
            u8 => self.popByte(),
            u16 => self.popShort(),
            else => unreachable,
        };
    }

    pub fn peek(self: *Stack, comptime T: type) T {
        return switch (T) {
            u8 => self.peekByte(),
            u16 => self.peekShort(),
            else => unreachable,
        };
    }
};

pub const StackView = struct {
    stack: *Stack,
    keep: bool = false,
    pop_offset: u8 = 0, // how many bytes we've "popped" without moving ptr

    pub fn push(self: *StackView, comptime T: type, val: T) void {
        self.stack.push(T, val);
    }

    pub fn pop(self: *StackView, comptime T: type) T {
        if (self.keep) {
            defer self.pop_offset +%= @sizeOf(T);
            return switch (T) {
                u8 => self.stack.data[self.stack.sp -% 1 -% self.pop_offset],
                u16 => blk: {
                    const lsb = self.stack.data[self.stack.sp -% 1 -% self.pop_offset];
                    const msb = self.stack.data[self.stack.sp -% 2 -% self.pop_offset];
                    break :blk (@as(u16, msb) << 8) | lsb;
                },
                else => unreachable,
            };
        } else {
            return self.stack.pop(T);
        }
    }

    pub fn drop(self: *StackView, comptime T: type) void {
        if (!self.keep) self.stack.sp -%= @sizeOf(T);
    }
};

pub const page_count = 0x10;
pub const page_size = 0x10000; // 64kb
pub const device_page_size = 0x100;

pub const Uxn = struct {
    pages: [][page_size]u8,
    mem: *[page_size]u8,
    dev: [device_page_size]u8,
    wst: Stack,
    rst: Stack,
    pc: u16,

    intercept_ctx: *anyopaque = undefined,
    intercept_fn: ?*const fn (ctx: *anyopaque, uxn: *Uxn, port: u8, is_ouput: bool) void = null,

    op_sv: StackView,
    sec_sv: StackView,

    pub fn init(ram: []u8) Uxn {
        // ensure ram divides into full pages
        std.debug.assert(ram.len >= page_size and ram.len % page_size == 0);

        return Uxn{ .pages = @ptrCast(ram), .mem = @ptrCast(ram), .dev = @splat(0x00), .wst = Stack{}, .rst = Stack{}, .pc = 0x100, .op_sv = .{ .stack = undefined }, .sec_sv = .{ .stack = undefined } };
    }

    pub fn dumpStacks(self: *Uxn) void {
        const offset: u8 = 8;
        var buf: [3 * 8]u8 = undefined;
        var pos: usize = 0;

        pos = 0;
        var wst_i = self.wst.sp -% offset;
        while (wst_i != self.wst.sp) : (wst_i +%= 1) {
            const s = std.fmt.bufPrint(buf[pos..], "{x:0>2} ", .{self.wst.data[wst_i]}) catch break;
            pos += s.len;
        }
        logger.debug("WST [{s}] sp={d}", .{ std.mem.trimEnd(u8, buf[0..pos], " "), self.wst.sp });

        pos = 0;
        var rst_i = self.rst.sp -% offset;
        while (rst_i != self.rst.sp) : (rst_i +%= 1) {
            const s = std.fmt.bufPrint(buf[pos..], "{x:0>2} ", .{self.rst.data[rst_i]}) catch break;
            pos += s.len;
        }
        logger.debug("RST [{s}] sp={d}", .{ std.mem.trimEnd(u8, buf[0..pos], " "), self.rst.sp });
    }

    pub fn runVector(self: *Uxn, pc: u16) void {
        self.pc = pc;
        _ = self.run();
    }

    pub fn run(self: *Uxn) u1 {
        @setEvalBranchQuota(2048);

        if (self.pc == 0x00 or self.dev[0x0f] != 0x00) return 0;

        while (Opcode.fromByte(self.mem[self.pc]) != .BRK) {
            const op = Opcode.fromByte(self.mem[self.pc]);
            if (std.log.logEnabled(.debug, .uxn_cpu)) {
                self.dumpStacks();
            }
            logger.debug("PC {x:0>4}: executing {s}", .{ self.pc, op.mnemonic() });
            self.pc +%= 1;

            var op_stack: *Stack = undefined;
            var sec_stack: *Stack = undefined;
            if (op.returnMode()) {
                op_stack = &self.rst;
                sec_stack = &self.wst;
            } else {
                op_stack = &self.wst;
                sec_stack = &self.rst;
            }
            self.op_sv.stack = op_stack;
            self.op_sv.keep = op.keepMode();
            self.op_sv.pop_offset = 0;
            self.sec_sv.stack = sec_stack;
            self.sec_sv.keep = op.keepMode();
            self.sec_sv.pop_offset = 0;

            switch (op) {
                inline .LIT, .LIT2, .LITr, .LIT2r => |opcode| self.op_lit(opcode.operandType()),

                inline .JCI, .JMI, .JSI => |opcode| {
                    const offset = self.fetch(u16);

                    if (opcode == .JSI)
                        self.rst.pushShort(self.pc);

                    if (opcode != .JCI or self.wst.popByte() != 0x00)
                        self.pc +%= offset;
                },

                inline else => |opcode| {
                    const base_op = Opcode.baseOpcode(opcode);
                    const T = opcode.operandType();
                    switch (base_op) {
                        .BRK => unreachable,
                        // Stack shuffling
                        .INC => self.op_inc(T),
                        .POP => self.op_pop(T),
                        .NIP => self.op_nip(T),
                        .SWP => self.op_swp(T),
                        .ROT => self.op_rot(T),
                        .DUP => self.op_dup(T),
                        .OVR => self.op_ovr(T),
                        // Comparison
                        .EQU => self.op_equ(T),
                        .NEQ => self.op_neq(T),
                        .GTH => self.op_gth(T),
                        .LTH => self.op_lth(T),
                        // Contol flow
                        .JMP => self.op_jmp(T),
                        .JCN => self.op_jcn(T),
                        .JSR => self.op_jsr(T),
                        // Stack swap
                        .STH => self.op_sth(T),
                        // Load/store memory
                        .LDZ => self.op_ldz(T),
                        .STZ => self.op_stz(T),
                        .LDR => self.op_ldr(T),
                        .STR => self.op_str(T),
                        .LDA => self.op_lda(T),
                        .STA => self.op_sta(T),
                        // IO
                        .DEI => self.op_dei(T),
                        .DEO => self.op_deo(T),
                        // Arithemtic
                        .ADD => self.op_add(T),
                        .SUB => self.op_sub(T),
                        .MUL => self.op_mul(T),
                        .DIV => self.op_div(T),
                        // Bitwise
                        .AND => self.op_and(T),
                        .ORA => self.op_ora(T),
                        .EOR => self.op_eor(T),
                        .SFT => self.op_sft(T),
                    }
                },
            }
        }
        return 0;
    }

    fn load(self: *Uxn, comptime T: type, comptime field: []const u8, addr: anytype) T {
        if (T == u8) {
            return @field(self, field)[addr];
        } else if (T == u16) {
            const msb = @field(self, field)[addr];
            const lsb = @field(self, field)[addr +% 1];
            return (@as(u16, msb) << 8) | lsb;
        }
    }

    fn store(self: *Uxn, comptime T: type, comptime field: []const u8, addr: anytype, val: T) void {
        if (T == u8) {
            @field(self, field)[addr] = val;
        } else if (T == u16) {
            @field(self, field)[addr] = @intCast(val >> 8);
            @field(self, field)[addr +% 1] = @intCast(val & 0xFF);
        }
    }

    fn loadMem(self: *Uxn, comptime T: type, addr: u16) T {
        return self.load(T, "mem", addr);
    }

    fn loadZero(self: *Uxn, comptime T: type, addr: u8) T {
        return self.load(T, "mem", addr);
    }

    pub fn loadDevice(self: *Uxn, comptime T: type, addr: u8) T {
        return self.load(T, "dev", addr);
    }

    fn storeMem(self: *Uxn, comptime T: type, addr: u16, val: T) void {
        self.store(T, "mem", addr, val);
    }

    fn storeZero(self: *Uxn, comptime T: type, addr: u8, val: T) void {
        self.store(T, "mem", addr, val);
    }

    pub fn storeDevice(self: *Uxn, comptime T: type, addr: u8, val: T) void {
        self.store(T, "dev", addr, val);
    }

    fn relativeAddr(self: *const Uxn, offset: u8) u16 {
        const signed: i8 = @bitCast(offset);
        return self.pc +% @as(u16, @bitCast(@as(i16, signed)));
    }

    fn fetch(self: *Uxn, comptime T: type) T {
        defer self.pc +%= @sizeOf(T);

        return self.loadMem(T, self.pc);
    }

    // Op Codes
    fn op_inc(self: *Uxn, comptime T: type) void {
        const val = self.op_sv.pop(T);
        self.op_sv.push(T, val +% 1);
    }

    fn op_pop(self: *Uxn, comptime T: type) void {
        _ = self.op_sv.pop(T);
    }

    fn op_nip(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        _ = self.op_sv.pop(T);
        self.op_sv.push(T, b);
    }

    fn op_swp(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, b);
        self.op_sv.push(T, a);
    }

    fn op_rot(self: *Uxn, comptime T: type) void {
        const c = self.op_sv.pop(T);
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, b);
        self.op_sv.push(T, c);
        self.op_sv.push(T, a);
    }

    fn op_dup(self: *Uxn, comptime T: type) void {
        const val = self.op_sv.pop(T);
        self.op_sv.push(T, val);
        self.op_sv.push(T, val);
    }

    fn op_ovr(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a);
        self.op_sv.push(T, b);
        self.op_sv.push(T, a);
    }

    fn op_equ(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(u8, @intFromBool(a == b));
    }

    fn op_neq(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(u8, @intFromBool(a != b));
    }

    fn op_gth(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(u8, @intFromBool(a > b));
    }

    fn op_lth(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(u8, @intFromBool(a < b));
    }

    fn op_jmp(self: *Uxn, comptime T: type) void {
        const operand = self.op_sv.pop(T);

        switch (T) {
            u8 => {
                self.pc = self.relativeAddr(operand);
            },
            u16 => self.pc = operand,
            else => unreachable,
        }
    }

    fn op_jcn(self: *Uxn, comptime T: type) void {
        const operand = self.op_sv.pop(T);

        if (self.op_sv.pop(u8) != 0x00) {
            switch (T) {
                u8 => {
                    self.pc = self.relativeAddr(operand);
                },
                u16 => self.pc = operand,
                else => unreachable,
            }
        }
    }

    fn op_jsr(self: *Uxn, comptime T: type) void {
        const operand = self.op_sv.pop(T);

        self.sec_sv.push(u16, self.pc);

        switch (T) {
            u8 => {
                self.pc = self.relativeAddr(operand);
            },
            u16 => self.pc = operand,
            else => unreachable,
        }
    }

    fn op_sth(self: *Uxn, comptime T: type) void {
        const a = self.op_sv.pop(T);
        self.sec_sv.push(T, a);
    }

    fn op_ldz(self: *Uxn, comptime T: type) void {
        const addr = self.op_sv.pop(u8);
        const val = self.loadZero(T, addr);
        self.op_sv.push(T, val);
    }

    fn op_stz(self: *Uxn, comptime T: type) void {
        const addr = self.op_sv.pop(u8);
        const val = self.op_sv.pop(T);
        self.storeZero(T, addr, val);
    }

    fn op_ldr(self: *Uxn, comptime T: type) void {
        const addr = self.relativeAddr(self.op_sv.pop(u8));
        const val = self.loadMem(T, addr);
        self.op_sv.push(T, val);
    }

    fn op_str(self: *Uxn, comptime T: type) void {
        const addr = self.relativeAddr(self.op_sv.pop(u8));
        const val = self.op_sv.pop(T);
        self.storeMem(T, addr, val);
    }

    fn op_lda(self: *Uxn, comptime T: type) void {
        const addr = self.op_sv.pop(u16);
        const val = self.loadMem(T, addr);
        self.op_sv.push(T, val);
    }

    fn op_sta(self: *Uxn, comptime T: type) void {
        const addr = self.op_sv.pop(u16);
        const val = self.op_sv.pop(T);
        self.storeMem(T, addr, val);
    }

    fn op_dei(self: *Uxn, comptime T: type) void {
        const dev_addr = self.op_sv.stack.peek(u8);
        if (self.intercept_fn) |f| {
            f(self.intercept_ctx, self, dev_addr, false);
            if (T == u16) {
                f(self.intercept_ctx, self, dev_addr +% 1, false);
            }
        }
        const val = self.loadDevice(T, dev_addr);
        self.op_sv.drop(u8);
        self.op_sv.push(T, val);
    }

    fn op_deo(self: *Uxn, comptime T: type) void {
        const dev_addr = self.op_sv.pop(u8);
        const val = self.op_sv.pop(T);
        self.storeDevice(T, dev_addr, val);
        if (self.intercept_fn) |f| {
            f(self.intercept_ctx, self, dev_addr, true);
            if (T == u16) {
                f(self.intercept_ctx, self, dev_addr +% 1, true);
            }
        }
    }

    fn op_add(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a +% b);
    }

    fn op_sub(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a -% b);
    }

    fn op_mul(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a *% b);
    }

    fn op_div(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, if (b == 0) 0 else a / b);
    }

    fn op_and(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a & b);
    }

    fn op_ora(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a | b);
    }

    fn op_eor(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        self.op_sv.push(T, a ^ b);
    }

    fn op_sft(self: *Uxn, comptime T: type) void {
        const b = self.op_sv.pop(u8);
        const a = self.op_sv.pop(T);
        const lsft: u4 = @truncate(b >> 4);
        const rsft: u4 = @truncate(b & 0xF);
        self.op_sv.push(T, @truncate((@as(u32, a) >> rsft) << lsft));
    }

    fn op_lit(self: *Uxn, comptime T: type) void {
        self.op_sv.push(T, self.fetch(T));
    }
};

const testing = std.testing;

fn load(uxn: *Uxn, addr: u16, bytes: []const u8) void {
    @memcpy(uxn.mem[addr..][0..bytes.len], bytes);
}

/// Loads `program` at 0x0100 into zeroed memory and runs it until BRK.
fn runProgram(uxn: *Uxn, program: []const u8) void {
    load(uxn, 0x0100, program);
    uxn.runVector(0x0100);
}

/// Checks both stacks, listed from the bottom of the stack to the top.
fn expectStacks(uxn: *const Uxn, wst: []const u8, rst: []const u8) !void {
    try testing.expectEqualSlices(u8, wst, uxn.wst.data[0..uxn.wst.sp]);
    try testing.expectEqualSlices(u8, rst, uxn.rst.data[0..uxn.rst.sp]);
}

test "ADD adds bytes" {
    // #01 #02 ADD
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0x01, 0x80, 0x02, 0x18 });
    try expectStacks(&uxn, &.{0x03}, &.{});
}

test "short mode operates on two bytes" {
    // #1234 #0001 ADD2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0x12, 0x34, 0xa0, 0x00, 0x01, 0x38 });
    try expectStacks(&uxn, &.{ 0x12, 0x35 }, &.{});
}

test "keep mode leaves operands on the stack" {
    // #01 #02 ADDk
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0x01, 0x80, 0x02, 0x98 });
    try expectStacks(&uxn, &.{ 0x01, 0x02, 0x03 }, &.{});
}

test "return mode operates on the return stack" {
    // LITr 05 INCr
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xc0, 0x05, 0x41 });
    try expectStacks(&uxn, &.{}, &.{0x06});
}

test "STH moves a value to the other stack" {
    // #07 STH
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0x07, 0x0f });
    try expectStacks(&uxn, &.{}, &.{0x07});
}

test "JSI pushes the return address and jumps" {
    // JSI +0001, BRK, #2a
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x60, 0x00, 0x01, 0x00, 0x80, 0x2a });
    try expectStacks(&uxn, &.{0x2a}, &.{ 0x01, 0x03 });
}

test "STZ and LDZ round trip through the zero page" {
    // #aa #10 STZ #10 LDZ
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0xaa, 0x80, 0x10, 0x11, 0x80, 0x10, 0x10 });
    try testing.expectEqual(0xaa, uxn.mem[0x10]);
    try expectStacks(&uxn, &.{0xaa}, &.{});
}

test "DIV by zero gives zero" {
    // #05 #00 DIV
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0x05, 0x80, 0x00, 0x1b });
    try expectStacks(&uxn, &.{0x00}, &.{});
}

test "SFT shifts right then left" {
    // #34 #12 SFT: right by 2 gives 0d, then left by 1 gives 1a
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0x34, 0x80, 0x12, 0x1f });
    try expectStacks(&uxn, &.{0x1a}, &.{});
}

test "SFT2 uses a one byte shift" {
    // #1234 #10 SFT2: the shift is a byte even in short mode,
    // so 1234 shifts left by 1 to give 2468
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0x12, 0x34, 0x80, 0x10, 0x3f });
    try expectStacks(&uxn, &.{ 0x24, 0x68 }, &.{});
}

test "SFT clears a byte when shifting right by 8 or more" {
    // #ff #08 SFT
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0xff, 0x80, 0x08, 0x1f });
    try expectStacks(&uxn, &.{0x00}, &.{});
}

test "SFT clears a byte when shifting left by 8 or more" {
    // #ff #80 SFT
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0x80, 0xff, 0x80, 0x80, 0x1f });
    try expectStacks(&uxn, &.{0x00}, &.{});
}

test "SFT2 shifts a short left by up to 15" {
    // #ffff #f0 SFT2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0xff, 0xff, 0x80, 0xf0, 0x3f });
    try expectStacks(&uxn, &.{ 0x80, 0x00 }, &.{});
}

test "SFT2k keeps the short and the one byte shift" {
    // #1234 #10 SFT2k
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0x12, 0x34, 0x80, 0x10, 0xbf });
    try expectStacks(&uxn, &.{ 0x12, 0x34, 0x10, 0x24, 0x68 }, &.{});
}

test "LDA2 wraps around the end of memory" {
    // #ffff LDA2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    const program = [_]u8{ 0xa0, 0xff, 0xff, 0x34 };
    load(&uxn, 0x0100, &program);
    uxn.mem[0xffff] = 0xab;
    uxn.mem[0x0000] = 0xcd;
    uxn.runVector(0x0100);
    try expectStacks(&uxn, &.{ 0xab, 0xcd }, &.{});
}

test "STA2 wraps around the end of memory" {
    // #abcd #ffff STA2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0xab, 0xcd, 0xa0, 0xff, 0xff, 0x35 });
    try testing.expectEqual(0xab, uxn.mem[0xffff]);
    try testing.expectEqual(0xcd, uxn.mem[0x0000]);
}

/// Intercept handler that records each port it sees. On input it writes the
/// port number to that port, so a test can tell the device updated it.
const PortRecorder = struct {
    ports: [4]u8 = undefined,
    len: usize = 0,

    fn intercept(ctx: *anyopaque, uxn: *Uxn, port: u8, is_output: bool) void {
        const self: *PortRecorder = @ptrCast(@alignCast(ctx));
        self.ports[self.len] = port;
        self.len += 1;
        if (!is_output) uxn.dev[port] = port;
    }

    fn seen(self: *const PortRecorder) []const u8 {
        return self.ports[0..self.len];
    }
};

/// Runs `program` from 0x0100 with `recorder` attached as the intercept handler.
fn runRecorded(uxn: *Uxn, recorder: *PortRecorder, program: []const u8) void {
    uxn.intercept_ctx = recorder;
    uxn.intercept_fn = PortRecorder.intercept;
    runProgram(uxn, program);
}

test "DEI2 intercepts both ports in order before reading them" {
    // #c4 DEI2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = PortRecorder{};
    runRecorded(&uxn, &recorder, &.{ 0x80, 0xc4, 0x36 });
    try testing.expectEqualSlices(u8, &.{ 0xc4, 0xc5 }, recorder.seen());
    try expectStacks(&uxn, &.{ 0xc4, 0xc5 }, &.{});
}

test "DEO2 stores both bytes and intercepts both ports in order" {
    // #1234 #c4 DEO2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = PortRecorder{};
    runRecorded(&uxn, &recorder, &.{ 0xa0, 0x12, 0x34, 0x80, 0xc4, 0x37 });
    try testing.expectEqualSlices(u8, &.{ 0xc4, 0xc5 }, recorder.seen());
    try testing.expectEqual(0x12, uxn.dev[0xc4]);
    try testing.expectEqual(0x34, uxn.dev[0xc5]);
    try expectStacks(&uxn, &.{}, &.{});
}

test "DEI2 on port ff wraps to port 00" {
    // #ff DEI2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = PortRecorder{};
    runRecorded(&uxn, &recorder, &.{ 0x80, 0xff, 0x36 });
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00 }, recorder.seen());
    try expectStacks(&uxn, &.{ 0xff, 0x00 }, &.{});
}

test "DEO2 on port ff wraps to port 00" {
    // #1234 #ff DEO2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = PortRecorder{};
    runRecorded(&uxn, &recorder, &.{ 0xa0, 0x12, 0x34, 0x80, 0xff, 0x37 });
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00 }, recorder.seen());
    try testing.expectEqual(0x12, uxn.dev[0xff]);
    try testing.expectEqual(0x34, uxn.dev[0x00]);
}

const SpRecorder = struct {
    wst_sp: u8 = 0,
    rst_sp: u8 = 0,

    fn intercept(ctx: *anyopaque, uxn: *Uxn, port: u8, is_output: bool) void {
        _ = port;
        _ = is_output;
        const self: *SpRecorder = @ptrCast(@alignCast(ctx));
        self.wst_sp = uxn.wst.sp;
        self.rst_sp = uxn.rst.sp;
    }
};

test "DEI intercept runs before port is popped" {
    // #12 #34 DEI
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = SpRecorder{};
    const program = [_]u8{ 0x80, 0x12, 0x80, 0x34, 0x16 };
    load(&uxn, 0x0100, &program);
    uxn.intercept_ctx = &recorder;
    uxn.intercept_fn = SpRecorder.intercept;
    uxn.runVector(0x0100);

    try testing.expectEqual(2, recorder.wst_sp);
    try expectStacks(&uxn, &.{ 0x12, 0x00 }, &.{});
}

test "DEIr intercept runs before port is popped" {
    // LITr 12 LITr 34 DEIr
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = SpRecorder{};
    const program = [_]u8{ 0xc0, 0x12, 0xc0, 0x34, 0x56 };
    load(&uxn, 0x0100, &program);
    uxn.intercept_ctx = &recorder;
    uxn.intercept_fn = SpRecorder.intercept;
    uxn.runVector(0x0100);

    try testing.expectEqual(2, recorder.rst_sp);
    try expectStacks(&uxn, &.{}, &.{ 0x12, 0x00 });
}

test "DEIk intercept runs before port is popped" {
    // #12 #34 DEIk
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    var recorder = SpRecorder{};
    const program = [_]u8{ 0x80, 0x12, 0x80, 0x34, 0x96 };
    load(&uxn, 0x0100, &program);
    uxn.intercept_ctx = &recorder;
    uxn.intercept_fn = SpRecorder.intercept;
    uxn.runVector(0x0100);

    try testing.expectEqual(2, recorder.wst_sp);
    try expectStacks(&uxn, &.{ 0x12, 0x34, 0x00 }, &.{});
}

test "LDZ2 wraps around the end of the zero page" {
    // #ab #ff STZ #cd #00 STZ #ff LDZ2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{
        0x80, 0xab, 0x80, 0xff, 0x11,
        0x80, 0xcd, 0x80, 0x00, 0x11,
        0x80, 0xff, 0x30,
    });
    try expectStacks(&uxn, &.{ 0xab, 0xcd }, &.{});
}

test "STZ2 wraps around the end of the zero page" {
    // #abcd #ff STZ2
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    runProgram(&uxn, &.{ 0xa0, 0xab, 0xcd, 0x80, 0xff, 0x31 });
    try testing.expectEqual(0xab, uxn.mem[0xff]);
    try testing.expectEqual(0xcd, uxn.mem[0x00]);
}

test "forward jump with relative addressing wraps correctly around the midpoint of memory" {
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    const part1 = [_]u8{ 0x80, 0x01, 0x0c };
    const part2 = [_]u8{ 0x80, 0x2a };
    load(&uxn, 0x7ffc, &part1);
    load(&uxn, 0x8000, &part2);
    // @memcpy(uxn.mem[0x7ffc..][0..part1.len], &part1);
    // @memcpy(uxn.mem[0x8000..][0..part2.len], &part2);
    uxn.runVector(0x7ffc);
    try expectStacks(&uxn, &.{0x2a}, &.{});
}

test "backward jump with relative addressing wraps correctly around the midpoint of memory" {
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    const part1 = [_]u8{ 0x80, 0x2a, 0x00 };
    const part2 = [_]u8{ 0x80, 0xf9, 0x0c };
    load(&uxn, 0x7ffc, &part1);
    load(&uxn, 0x8000, &part2);
    // @memcpy(uxn.mem[0x7ffc..][0..part1.len], &part1);
    // @memcpy(uxn.mem[0x8000..][0..part2.len], &part2);
    uxn.runVector(0x8000);
    try expectStacks(&uxn, &.{0x2a}, &.{});
}

test "load with relative addressing wraps correctly around the midpoint of memory" {
    var ram: [page_size]u8 = @splat(0);
    var uxn = Uxn.init(&ram);
    const part1 = [_]u8{ 0x80, 0x01, 0x12 };
    const part2 = [_]u8{0x2a};
    load(&uxn, 0x7ffc, &part1);
    load(&uxn, 0x8000, &part2);
    // @memcpy(uxn.mem[0x7ffc..][0..part1.len], &part1);
    // @memcpy(uxn.mem[0x8000..][0..part2.len], &part2);
    uxn.runVector(0x7ffc);
    try expectStacks(&uxn, &.{0x2a}, &.{});
}
