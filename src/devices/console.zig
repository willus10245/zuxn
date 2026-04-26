const std = @import("std");
const Cpu = @import("../uxn.zig").Uxn;

const logger = std.log.scoped(.uxn_varvara_console);

const vector_port: u8 = 0x10;
const read_port: u8 = 0x12;
const type_port: u8 = 0x17;
const wrt_port: u8 = 0x18;
const err_port: u8 = 0x19;

pub const Console = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    pub fn intercept(self: *Console, cpu: *Cpu, port: u8, is_output: bool) void {
        if (is_output) {
            switch (port) {
                wrt_port, err_port => {
                    const byte = cpu.loadDevice(u8, port);

                    if (port == wrt_port) {
                        _ = self.stdout.writeByte(byte) catch return;
                    } else {
                        _ = self.stderr.writeByte(byte) catch return;
                    }
                },
                else => {},
            }
        }
    }

    pub fn setArgc(_: Console, cpu: *Cpu, args: [][]const u8) void {
        cpu.storeDevice(u8, type_port, @intFromBool(args.len > 0));
    }

    pub fn readArguments(_: Console, cpu: *Cpu, args: [][]const u8) void {
        const console_vector = cpu.loadDevice(u16, vector_port);

        for (args, 0..) |arg, i| {
            for (arg) |byte| {
                cpu.storeDevice(u8, type_port, 0x2);
                cpu.storeDevice(u8, read_port, byte);

                cpu.runVector(console_vector);
            }

            cpu.storeDevice(u8, type_port, if (i == args.len - 1) 0x4 else 0x3);
            cpu.storeDevice(u8, read_port, '\n');

            cpu.runVector(console_vector);
        }
    }

    pub fn readStdinByte(_: Console, cpu: *Cpu, byte: u8) void {
        const console_vector = cpu.loadDevice(u16, vector_port);

        cpu.storeDevice(u8, type_port, 0x1);
        cpu.storeDevice(u8, read_port, byte);

        if (console_vector > 0x000)
            cpu.runVector(console_vector);
    }
};
