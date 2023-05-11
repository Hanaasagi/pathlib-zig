const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");
const Allocator = mem.Allocator;

const open_flags = .{
    .access_sub_paths = true,
};

pub const Iterator = struct {
    allocator: mem.Allocator,
    root: std.fs.IterableDir,
    segments: std.ArrayListUnmanaged([]const u8),
    stack: std.ArrayListUnmanaged(std.fs.IterableDir.Iterator),
    components: std.ArrayListUnmanaged([]const u8),
    path: ?[]const u8,
    done: bool,

    pub fn init(allocator: mem.Allocator, root: std.fs.IterableDir, pattern: []const u8) !Iterator {
        if (pattern.len > 0 and pattern[0] == '/') return error.NoAbsolutePatterns;

        var ret = Iterator{
            .allocator = allocator,
            .root = root,
            .segments = std.ArrayListUnmanaged([]const u8){},
            .stack = std.ArrayListUnmanaged(std.fs.IterableDir.Iterator){},
            .components = std.ArrayListUnmanaged([]const u8){},
            .path = null,
            .done = false,
        };
        errdefer ret.deinit();

        var it = mem.split(u8, pattern, "/");
        while (it.next()) |seg| {
            if (mem.indexOf(u8, seg, "**") != null)
                return error.NotSupported;

            try ret.segments.append(allocator, seg);
        }

        return ret;
    }

    pub fn deinit(self: *Iterator) void {
        self.segments.deinit(self.allocator);
        self.components.deinit(self.allocator);
        if (self.stack.items.len > 0) {
            for (self.stack.items[1..]) |*it| {
                it.dir.close();
            }
        }

        self.stack.deinit(self.allocator);
        if (self.path) |path| self.allocator.free(path);
    }

    pub fn match(pattern: []const u8, str: []const u8) bool {
        if (mem.eql(u8, pattern, "*")) return true;

        var i: usize = 0;
        var it = mem.tokenize(u8, pattern, "*");
        var exact_begin = pattern.len > 0 and pattern[0] != '*';

        while (it.next()) |substr| {
            if (mem.indexOf(u8, str[i..], substr)) |j| {
                if (exact_begin) {
                    if (j != 0) return false;
                    exact_begin = false;
                }

                i += j + substr.len;
            } else return false;
        }

        return if (pattern[pattern.len - 1] == '*') true else i == str.len;
    }

    pub fn next(self: *Iterator) !?[]const u8 {
        if (self.done) return null;

        if (self.stack.items.len == 0) {
            try self.stack.append(self.allocator, self.root.iterate());
        }

        var i = self.stack.items.len - 1;
        reset: while (true) {
            var it = &self.stack.items[i];
            while (try it.next()) |entry| {
                if (entry.kind != .File and entry.kind != .Directory)
                    continue;

                if (match(self.segments.items[i], entry.name)) switch (entry.kind) {
                    .File => {
                        if (self.path) |path| {
                            self.allocator.free(path);
                            self.path = null;
                        }

                        try self.components.append(self.allocator, entry.name);
                        self.path = try std.fs.path.join(self.allocator, self.components.items);
                        _ = self.components.pop();
                        return self.path;
                    },
                    .Directory => {
                        if (i < self.segments.items.len - 1) {
                            const dir = try it.dir.openIterableDir(entry.name, open_flags);
                            try self.stack.append(self.allocator, dir.iterate());
                            try self.components.append(self.allocator, entry.name);
                            i += 1;

                            continue :reset;
                        }
                    },
                    else => unreachable,
                };
            }

            if (i == 0) {
                self.done = true;
                return null;
            }

            i -= 1;
            _ = self.components.pop();
            _ = self.stack.pop();
            // self.stack.pop().dir.close();
        }
    }
};

fn get_home_dir() []const u8 {
    switch (builtin.os.tag) {
        .windows => {
            var home = std.os.getenv("HOMEDRIVE") orelse "" + std.os.getenv("HOMEPATH") orelse "";
            if (home.len == 0) {
                home = std.os.getenv("USERPROFILE") orelse "";
            }
            return home;
        },
        .macos => {},
        else => {
            var home = std.os.getenv("XDG_HOME") orelse "";
            if (home.len != 0) {
                return home;
            }
        },
    }
    return std.os.getenv("HOME") orelse "";
}

