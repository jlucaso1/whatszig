const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Add go mod download step
    const go_deps = b.addSystemCommand(&[_][]const u8{
        "go", "mod", "download",
    });
    go_deps.setCwd(b.path("gowhatsapp"));
    go_deps.setEnvironmentVariable("CGO_ENABLED", "1");

    const go_lib = b.addSystemCommand(&[_][]const u8{
        "go", "build", "-buildmode=c-archive", "-o", "libwhatsapp.a", "whatsapp.go",
    });

    go_lib.setCwd(b.path("gowhatsapp"));

    go_lib.setEnvironmentVariable("CGO_ENABLED", "1");

    const goarch = switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "arm",
        .x86 => "386",
        else => @panic("Unsupported architecture for GOARCH"),
    };
    // Set goarch for both commands
    go_deps.setEnvironmentVariable("GOARCH", goarch);
    go_lib.setEnvironmentVariable("GOARCH", goarch);

    switch (target.result.os.tag) {
        .windows => {
            go_deps.setEnvironmentVariable("GOOS", "windows");
            go_lib.setEnvironmentVariable("GOOS", "windows");
        },
        .linux => {
            go_deps.setEnvironmentVariable("GOOS", "linux");
            go_lib.setEnvironmentVariable("GOOS", "linux");
        },
        .macos => {
            go_deps.setEnvironmentVariable("GOOS", "darwin");
            go_lib.setEnvironmentVariable("GOOS", "darwin");
        },
        else => {
            @panic("Unsupported OS");
        },
    }

    // Generate target triple string (e.g., "x86_64-linux")
    const target_triple = blk: {
        var triple = std.ArrayList(u8).init(b.allocator);
        defer triple.deinit();

        // CPU architecture
        const arch_name = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            else => @panic("Unsupported architecture"),
        };

        // OS
        const os_name = switch (target.result.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "macos",
            else => @panic("Unsupported OS"),
        };

        triple.writer().print("{s}-{s}", .{ arch_name, os_name }) catch unreachable;
        break :blk triple.toOwnedSlice() catch unreachable;
    };

    // Use the dynamic target triple
    go_lib.setEnvironmentVariable("CC", b.fmt("zig cc -target {s}", .{target_triple}));
    go_lib.setEnvironmentVariable("CXX", b.fmt("zig c++ -target {s}", .{target_triple}));

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "attemp1",
        .root_module = exe_mod,
    });

    exe.addIncludePath(b.path("gowhatsapp"));

    exe.addObjectFile(b.path("gowhatsapp/libwhatsapp.a"));

    exe.linkLibC();

    // Make go_lib depend on go_deps
    go_lib.step.dependOn(&go_deps.step);

    exe.step.dependOn(&go_lib.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
