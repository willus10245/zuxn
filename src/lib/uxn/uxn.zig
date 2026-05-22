const std = @import("std");
const Opcode = @import("opcodes.zig").Opcode;

const logger = std.log.scoped(.uxn_cpu);

pub const Stack = struct {
    data: [0x100]u8 = [_]u8{0} ** 0x100,
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
};

pub const Uxn = struct {
    mem: [0x10000]u8 = [_]u8{0} ** 0x10000, // 64kb
    dev: [0x100]u8 = [_]u8{0} ** 0x100,
    wst: Stack = Stack{},
    rst: Stack = Stack{},
    pc: u16 = 0x0100,

    intercept_ctx: *anyopaque = undefined,
    intercept_fn: ?*const fn (ctx: *anyopaque, uxn: *Uxn, port: u8, is_ouput: bool) void = null,

    op_sv: StackView = .{ .stack = undefined },
    sec_sv: StackView = .{ .stack = undefined },

    pub fn init() Uxn {
        var uxn = Uxn{};
        uxn.mem = [_]u8{0} ** 0x100 ++ [_]u8{ 0x80, 0x68, 0x80, 0x18, 0x17, 0x80, 0x0a, 0x80, 0x18, 0x17 } ++ [_]u8{0} ** 0xFEF6;
        return uxn;
    }

    fn dumpStacks(self: *Uxn) void {
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
            self.dumpStacks();
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
            return std.mem.readInt(T, @as(*const [2]u8, @ptrCast(@field(self, field)[addr..addr +| 2])), .big);
        }
    }

    fn store(self: *Uxn, comptime T: type, comptime field: []const u8, addr: anytype, val: T) void {
        if (T == u8) {
            @field(self, field)[addr] = val;
        } else if (T == u16) {
            std.mem.writeInt(T, @as(*[2]u8, @ptrCast(@field(self, field)[addr..addr +| 2])), val, .big);
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
                const offset: i8 = @bitCast(operand);
                const new_addr: i16 = @as(i16, @bitCast(self.pc)) + offset;
                self.pc = @bitCast(new_addr);
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
                    const offset: i8 = @bitCast(operand);
                    const new_addr: i16 = @as(i16, @bitCast(self.pc)) + offset;
                    self.pc = @bitCast(new_addr);
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
                const offset: i8 = @bitCast(operand);
                const new_addr: i16 = @as(i16, @bitCast(self.pc)) + offset;
                self.pc = @bitCast(new_addr);
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
        const offset: i8 = @bitCast(self.op_sv.pop(u8));
        const addr: i16 = @as(i16, @bitCast(self.pc)) + offset;
        const val = self.loadMem(T, @bitCast(addr));
        self.op_sv.push(T, val);
    }

    fn op_str(self: *Uxn, comptime T: type) void {
        const offset: i8 = @bitCast(self.op_sv.pop(u8));
        const addr: i16 = @as(i16, @bitCast(self.pc)) + offset;
        const val = self.op_sv.pop(T);
        self.storeMem(T, @bitCast(addr), val);
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
        const dev_addr = self.op_sv.pop(u8);
        if (self.intercept_fn) |f| {
            f(self.intercept_ctx, self, dev_addr, false);
        }
        const val = self.loadDevice(T, dev_addr);
        self.op_sv.push(T, val);
    }

    fn op_deo(self: *Uxn, comptime T: type) void {
        const dev_addr = self.op_sv.pop(u8);
        const val = self.op_sv.pop(T);
        self.storeDevice(T, dev_addr, val);
        if (self.intercept_fn) |f| {
            f(self.intercept_ctx, self, dev_addr, true);
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
        const b = self.op_sv.pop(T);
        const a = self.op_sv.pop(T);
        const ShiftT = std.math.Log2Int(T);
        const lsft: ShiftT = @truncate(b >> 4);
        const rsft: ShiftT = @truncate(b & 0xF);
        self.op_sv.push(T, (a >> rsft) << lsft);
    }

    fn op_lit(self: *Uxn, comptime T: type) void {
        self.op_sv.push(T, self.fetch(T));
    }
};