pub const PathLib = struct {
    allocator: Allocator,

    pub fn init(allocator: std.mem.Allocator) PathLib {
        return PathLib{ .allocator = allocator };
    }

    pub fn fromSlice(self: PathLib, path: []const u8) Path {
        return Path.init(self.allocator, path, false);
    }

    pub fn home(self: PathLib) Path {
        return Path.init(self.allocator, get_home_dir(), false);
    }
};

pub const Path = struct {
    allocator: Allocator,
    _path: []const u8,
    fromHeap: bool,

    pub fn init(allocator: Allocator, path: []const u8, fromHeap: bool) Path {
        return Path{ .allocator = allocator, ._path = path, .fromHeap = fromHeap };
    }

    pub fn deinit(self: Path) void {
        if (self.fromHeap) {
            self.allocator.free(self._path);
        }
    }

    pub fn expanduser(self: Path) Allocator.Error!Path {
        const home_dir = get_home_dir();
        if (home_dir.len == 0) {
            return self;
        }

        if (std.mem.eql(u8, self._path, "~")) {
            return Path.init(self.allocator, home_dir, false);
        }

        const sep = std.fs.path.sep_str;
        const tildesep = "~" ++ sep;
        const Ltildesep = tildesep.len;

        // TODO: HOME with slash
        if (std.mem.startsWith(u8, self._path, tildesep)) {
            var result = try self.allocator.alloc(u8, home_dir.len + self._path.len - Ltildesep + 1);
            std.mem.copy(u8, result[0..], home_dir);
            std.mem.copy(u8, result[home_dir.len..], self._path[1..]);
            return Path.init(self.allocator, result, true);
        }

        return self;
    }

    pub fn equal(self: Path, other: Path) bool {
        return std.mem.eql(u8, self._path, other._path);
    }

    pub fn toSlice(self: Path) []const u8 {
        return self._path;
    }

    pub fn toCString(self: Path) Allocator.Error![]const u8 {
        var result = try self.allocator.alloc(u8, self._path.len + "\x00".len);
        std.mem.copy(u8, result[0..], self._path);
        std.mem.copy(u8, result[self._path.len..], "\x00");
        return result;
    }

    pub fn isAbsolute(self: Path) bool {
        return std.fs.path.isAbsolute(self.toSlice());
    }

    pub fn isRelative(self: Path) bool {
        return !std.fs.path.isAbsolute(self.toSlice());
    }

    pub fn name(self: Path) []const u8 {
        return std.fs.path.basename(self.toSlice());
    }

    pub fn parent(self: Path) Path {
        const p = std.fs.path.dirname(self.toSlice()) orelse "/";
        return Path.init(self.allocator, p, self.fromHeap);
    }

    pub fn suffix(self: Path) []const u8 {
        return std.fs.path.extension(self.toSlice());
    }

    pub fn suffixes(self: Path) !std.ArrayList([]const u8) {
        var path = self.toSlice();
        var list = std.ArrayList([]const u8).init(self.allocator);

        while (true) {
            const ext = std.fs.path.extension(path);
            if (ext.len == 0) {
                break;
            }

            try list.insert(0, ext);
            path = path[0 .. path.len - ext.len];
        }
        return list;
    }

    pub fn joinPath(self: Path, others: []const Path) Allocator.Error!Path {
        var list = std.ArrayList([]const u8).init(self.allocator);
        defer list.deinit();

        try list.append(self.toSlice());
        for (others) |p| {
            try list.append(p.toSlice());
        }

        const newPath = try std.fs.path.join(self.allocator, list.items);
        return Path.init(self.allocator, newPath, true);
    }

    pub fn stat(self: Path) !std.fs.File.Stat {
        // TODO: optimise one syscall in linux
        // if (builtin.os.tag == .windows or builtin.os.tag == .macos) {} else {
        //     var stat_: std.os.Stat = undefined;

        //     if (self.toCString()) |s| {
        //         _ = std.os.linux.stat(s[0.. :0], &stat_);
        //         return std.fs.File.Stat.fromSystem(stat_);
        //     } else |_| {
        //         // goto default
        //     }
        // }
        // default
        const path = self.toSlice();
        if (!self.isAbsolute()) {
            if (std.fs.cwd().openDir(path, .{})) |handle| {
                return try handle.stat();
            } else |_| {
                const handle = try std.fs.cwd().openFile(path, .{});
                return try handle.stat();
            }
        } else {
            if (std.fs.openDirAbsolute(path, .{})) |handle| {
                return try handle.stat();
            } else |_| {
                const handle = try std.fs.openFileAbsolute(path, .{});
                return try handle.stat();
            }
        }
    }

    pub fn isBlockDevice(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.BlockDevice;
    }

    pub fn isCharDevice(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.CharacterDevice;
    }

    pub fn isSocket(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.UnixDomainSocket;
    }

    pub fn isSymlink(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.SymLink;
    }
    pub fn isFifo(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.NamedPipe;
    }

    pub fn isDir(self: Path) !bool {
        const path = self.toSlice();
        if (!self.isAbsolute()) {
            if (std.fs.cwd().openDir(path, .{})) |_| {
                return true;
            } else |_| {
                _ = try std.fs.cwd().openFile(path, .{});
                return false;
            }
        } else {
            if (std.fs.openDirAbsolute(path, .{})) |_| {
                return true;
            } else |_| {
                _ = try std.fs.openFileAbsolute(path, .{});
                return false;
            }
        }
    }

    pub fn isFile(self: Path) !bool {
        return !try self.isDir();
    }

    pub fn glob(self: Path, pattern: []const u8) !Iterator {
        var dir = try std.fs.cwd().openIterableDir(self.toSlice(), open_flags);

        return try Iterator.init(self.allocator, dir, pattern);
    }
};

