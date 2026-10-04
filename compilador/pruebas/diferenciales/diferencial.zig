//! Runner de pruebas diferenciales de Alma.
//!
//! Ejecuta cada caso `casos/*.alma` con el intérprete, el backend C y (solo en
//! Windows x64) el backend propio, y compara stdout byte a byte y el código de
//! salida con `casos/<nombre>.salida`. Es el criterio de aceptación de los
//! backends: un motor solo «aprueba» un caso si produce exactamente esos bytes.
//!
//! Cabecera de cada caso (comentarios al principio del archivo):
//!   // motores: interprete c propio   motores que deben concordar (obligatorio)
//!   // codigo: 1                       código de salida esperado (por defecto 0)
//! Un motor no listado, o no disponible en la plataforma, queda «excluido» y no
//! cuenta como aprobado. Los subdirectorios de `casos/` contienen módulos
//! auxiliares y no se ejecutan como casos.
//!
//! Uso: diferencial <alma> <dir-casos> <dir-trabajo>   (lo invoca `zig build diferencial`)

const std = @import("std");
const builtin = @import("builtin");

const Motor = enum { interprete, c, propio };
const Caso = struct { motores: std.EnumSet(Motor), codigo: u8 };
const Resultado = struct { codigo: ?u8, stdout: []const u8, stderr: []const u8 };

const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } };
const propio_disponible = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("Uso: diferencial <alma> <dir-casos> <dir-trabajo>\n", .{});
        std.process.exit(2);
    }
    const alma = args[1];
    const dir_casos = args[2];
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[3]);
    const trabajo = try cwd.realPathFileAlloc(io, args[3], arena);

    var nombres: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var dir = try cwd.openDir(io, dir_casos, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entrada| {
            if (entrada.kind != .file or !std.mem.endsWith(u8, entrada.name, ".alma")) continue;
            try nombres.append(arena, try arena.dupe(u8, entrada.name[0 .. entrada.name.len - ".alma".len]));
        }
    }
    std.mem.sort([]const u8, nombres.items, {}, menorQue);

    var aprobadas: usize = 0;
    var fallidas: usize = 0;
    var excluidas: usize = 0;
    for (nombres.items) |nombre| {
        const ruta = try std.fmt.allocPrint(arena, "{s}{c}{s}.alma", .{ dir_casos, std.fs.path.sep, nombre });
        const ruta_salida = try std.fmt.allocPrint(arena, "{s}{c}{s}.salida", .{ dir_casos, std.fs.path.sep, nombre });
        const fuente = try cwd.readFileAlloc(io, ruta, arena, .limited(1 << 20));
        const caso = leerCabecera(fuente) orelse {
            std.debug.print("FALLA {s}: falta la cabecera '// motores: ...'\n", .{nombre});
            fallidas += 1;
            continue;
        };
        const esperado = cwd.readFileAlloc(io, ruta_salida, arena, .limited(1 << 24)) catch |err| {
            std.debug.print("FALLA {s}: no se pudo leer {s}: {s}\n", .{ nombre, ruta_salida, @errorName(err) });
            fallidas += 1;
            continue;
        };
        for ([_]Motor{ .interprete, .c, .propio }) |motor| {
            if (!caso.motores.contains(motor)) {
                excluidas += 1;
                continue;
            }
            if (motor == .propio and !propio_disponible) {
                std.debug.print("excluido {s} [propio]: el backend propio solo genera Windows x64\n", .{nombre});
                excluidas += 1;
                continue;
            }
            const r = ejecutarMotor(arena, io, alma, ruta, trabajo, nombre, motor) catch |err| {
                std.debug.print("FALLA {s} [{s}]: {s}\n", .{ nombre, @tagName(motor), @errorName(err) });
                fallidas += 1;
                continue;
            };
            if (comparar(nombre, motor, caso, esperado, r)) aprobadas += 1 else fallidas += 1;
        }
    }
    std.debug.print("\nPruebas diferenciales: {d} aprobadas, {d} fallidas, {d} excluidas ({d} casos).\n", .{ aprobadas, fallidas, excluidas, nombres.items.len });
    if (fallidas != 0 or aprobadas == 0) std.process.exit(1);
}

