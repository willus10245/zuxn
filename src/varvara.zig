const std = @import("std");

const Cpu = @import("uxn.zig").Uxn;
const console = @import("devices/console.zig");

const logger = std.log.scoped(.uxn_varvara);

pub const Varvara = struct {
    console_device: console.Console,

    pub fn init(stdout: *std.Io.Writer, stderr: *std.Io.Writer) Varvara {
        const sys = Varvara{ .console_device = .{ .stdout = stdout, .stderr = stderr } };

        return sys;
    }

    pub fn intercept(self: *Varvara, cpu: *Cpu, port: u8, is_output: bool) void {
        switch (port & 0xF0) {
            0x10 => self.console_device.intercept(cpu, port, is_output),
            else => unreachable,
        }
    }
};