test "test path toSlice" {
    const path = PathLib.init(std.testing.allocator).fromSlice("/home/monosuzu/");
    defer path.deinit();

    try std.testing.expect(std.mem.eql(u8, path.toSlice(), "/home/monosuzu/"));
}

test "test home" {
    const path = PathLib.init(std.testing.allocator).home();
    defer path.deinit();

    const expect: []const u8 = std.os.getenv("HOME") orelse "";

    try std.testing.expect(std.mem.eql(u8, path.toSlice(), expect));
}

test "test expanduser single tilde " {
    const path = try PathLib.init(std.testing.allocator).fromSlice("~").expanduser();
    defer path.deinit();

    const expect: []const u8 = std.os.getenv("HOME") orelse "";
    try std.testing.expect(std.mem.eql(u8, path.toSlice(), expect));
}

test "test expanduser full path" {
    const path = try PathLib.init(std.testing.allocator).fromSlice("~/zig/src").expanduser();
    defer path.deinit();

    const home_dir = std.os.getenv("HOME") orelse "";
    var result = try std.testing.allocator.alloc(u8, home_dir.len + "/zig/src".len);
    std.mem.copy(u8, result[0..], home_dir);
    std.mem.copy(u8, result[home_dir.len..], "/zig/src");

    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.eql(u8, path.toSlice(), result));
}

test "test isAbsolute" {
    const lib = PathLib.init(std.testing.allocator);

    try std.testing.expect(lib.fromSlice("./zig/src").isAbsolute() == false);

    try std.testing.expect(lib.fromSlice("/home/zig/src").isAbsolute() == true);
}

test "test isRelative" {
    const lib = PathLib.init(std.testing.allocator);

    try std.testing.expect(lib.fromSlice("./zig/src").isRelative() == true);

    try std.testing.expect(lib.fromSlice("/home/zig/src").isRelative() == false);
}

test "test parent" {
    const path = PathLib.init(std.testing.allocator).fromSlice("/home/monosuzu").parent();
    defer path.deinit();

    try std.testing.expect(std.mem.eql(u8, path.toSlice(), "/home"));
}

test "test parent but root directory" {
    const path = PathLib.init(std.testing.allocator).fromSlice("/").parent();
    defer path.deinit();

    try std.testing.expect(std.mem.eql(u8, path.toSlice(), "/"));
}