fn menorQue(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn leerCabecera(fuente: []const u8) ?Caso {
    var caso = Caso{ .motores = .initEmpty(), .codigo = 0 };
    var con_motores = false;
    var lineas = std.mem.splitScalar(u8, fuente, '\n');
    while (lineas.next()) |linea_cruda| {
        const linea = std.mem.trim(u8, linea_cruda, " \t\r");
        if (!std.mem.startsWith(u8, linea, "//")) break;
        const contenido = std.mem.trim(u8, linea[2..], " \t");
        if (std.mem.startsWith(u8, contenido, "motores:")) {
            var palabras = std.mem.tokenizeAny(u8, contenido["motores:".len..], " \t,");
            while (palabras.next()) |p| caso.motores.insert(std.meta.stringToEnum(Motor, p) orelse return null);
            con_motores = true;
        } else if (std.mem.startsWith(u8, contenido, "codigo:")) {
            caso.codigo = std.fmt.parseInt(u8, std.mem.trim(u8, contenido["codigo:".len..], " \t"), 10) catch return null;
        }
    }
    return if (con_motores) caso else null;
}

fn correr(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Resultado {
    const r = try std.process.run(arena, io, .{ .argv = argv, .timeout = timeout });
    const codigo: ?u8 = switch (r.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .codigo = codigo, .stdout = r.stdout, .stderr = r.stderr };
}

fn ejecutarMotor(arena: std.mem.Allocator, io: std.Io, alma: []const u8, ruta: []const u8, trabajo: []const u8, nombre: []const u8, motor: Motor) !Resultado {
    if (motor == .interprete) return correr(arena, io, &.{ alma, "ejecutar", ruta });
    const ext = if (motor == .propio or builtin.os.tag == .windows) ".exe" else "";
    const binario = try std.fmt.allocPrint(arena, "{s}{c}{s}-{s}{s}", .{ trabajo, std.fs.path.sep, nombre, @tagName(motor), ext });
    const backend = if (motor == .propio) "--backend=propio" else "--backend=c";
    const compilacion = try correr(arena, io, &.{ alma, "compilar", ruta, "-o", binario, "--sobrescribir", backend });
    if (compilacion.codigo == null or compilacion.codigo.? != 0) {
        std.debug.print("  alma compilar {s} ({s}) falló:\n{s}\n", .{ nombre, backend, compilacion.stderr });
        return error.CompilacionFallida;
    }
    return correr(arena, io, &.{binario});
}

fn comparar(nombre: []const u8, motor: Motor, caso: Caso, esperado: []const u8, r: Resultado) bool {
    var ok = true;
    if (r.codigo == null or r.codigo.? != caso.codigo) {
        std.debug.print("FALLA {s} [{s}]: código {?d}, esperado {d}\n  stderr: {s}\n", .{ nombre, @tagName(motor), r.codigo, caso.codigo, r.stderr });
        ok = false;
    }
    if (!std.mem.eql(u8, r.stdout, esperado)) {
        const i = std.mem.findDiff(u8, r.stdout, esperado) orelse 0;
        const desde = i -| 20;
        std.debug.print("FALLA {s} [{s}]: stdout difiere en el byte {d} ({d} bytes, esperados {d})\n  obtenido: {f}\n  esperado: {f}\n", .{
            nombre,
            @tagName(motor),
            i,
            r.stdout.len,
            esperado.len,
            std.zig.fmtString(r.stdout[@min(desde, r.stdout.len)..@min(i + 40, r.stdout.len)]),
            std.zig.fmtString(esperado[@min(desde, esperado.len)..@min(i + 40, esperado.len)]),
        });
        ok = false;
    }
    if (ok) std.debug.print("ok    {s} [{s}]\n", .{ nombre, @tagName(motor) });
    return ok;
}
