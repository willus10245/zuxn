const std = @import("std");
const Uxn = @import("uxn-core").Uxn;
const Assem = @import("uxn-asm").Assembler;
const Io = std.Io;

const logger = std.log.scoped(.uxn_asm);

const Assembler = Assem(.{});

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &.{});
    const stdout_writer = &stdout_file_writer.interface;

    const input_file_name = args[1];
    const output_file_name = args[2];
    const base_dir = Io.Dir.cwd();

    var output_rom: [0x10000]u8 = [1]u8{0x00} ** 0x10000;

    const input_file = try base_dir.openFile(io, input_file_name, .{});
    defer input_file.close(io);

    var input_buffer: [1024]u8 = undefined;
    var input_reader = input_file.reader(io, &input_buffer);
    const reader = &input_reader.interface;

    var assembler = Assembler.init(arena);
    defer assembler.deinit();

    try assembler.assemble(reader, &output_rom);

    const output_file = try base_dir.createFile(io, output_file_name, .{});
    defer output_file.close(io);

    var write_buffer: [1024]u8 = undefined;
    var output_writer = output_file.writer(io, &write_buffer);
    var writer = &output_writer.interface;

    try writer.writeAll(output_rom[0x100..assembler.rom_length]);
    try output_writer.end();

    try stdout_writer.print("Assembled {s} in {d} bytes({d:.2}% used), {d} labels, {d} macros.\n", .{ input_file_name, assembler.rom_length - 0x100, @as(f16, @floatFromInt(assembler.rom_length - 0x100)) / 652.80, assembler.labels.items.len, assembler.macros.items.len });
}
