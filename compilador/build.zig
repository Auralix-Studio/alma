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
    const test_step = b.step("test", "Corre las pruebas unitarias del compilador");
    test_step.dependOn(&run_tests.step);

    // Pruebas diferenciales: intérprete vs backend C vs backend propio sobre
    // pruebas/diferenciales/casos (stdout byte a byte y código de salida).
    const diferencial = b.addExecutable(.{
        .name = "diferencial",
        .root_module = b.createModule(.{
            .root_source_file = b.path("pruebas/diferenciales/diferencial.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_diferencial = b.addRunArtifact(diferencial);
    run_diferencial.addArtifactArg(exe);
    run_diferencial.addDirectoryArg(b.path("pruebas/diferenciales/casos"));
    _ = run_diferencial.addOutputDirectoryArg("trabajo");
    run_diferencial.has_side_effects = true;
    const diferencial_step = b.step("diferencial", "Compara intérprete, backend C y backend propio");
    diferencial_step.dependOn(&run_diferencial.step);
}
