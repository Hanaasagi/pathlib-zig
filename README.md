# A user-friendly path handling library

**After some thought, I believe this abstraction is unnecessary, so I've decided to archive it.**

### Example

Full example here https://github.com/Hanaasagi/pathlib-zig/tree/master/examples

```zig
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

    // ...
}

```

### API

- `home`
- `expanduser`
- `isAbsolute`
- `parent`
- `suffix`
- `joinPath`
- `name`
- `stat`
- `isDir`
- `isFile`
- `glob`
- ... and more
