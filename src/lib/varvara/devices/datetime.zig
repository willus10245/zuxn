const std = @import("std");
const Cpu = @import("uxn-core").Uxn;

const ctime = @cImport({
    @cInclude("time.h");
});

const logger = std.log.scoped(.uxn_varvara_datetime);

const year_port: u8 = 0xc0;
const month_port: u8 = 0xc2;
const day_port: u8 = 0xc3;
const hour_port: u8 = 0xc4;
const minute_port: u8 = 0xc5;
const second_port: u8 = 0xc6;
const dow_port: u8 = 0xc7;
const doy_port: u8 = 0xc8;
const dst_port: u8 = 0xca;

pub fn intercept(cpu: *Cpu, port: u8, is_output: bool) void {
    if (!is_output) {
        const now = ctime.time(null);
        const t = ctime.localtime(&now);

        switch (port) {
            year_port, year_port + 1 => cpu.storeDevice(u16, year_port, @as(u16, @intCast(t.*.tm_year + 1900))),
            month_port => cpu.storeDevice(u8, month_port, @as(u8, @intCast(t.*.tm_mon))),
            day_port => cpu.storeDevice(u8, day_port, @as(u8, @intCast(t.*.tm_mday))),
            hour_port => cpu.storeDevice(u8, hour_port, @as(u8, @intCast(t.*.tm_hour))),
            minute_port => cpu.storeDevice(u8, minute_port, @as(u8, @intCast(t.*.tm_min))),
            second_port => cpu.storeDevice(u8, second_port, @as(u8, @intCast(t.*.tm_sec))),
            dow_port => cpu.storeDevice(u8, dow_port, @as(u8, @intCast(t.*.tm_wday))),
            doy_port, doy_port + 1 => cpu.storeDevice(u16, doy_port, @as(u16, @intCast(t.*.tm_yday))),
            dst_port => cpu.storeDevice(u8, dst_port, @as(u8, @intCast(t.*.tm_isdst))),
            else => {},
        }
    }
}
