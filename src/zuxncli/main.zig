const std = @import("std");
const Uxn = @import("uxn-core").Uxn;
const Varvara = @import("uxn-varvara").Varvara;
const Io = std.Io;

const logger = std.log.scoped(.uxn);

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
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &.{});
    const stdout_writer = &stdout_file_writer.interface;
    var stderr_file_writer: Io.File.Writer = .init(.stdout(), io, &.{});
    const stderr_writer = &stderr_file_writer.interface;

    var varv = Varvara.init(stdout_writer, stderr_writer);

    var uxn = Uxn.init();
    uxn.intercept_ctx = &varv;
    uxn.intercept_fn = intercept;

    const rom_path = args[1];
    _ = try std.Io.Dir.cwd().readFile(io, rom_path, uxn.mem[uxn.pc..]);

    const rom_args: [][]const u8 = @ptrCast(@constCast(args[2..]));
    varv.console_device.setArgc(&uxn, rom_args);

    uxn.runVector(0x0100);

    varv.console_device.readArguments(&uxn, rom_args);

    if (varv.system_device.exit_code) |c| {
        std.process.exit(c);
    }

    while (varv.system_device.exit_code == null) {
        const byte = stdin.takeByte() catch unreachable;

        varv.console_device.readStdinByte(&uxn, byte);
    }

    std.process.exit(varv.system_device.exit_code orelse 0);
}
