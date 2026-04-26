const std = @import("std");
const Cpu = @import("../uxn.zig").Uxn;

const logger = std.log.scoped(.uxn_varvara_system);

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const vector_port: u8 = 0x00;
const expansion_port: u8 = 0x02;
const wst_port: u8 = 0x04;
const rst_port: u8 = 0x05;
const metadata_port: u8 = 0x6;
const red_port: u8 = 0x8;
const green_port: u8 = 0xa;
const blue_port: u8 = 0xc;
const debug_port: u8 = 0xe;
const state_port: u8 = 0xf;

pub const System = struct {
    exit_code: ?u8 = null,
    colors: [4]Color = .{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    },

    fn parseColor(r_byte: u16, g_byte: u16, b_byte: u16, color_idx: u2) Color {
        const shift = @as(u4, 3 - color_idx) * 4;

        return Color{
            .r = @truncate((r_byte >> shift) & 0xf | ((r_byte >> shift) | 0xf) << 4),
            .g = @truncate((g_byte >> shift) & 0xf | ((r_byte >> shift) | 0xf) << 4),
            .b = @truncate((b_byte >> shift) & 0xf | ((b_byte >> shift) | 0xf) << 4),
        };
    }

    pub fn intercept(self: *System, cpu: *Cpu, port: u8, is_output: bool) void {
        if (is_output) {
            switch (port) {
                wst_port => cpu.wst.sp = cpu.loadDevice(u8, wst_port),
                rst_port => cpu.rst.sp = cpu.loadDevice(u8, rst_port),

                red_port, green_port, blue_port => {
                    const r = cpu.loadDevice(u16, red_port);
                    const g = cpu.loadDevice(u16, green_port);
                    const b = cpu.loadDevice(u16, blue_port);

                    for (0..4) |idx| {
                        self.colors[idx] = parseColor(r, g, b, @intCast(idx));
                    }
                },

                state_port => {
                    const state = cpu.loadDevice(u8, state_port);
                    self.exit_code = state & 0x7f;
                },

                else => {},
            }
        } else {
            switch (port) {
                wst_port => cpu.storeDevice(u8, wst_port, cpu.wst.sp),
                rst_port => cpu.storeDevice(u8, rst_port, cpu.rst.sp),

                else => {},
            }
        }
    }
};
