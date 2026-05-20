const std = @import("std");

const Cpu = @import("uxn-core").Uxn;
const system = @import("devices/system.zig");
const console = @import("devices/console.zig");
const datetime = @import("devices/datetime.zig");

const logger = std.log.scoped(.uxn_varvara);

pub const Varvara = struct {
    system_device: system.System,
    console_device: console.Console,

    pub fn init(stdout: *std.Io.Writer, stderr: *std.Io.Writer) Varvara {
        const sys = Varvara{ .system_device = .{}, .console_device = .{ .stdout = stdout, .stderr = stderr } };

        return sys;
    }

    pub fn intercept(self: *Varvara, cpu: *Cpu, port: u8, is_output: bool) void {
        switch (port & 0xF0) {
            0x00 => self.system_device.intercept(cpu, port, is_output),
            0x10 => self.console_device.intercept(cpu, port, is_output),
            0xc0 => datetime.intercept(cpu, port, is_output),
            else => {},
        }
    }
};
