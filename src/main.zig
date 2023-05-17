const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");
const Allocator = mem.Allocator;

const open_flags = .{
    .access_sub_paths = true,
};

fn matchPattern(pattern: []const u8, str: []const u8) bool {
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

                if (matchPattern(self.segments.items[i], entry.name)) switch (entry.kind) {
                    .File => {
                        if (self.path) |path| {
                            self.allocator.free(path);
                            self.path = null;
                        }

                        try self.components.append(self.allocator, entry.name);
                        self.path = try std.fs.path.join(self.allocator, self.components.items);
                        _ = self.components.pop();
                        if (i == self.segments.items.len - 1) {
                            return self.path;
                        }
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
            var dir = self.stack.pop().dir;
            dir.close();
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

    pub fn cwd(self: PathLib) !Path {
        return Path.init(self.allocator, try std.process.getCwdAlloc(self.allocator), true);
    }
};

pub const Path = struct {
    allocator: Allocator,
    _path: []const u8,
    fromHeap: bool,

    pub fn init(allocator: Allocator, path: []const u8, fromHeap: bool) Path {
        return Path{ .allocator = allocator, ._path = path, .fromHeap = fromHeap };
    }

    pub inline fn deinit(self: Path) void {
        // only need to free memory for the paths that we create
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

    pub fn eql(self: Path, other: Path) bool {
        // fast way
        if (std.mem.eql(u8, self._path, other._path)) {
            return true;
        }

        // deep equal
        const a = self.absolute() catch {
            return false;
        };
        defer a.deinit();
        const b = other.absolute() catch {
            return false;
        };
        defer b.deinit();

        return std.mem.eql(u8, a._path, b._path);
    }

    pub inline fn toSlice(self: Path) []const u8 {
        return self._path;
    }

    pub fn toCString(self: Path) Allocator.Error![]const u8 {
        var result = try self.allocator.alloc(u8, self._path.len + "\x00".len);
        std.mem.copy(u8, result[0..], self._path);
        std.mem.copy(u8, result[self._path.len..], "\x00");
        return result;
    }

    pub inline fn isAbsolute(self: Path) bool {
        return std.fs.path.isAbsolute(self.toSlice());
    }

    pub inline fn isRelative(self: Path) bool {
        return !std.fs.path.isAbsolute(self.toSlice());
    }

    pub fn absolute(self: Path) !Path {
        if (self.isAbsolute()) {
            return self;
        }
        const cwd = try PathLib.init(self.allocator).cwd();
        defer cwd.deinit();
        return cwd.joinPath(&[_]Path{self});
    }

    pub inline fn name(self: Path) []const u8 {
        return std.fs.path.basename(self.toSlice());
    }

    pub fn withName(self: Path, newName: []const u8) !Path {
        const base = std.fs.path.dirname(self.toSlice()) orelse "/";
        const sep = std.fs.path.sep_str;

        var newPath = try self.allocator.alloc(u8, base.len + newName.len + sep.len);
        std.mem.copy(u8, newPath[0..], base);
        std.mem.copy(u8, newPath[base.len..], sep);
        std.mem.copy(u8, newPath[base.len + sep.len ..], newName);

        return Path.init(self.allocator, newPath, true);
    }

    pub fn parent(self: Path) Path {
        const p = std.fs.path.dirname(self.toSlice()) orelse "/";

        return Path.init(self.allocator, p, false);
    }

    pub inline fn suffix(self: Path) []const u8 {
        return std.fs.path.extension(self.toSlice());
    }

    pub fn withSuffix(self: Path, newSuffix: []const u8) !Path {
        const path = self.toSlice();
        const ext = std.fs.path.extension(path);

        var newPath = try self.allocator.alloc(u8, path.len - ext.len + newSuffix.len);
        std.mem.copy(u8, newPath[0..], path[0 .. path.len - ext.len]);
        std.mem.copy(u8, newPath[path.len - ext.len ..], newSuffix);

        return Path.init(self.allocator, newPath, true);
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

        const sep = std.fs.path.sep_str;

        try list.append(self.toSlice());
        for (others) |p| {
            const s = p.toSlice();
            if (std.mem.startsWith(u8, s, "." ++ sep)) {
                try list.append(s[1..]);
            } else {
                try list.append(s);
            }
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

    pub inline fn isBlockDevice(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.BlockDevice;
    }

    pub inline fn isCharDevice(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.CharacterDevice;
    }

    pub inline fn isSocket(self: Path) !bool {
        const s = try self.stat();
        return s.kind == std.fs.File.Kind.UnixDomainSocket;
    }

    pub inline fn isSymlink(self: Path) !bool {
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

    pub fn match(self: Path, pattern: []const u8) bool {
        return matchPattern(pattern, self.toSlice());
    }

    pub fn glob(self: Path, pattern: []const u8) !Iterator {
        var dir = try std.fs.cwd().openIterableDir(self.toSlice(), open_flags);

        return try Iterator.init(self.allocator, dir, pattern);
    }

    pub fn exists(self: Path) !bool {
        _ = self.stat() catch {
            return false;
        };

        return true;
    }

    pub fn openFile(self: Path, flags: std.fs.File.OpenFlags) std.fs.File.OpenError!std.fs.File {
        const path = self.toSlice();
        if (self.isAbsolute()) {
            if (!try self.exists()) {
                const f = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
                defer f.close();
            }
            return std.fs.openFileAbsolute(path, flags);
        }

        if (!try self.exists()) {
            const f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
            defer f.close();
        }

        return std.fs.cwd().openFile(path, flags);
    }

    pub fn openDir(self: Path, flags: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        const path = self.toSlice();
        if (self.isAbsolute()) {
            if (!try self.exists()) {
                try std.fs.makeDirAbsolute(path);
            }
            return std.fs.openDirAbsolute(self.toSlice(), flags);
        }

        if (!try self.exists()) {
            try std.fs.cwd().makeDir(path);
        }

        return std.fs.cwd().openDir(self.toSlice(), flags);
    }

    /// return a deep clone of the path
    pub fn clone(self: Path) Path {
        if (self.fromHeap()) {
            var newPath = try self.allocator.alloc(u8, self._path.len);
            std.mem.copy(u8, newPath[0..], self._path);

            return Path.init(self.allocator, newPath, true);
        }
        return Path.init(self.allocator, self._path, self.fromHeap);
    }
};

// -----------------------------------------------------------
//                      unit tests
// -----------------------------------------------------------

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

test "test cwd" {
    const path = try PathLib.init(std.testing.allocator).cwd();
    defer path.deinit();

    const expect: []const u8 = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(expect);

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

test "test eql" {
    const path = try PathLib.init(std.testing.allocator).fromSlice("~/zig/src").expanduser();
    defer path.deinit();

    const home_dir = std.os.getenv("HOME") orelse "";
    var result = try std.testing.allocator.alloc(u8, home_dir.len + "/zig/src".len);
    std.mem.copy(u8, result[0..], home_dir);
    std.mem.copy(u8, result[home_dir.len..], "/zig/src");
    defer std.testing.allocator.free(result);

    const expect = PathLib.init(std.testing.allocator).fromSlice(result);
    defer expect.deinit();

    try std.testing.expect(path.eql(expect));
}

test "test isAbsolute" {
    const lib = PathLib.init(std.testing.allocator);

    try std.testing.expect(lib.fromSlice("./zig/src").isAbsolute() == false);

    try std.testing.expect(lib.fromSlice("/home/zig/src").isAbsolute() == true);
}

test "test absolute" {
    const path = PathLib.init(std.testing.allocator).fromSlice("./zig/src");
    defer path.deinit();

    const absPath = try path.absolute();
    defer absPath.deinit();

    const cwd: []const u8 = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var expect = try std.testing.allocator.alloc(u8, cwd.len + "/zig/src".len);
    std.mem.copy(u8, expect[0..], cwd);
    std.mem.copy(u8, expect[cwd.len..], "/zig/src");

    defer std.testing.allocator.free(expect);

    try std.testing.expect(std.mem.eql(u8, absPath.toSlice(), expect));
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

test "test withSuffix" {
    const lib = PathLib.init(std.testing.allocator);

    var path = lib.fromSlice("my/library/setup.py");
    defer path.deinit();

    var newPath = try path.withSuffix(".zig");
    defer newPath.deinit();

    try std.testing.expect(std.mem.eql(u8, newPath.toSlice(), "my/library/setup.zig"));
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

test "test withName" {
    const path = PathLib.init(std.testing.allocator).fromSlice("my/library/setup.py");
    defer path.deinit();

    const newPath = try path.withName("install.py");
    defer newPath.deinit();

    try std.testing.expect(std.mem.eql(u8, newPath.toSlice(), "my/library/install.py"));
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

test "test match" {
    var path = PathLib.init(std.testing.allocator).fromSlice("b.zig");
    defer path.deinit();
    try std.testing.expect(path.match("*.zig") == true);

    path = PathLib.init(std.testing.allocator).fromSlice("/b.zig");
    defer path.deinit();
    try std.testing.expect(path.match("*.zig") == true);

    path = PathLib.init(std.testing.allocator).fromSlice("README.md");
    defer path.deinit();
    try std.testing.expect(path.match("*.zig") == false);
    try std.testing.expect(path.match("*/*.zig") == false);
}

test "test match nested" {
    var path = PathLib.init(std.testing.allocator).fromSlice("a/b.zig");
    defer path.deinit();
    try std.testing.expect(path.match("*.zig") == true);

    path = PathLib.init(std.testing.allocator).fromSlice("a/b/c.zig");
    defer path.deinit();

    try std.testing.expect(path.match("a/b/c.zig") == true);
    try std.testing.expect(path.match("b/c.zig") == false);
    try std.testing.expect(path.match("c.zig") == false);

    try std.testing.expect(path.match("*/b/c.zig") == true);
    try std.testing.expect(path.match("*/b/*.zig") == true);
    try std.testing.expect(path.match("*/*/*.zig") == true);
    try std.testing.expect(path.match("*.zig") == true);
    // TODO: ?
    try std.testing.expect(path.match("b/*.zig") == false);

    try std.testing.expect(path.match("*.py") == false);
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

test "test exists" {
    var path = PathLib.init(std.testing.allocator).fromSlice("/dev/random");
    defer path.deinit();
    try std.testing.expect(try path.exists() == true);

    path = PathLib.init(std.testing.allocator).fromSlice("/dev/random222");
    defer path.deinit();
    try std.testing.expect(try path.exists() == false);

    path = PathLib.init(std.testing.allocator).fromSlice("./build.zig");
    defer path.deinit();
    try std.testing.expect(try path.exists() == true);
}

test "test openFile" {
    var dst = std.testing.tmpDir(open_flags);
    defer dst.cleanup();

    var path = PathLib.init(std.testing.allocator).fromSlice("./zig-cache/tmp/" ++ dst.sub_path ++ "/test");
    defer path.deinit();

    try std.testing.expect(try path.exists() == false);

    var file = try path.openFile(.{ .mode = std.fs.File.OpenMode.write_only });
    defer file.close();

    try std.testing.expect(try path.exists() == true);
    try std.testing.expect(try path.isFile() == true);
}

test "test openDir" {
    var dst = std.testing.tmpDir(open_flags);
    defer dst.cleanup();

    var path = PathLib.init(std.testing.allocator).fromSlice("./zig-cache/tmp/" ++ dst.sub_path ++ "/test");
    defer path.deinit();

    try std.testing.expect(try path.exists() == false);

    var dir = try path.openDir(.{});
    defer dir.close();

    try std.testing.expect(try path.exists() == true);
    try std.testing.expect(try path.isDir() == true);
}
