const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Build option: link pigpio for GPIO support ──
    const use_gpio = b.option(bool, "gpio", "Link with pigpiod_if2 for GPIO support (default: true on Linux)") orelse
        (target.result.os.tag == .linux);

    const options = b.addOptions();
    options.addOption(bool, "use_pigpio", use_gpio);

    const exe = b.addExecutable(.{
        .name = "morse-pi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addOptions("build_options", options);

    if (use_gpio) {
        exe.linkSystemLibrary("pigpiod_if2");
    }
    exe.linkLibC();

    b.installArtifact(exe);

    // ── Run step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Morse-Pi server");
    run_step.dependOn(&run_cmd.step);
}