test "test suffix" {
    const lib = PathLib.init(std.testing.allocator);

    var path = lib.fromSlice("my/library/setup.py");
    defer path.deinit();
    try std.testing.expect(std.mem.eql(u8, path.suffix(), ".py"));

    path = lib.fromSlice("my/library.tar.gz");
    defer path.deinit();
    try std.testing.expect(std.mem.eql(u8, path.suffix(), ".gz"));

    path = lib.fromSlice("my/library");
    defer path.deinit();
    try std.testing.expect(std.mem.eql(u8, path.suffix(), ""));
}

test "test suffixes" {
    const lib = PathLib.init(std.testing.allocator);

    const path = lib.fromSlice("my/library.tar.gz");
    defer path.deinit();

    var res = try path.suffixes();
    defer res.deinit();

    try std.testing.expect(res.items.len == 2);
}

test "test joinPath" {
    const lib = PathLib.init(std.testing.allocator);

    const path1 = lib.fromSlice("my/");
    defer path1.deinit();

    const path2 = lib.fromSlice("library/");
    defer path2.deinit();

    const path3 = lib.fromSlice("app/");
    defer path3.deinit();

    const others = [_]Path{ path2, path3 };

    const newPath = try path1.joinPath(&others);
    defer newPath.deinit();

    try std.testing.expect(std.mem.eql(u8, newPath.toSlice(), "my/library/app/"));
}

test "test name" {
    const path = PathLib.init(std.testing.allocator).fromSlice("my/library/setup.py");
    defer path.deinit();

    try std.testing.expect(std.mem.eql(u8, path.name(), "setup.py"));
}

test "test stat file" {
    const path = PathLib.init(std.testing.allocator).fromSlice("./build.zig");
    defer path.deinit();

    const stat = try path.stat();

    try std.testing.expect(stat.size != 0);
    try std.testing.expect(stat.atime != 0);
    try std.testing.expect(stat.mtime != 0);
    try std.testing.expect(stat.ctime != 0);
}

test "test stat dir" {
    const path = PathLib.init(std.testing.allocator).fromSlice("./src");
    defer path.deinit();

    const stat = try path.stat();

    try std.testing.expect(stat.size != 0);
    try std.testing.expect(stat.atime != 0);
    try std.testing.expect(stat.mtime != 0);
    try std.testing.expect(stat.ctime != 0);
}

test "test stat flle" {
    const path = PathLib.init(std.testing.allocator).fromSlice("./build.zig");
    defer path.deinit();

    const stat = try path.stat();

    try std.testing.expect(stat.size != 0);
    try std.testing.expect(stat.atime != 0);
    try std.testing.expect(stat.mtime != 0);
    try std.testing.expect(stat.ctime != 0);
}

test "test isDir" {
    var path = PathLib.init(std.testing.allocator).fromSlice("./src");
    defer path.deinit();

    var res = try path.isDir();

    try std.testing.expect(res == true);

    path = PathLib.init(std.testing.allocator).fromSlice("./build.zig");
    defer path.deinit();

    res = try path.isDir();

    try std.testing.expect(res == false);
}

test "test isFile" {
    var path = PathLib.init(std.testing.allocator).fromSlice("./src");
    defer path.deinit();

    var res = try path.isFile();

    try std.testing.expect(res == false);

    path = PathLib.init(std.testing.allocator).fromSlice("./build.zig");
    defer path.deinit();

    res = try path.isFile();

    try std.testing.expect(res == true);
}

test "test glob" {
    var path = PathLib.init(std.testing.allocator).fromSlice(".");
    defer path.deinit();

    var res = std.ArrayList([]const u8).init(std.testing.allocator);
    defer res.deinit();

    var it = try path.glob("*.zig");
    defer it.deinit();

    while (try it.next()) |p| {
        try res.append(p);
    }

    try std.testing.expect(res.items.len == 1);

    try std.testing.expect(std.mem.eql(u8, res.items[0], "build.zig"));
}

test "test isBlockDevice" {
    // TODO:
    var path = PathLib.init(std.testing.allocator).fromSlice("/dev/block");
    defer path.deinit();

    try std.testing.expect(try path.isBlockDevice() == false);
}

test "test isCharDevice" {
    var path = PathLib.init(std.testing.allocator).fromSlice("/dev/random");
    defer path.deinit();

    try std.testing.expect(try path.isCharDevice() == true);
}
test "test isSocket" {}

test "test isSymlink" {}

test "test isFifo" {}
