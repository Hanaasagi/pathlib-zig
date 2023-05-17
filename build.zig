const std = @import("std");
const Pkg = std.build.Pkg;
const Builder = std.build.Builder;
const Mode = std.builtin.Mode;
const CrossTarget = std.zig.CrossTarget;

const pkg_pathlib = Pkg{
    .name = "pathlib",
    .source = .{ .path = "src/main.zig" },
    .dependencies = null,
};

fn bin(b: *Builder, mode: *const Mode, target: *const CrossTarget, comptime source: []const []const u8) void {
    _ = target;
    inline for (source) |s| {
        const file = b.addExecutable(s, "examples/" ++ s ++ ".zig");
        file.setBuildMode(mode.*);
        // file.setTarget(target.*);
        file.addPackage(pkg_pathlib);
        file.linkLibC();
        file.install();
    }
}

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("pathlib-zig", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const target = b.standardTargetOptions(.{});
    bin(b, &mode, &target, &.{"tutorial"});
}
