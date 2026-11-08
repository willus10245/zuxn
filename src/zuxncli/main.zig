const std = @import("std");
const uxn = @import("uxn-core");
const Varvara = @import("uxn-varvara").Varvara;
const Io = std.Io;
const Uxn = uxn.Uxn;

const logger = std.log.scoped(.uxn);

pub const std_options: std.Options = .{
    .log_level = .info,
};

fn intercept(ctx: *anyopaque, cpu: *Uxn, port: u8, is_output: bool) void {
    const varv: *Varvara = @ptrCast(@alignCast(ctx));
    varv.intercept(cpu, port, is_output);
}

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    // Unbuffered
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &.{});
    const stdout_writer = &stdout_file_writer.interface;
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &.{});
    const stderr_writer = &stderr_file_writer.interface;

    if (args.len < 2) {
        try stderr_writer.writeAll("usage: zuxncli <rom_path>\n");
        std.process.exit(1);
    }

    const rom_path = args[1];
    var input_file_buffer: [1024]u8 = undefined;
    var input_file = try std.Io.Dir.cwd().openFile(io, rom_path, .{});
    var input_file_reader = input_file.reader(io, &input_file_buffer);

    defer input_file.close(io);

    const rom_args: [][]const u8 = @ptrCast(@constCast(args[2..]));

    var varv = Varvara.init(stdout_writer, stderr_writer);

    const ram = try uxn.loadRom(arena, &input_file_reader.interface);

    var cpu = Uxn.init(ram);
    cpu.intercept_ctx = &varv;
    cpu.intercept_fn = intercept;

    varv.console_device.setArgc(&cpu, rom_args);

    cpu.runVector(0x0100);

    varv.console_device.readArguments(&cpu, rom_args);

    if (varv.system_device.exit_code) |c| {
        std.process.exit(c);
    }

    while (varv.system_device.exit_code == null and varv.console_device.hasVector(&cpu)) {
        const byte = stdin.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                varv.console_device.sendEndOfInput(&cpu);
                break;
            },
            else => return err,
        };

        varv.console_device.readStdinByte(&cpu, byte);
    }

    std.process.exit(varv.system_device.exit_code orelse 0);
}
