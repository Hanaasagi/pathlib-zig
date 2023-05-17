const std = @import("std");
const pathlib = @import("pathlib").PathLib;
const Path = @import("pathlib").Path;

pub fn main() !void {
    // First, initialize this library.
    // The allocator will only be used when additional memory allocation is required,
    // such as when joining paths.
    const lib = pathlib.init(std.heap.page_allocator);

    // There are three ways to obtain a Path object, starting from the lib object.

    // 1. Get the current working directory.
    const cwd = try lib.cwd();
    defer cwd.deinit();
    std.debug.print("current working directory => {s}\n", .{cwd.toSlice()});

    // 2. Get home directory.
    const home = lib.home();
    defer home.deinit();
    std.debug.print("home directory => {s}\n\n", .{home.toSlice()});

    // 3. From any slice
    const zPath = lib.fromSlice("~/zig");
    defer zPath.deinit();
    std.debug.print("just an arbitrary path => {s}\n", .{zPath.toSlice()});

    // After obtaining a Path object, we can process it.

    // expand the `~`
    std.debug.print("expand it's `~` => {s}\n\n", .{(try zPath.expanduser()).toSlice()});

    // relative path
    const rPath = lib.fromSlice("./t");
    defer rPath.deinit();
    if (rPath.isRelative()) {
        std.debug.print("relative path => {s}\n", .{rPath.toSlice()});
        std.debug.print("and it's absolute path => {s}\n", .{(try rPath.absolute()).toSlice()});
    }

    if (!try rPath.exists()) {
        std.debug.print("path `{s}` is not existed, creating\n\n", .{rPath.toSlice()});

        var f = try rPath.openDir(.{});
        defer f.close();
    } else {
        std.debug.print("{s} is existed\n\n", .{rPath.toSlice()});
    }

    const tFile = lib.fromSlice("t.zig");
    defer tFile.deinit();
    const tFullPath = try rPath.joinPath(&[_]Path{tFile});
    defer tFullPath.deinit();

    std.debug.print("join {s} and {s} => {s}\n", .{ rPath.toSlice(), tFile.toSlice(), tFullPath.toSlice() });

    if (!try tFullPath.exists()) {
        std.debug.print("path `{s}` is not existed, creating\n\n", .{tFullPath.toSlice()});

        var f = try tFullPath.openFile(.{});
        defer f.close();
    } else {
        std.debug.print("{s} is existed\n\n", .{tFullPath.toSlice()});
    }

    std.debug.print("glob `*.zig` in {s}\n", .{cwd.toSlice()});
    var it = try cwd.glob("*.zig");
    while (try it.next()) |p| {
        std.debug.print("\t>>> {s}\n", .{p});
    }

    std.debug.print("glob `*/*.zig` in {s}\n", .{cwd.toSlice()});
    it = try cwd.glob("*/*.zig");
    while (try it.next()) |p| {
        std.debug.print("\t>>> {s}\n", .{p});
    }

    std.debug.print("glob `*` in {s}\n", .{cwd.toSlice()});
    it = try cwd.glob("*");
    while (try it.next()) |p| {
        std.debug.print("\t>>> {s}\n", .{p});
    }
}
