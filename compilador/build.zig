const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Binario del CLI: alma <comando> [args]
    const exe = b.addExecutable(.{
        .name = "alma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Ejecuta el CLI de Alma (usa -- para pasar argumentos)");
    run_step.dependOn(&run_cmd.step);

    // Tests del compilador (lexer + parser, agregados en pruebas.zig).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pruebas.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Corre los tests del lexer");
    test_step.dependOn(&run_tests.step);
}
