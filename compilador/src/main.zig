//! main.zig — CLI del ecosistema Alma (comando `alma`).
//!
//! Comandos implementados:
//!   alma ejecutar <archivo.alma>   Compila al vuelo y ejecuta (intérprete).
//!   alma tokens   <archivo.alma>   Muestra el flujo de tokens (herramienta de desarrollo).
//!   alma ast      <archivo.alma>   Muestra el AST en S-expresión (herramienta de desarrollo).
//!   alma version                   Muestra la versión.
//! También implementados: nuevo, compilar, analizar y paquete.
//! Pendientes: formatear, probar, doc, lsp.
//!
//! Usa la API `std.Io` de Zig 0.16 (Threaded) para leer archivos y escribir a stdout.

const std = @import("std");
const process = std.process;
const lexer = @import("lexico/lexer.zig");
const parser = @import("sintaxis/parser.zig");
const ast = @import("sintaxis/ast.zig");
const interprete = @import("ejecucion/interprete.zig");
const analizador = @import("semantica/analizador.zig");
const modulos = @import("modulos.zig");
const paquete = @import("paquete.zig");
const codegen_c = @import("codegen_c.zig");
const builtin = @import("builtin");

const VERSION = "0.1.0";

pub fn main(init: process.Init.Minimal) void {
    ejecutarCli(init) catch |err| {
        std.debug.print("Alma: {s}\n", .{@errorName(err)});
        process.exit(1);
    };
}

fn ejecutarCli(init: process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(arena);

    if (args.len < 2) {
        try imprimirAyuda(io);
        return;
    }

    const comando = args[1];
    if (esIgual(comando, "ejecutar")) {
        const ruta = try requiereRuta(args, "ejecutar");
        try cmdEjecutar(io, gpa, ruta);
    } else if (esIgual(comando, "tokens")) {
        const ruta = try requiereRuta(args, "tokens");
        try cmdTokens(io, gpa, ruta);
    } else if (esIgual(comando, "ast")) {
        const ruta = try requiereRuta(args, "ast");
        try cmdAst(io, gpa, ruta);
    } else if (esIgual(comando, "analizar")) {
        const ruta = try requiereRuta(args, "analizar");
        try cmdAnalizar(io, gpa, ruta);
    } else if (esIgual(comando, "compilar")) {
        const ruta = try requiereRuta(args, "compilar");
        try cmdCompilar(io, gpa, ruta);
    } else if (esIgual(comando, "nuevo")) {
        if (args.len < 3) {
            std.debug.print("Uso: alma nuevo <nombre>\n", .{});
            return error.FaltaArgumento;
        }
        try cmdNuevo(io, gpa, args[2]);
    } else if (esIgual(comando, "paquete")) {
        const sub = if (args.len >= 3) args[2] else "";
        try cmdPaquete(io, gpa, sub);
    } else if (esIgual(comando, "version") or esIgual(comando, "--version")) {
        try escribir(io, "Alma " ++ VERSION ++ "\n");
    } else if (esIgual(comando, "ayuda") or esIgual(comando, "--help") or esIgual(comando, "-h")) {
        try imprimirAyuda(io);
    } else if (esComandoOficialPendiente(comando)) {
        std.debug.print("El comando 'alma {s}' aún no está implementado.\n", .{comando});
        return error.ComandoNoImplementado;
    } else {
        std.debug.print("Comando desconocido: '{s}'\n", .{comando});
        try imprimirAyuda(io);
        return error.ComandoDesconocido;
    }
}

fn esIgual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn esComandoOficialPendiente(cmd: []const u8) bool {
    const pendientes = [_][]const u8{ "formatear", "probar", "doc", "lsp" };
    for (pendientes) |p| {
        if (esIgual(cmd, p)) return true;
    }
    return false;
}

fn requiereRuta(args: []const [:0]const u8, comando: []const u8) ![]const u8 {
    if (args.len < 3) {
        std.debug.print("Uso: alma {s} <archivo.alma>\n", .{comando});
        return error.FaltaArgumento;
    }
    return args[2];
}

// — Comandos —

fn cmdEjecutar(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) !void {
    var prog = try modulos.construir(gpa, io, ruta);
    defer prog.deinit();
    try validarPrograma(gpa, ruta, prog.stmts);

    var interp = try interprete.Interprete.init(gpa);
    defer interp.deinit();
    interp.io = io; // habilita el módulo `sistema` (archivos)
    interp.ejecutar(prog.stmts) catch |err| {
        if (interp.diag) |d| std.debug.print("{s}:{d}:{d}: error de ejecución: {s}\n", .{ ruta, interp.diag_pos.linea, interp.diag_pos.columna, d });
        try escribir(io, interp.textoSalida());
        return err;
    };

    try escribir(io, interp.textoSalida());
}

fn cmdTokens(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) !void {
    const fuente = leerArchivo(io, gpa, ruta) catch |err| return errorArchivo(ruta, err);
    defer gpa.free(fuente);

    const tokens = try lexer.tokenizar(gpa, fuente);
    defer gpa.free(tokens);

    std.debug.print("== Tokens de {s} ({d}) ==\n", .{ ruta, tokens.len });
    for (tokens) |t| {
        std.debug.print("{d}:{d}\t{s}\t{s}\n", .{ t.linea, t.columna, @tagName(t.tipo), t.lexema });
    }
}

fn cmdAst(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) !void {
    const fuente = leerArchivo(io, gpa, ruta) catch |err| return errorArchivo(ruta, err);
    defer gpa.free(fuente);

    const tokens = try lexer.tokenizar(gpa, fuente);
    defer gpa.free(tokens);

    var p = parser.Parser.init(gpa, tokens);
    defer p.deinit();
    const programa = p.parsePrograma() catch |err| {
        if (p.diag) |d| std.debug.print("Error de sintaxis en {s}: {s} (L{d}:C{d})\n", .{ ruta, d.mensaje, d.linea, d.columna });
        return err;
    };

    const arbol = try ast.escribirPrograma(gpa, programa);
    defer gpa.free(arbol);
    std.debug.print("{s}\n", .{arbol});
}

fn cmdCompilar(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) !void {
    var arena_st = std.heap.ArenaAllocator.init(gpa);
    defer arena_st.deinit();
    const arena = arena_st.allocator();

    var prog = try modulos.construir(gpa, io, ruta);
    defer prog.deinit();
    try validarPrograma(gpa, ruta, prog.stmts);
    const gen = try codegen_c.generar(arena, prog.stmts);
    const fuente_c = gen.fuente_c orelse {
        std.debug.print("No se puede compilar todavía: {s}\n(por ahora, ese programa se ejecuta con 'alma ejecutar')\n", .{gen.diag orelse "construcción no soportada"});
        return error.ConstruccionNoSoportada;
    };

    const base = sinExtension(ruta);
    const ruta_c = try std.fmt.allocPrint(arena, "{s}.c", .{base});
    const ext_exe = if (builtin.os.tag == .windows) ".exe" else "";
    const ruta_exe = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, ext_exe });

    const cwd: std.Io.Dir = .cwd();
    cwd.writeFile(io, .{ .sub_path = ruta_c, .data = fuente_c }) catch |err| {
        std.debug.print("No se pudo escribir '{s}': {s}\n", .{ ruta_c, @errorName(err) });
        return err;
    };

    // Compilar el C a binario nativo con `zig cc`.
    const argv = [_][]const u8{ "zig", "cc", ruta_c, "-o", ruta_exe, "-O2" };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
        std.debug.print("Se generó '{s}', pero no pude invocar 'zig cc' ({s}).\nCompilalo a mano con:  zig cc {s} -o {s} -O2\n", .{ ruta_c, @errorName(err), ruta_c, ruta_exe });
        return err;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Falló la compilación de C:\n{s}\n", .{res.stderr});
            return error.CompilacionFallida;
        },
        else => {
            std.debug.print("El compilador C terminó de forma anormal.\n", .{});
            return error.CompilacionFallida;
        },
    }

    const msg = try std.fmt.allocPrint(arena, "Compilado: {s}\n", .{ruta_exe});
    try escribir(io, msg);
}

fn sinExtension(ruta: []const u8) []const u8 {
    const punto = std.mem.lastIndexOfScalar(u8, ruta, '.') orelse return ruta;
    if (std.mem.lastIndexOfAny(u8, ruta, "/\\")) |sep| {
        if (punto < sep) return ruta; // el punto está en un directorio, no en el nombre
    }
    return ruta[0..punto];
}

fn cmdAnalizar(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) !void {
    var prog = try modulos.construir(gpa, io, ruta);
    defer prog.deinit();
    try validarPrograma(gpa, ruta, prog.stmts);
    try escribir(io, "Sin problemas.\n");
}

fn validarPrograma(gpa: std.mem.Allocator, ruta: []const u8, stmts: []const ast.Stmt) !void {
    var an = analizador.Analizador.init(gpa);
    defer an.deinit();
    const diags = try an.analizar(stmts);

    if (diags.len == 0) {
        return;
    }
    for (diags) |d| {
        std.debug.print("{s}:{d}:{d}: {s}\n", .{ ruta, d.pos.linea, d.pos.columna, d.mensaje });
    }
    std.debug.print("{d} problema(s) encontrado(s) en {s}.\n", .{ diags.len, ruta });
    return error.AnalisisFallido;
}

fn cmdNuevo(io: std.Io, gpa: std.mem.Allocator, nombre: []const u8) !void {
    const cwd: std.Io.Dir = .cwd();
    cwd.createDirPath(io, nombre) catch |err| {
        std.debug.print("No se pudo crear el directorio '{s}': {s}\n", .{ nombre, @errorName(err) });
        return err;
    };

    const ruta_principal = try std.fmt.allocPrint(gpa, "{s}/principal.alma", .{nombre});
    defer gpa.free(ruta_principal);
    const ruta_readme = try std.fmt.allocPrint(gpa, "{s}/README.md", .{nombre});
    defer gpa.free(ruta_readme);

    const codigo_principal =
        \\// Programa principal del proyecto.
        \\importar sistema
        \\
        \\funcion principal()
        \\    imprimir("¡Hola desde Alma!")
        \\fin
        \\
    ;
    const readme = try std.fmt.allocPrint(gpa,
        \\# {s}
        \\
        \\Un proyecto en el lenguaje Alma (ecosistema Auralix).
        \\
        \\## Ejecutar
        \\
        \\```
        \\alma ejecutar principal.alma
        \\```
        \\
    , .{nombre});
    defer gpa.free(readme);

    cwd.writeFile(io, .{ .sub_path = ruta_principal, .data = codigo_principal }) catch |err| {
        std.debug.print("No se pudo escribir '{s}': {s}\n", .{ ruta_principal, @errorName(err) });
        return err;
    };
    cwd.writeFile(io, .{ .sub_path = ruta_readme, .data = readme }) catch |err| {
        std.debug.print("No se pudo escribir '{s}': {s}\n", .{ ruta_readme, @errorName(err) });
        return err;
    };

    const ruta_manifiesto = try std.fmt.allocPrint(gpa, "{s}/alma.paquete", .{nombre});
    defer gpa.free(ruta_manifiesto);
    const manifiesto = try std.fmt.allocPrint(gpa,
        \\nombre = {s}
        \\version = 0.1.0
        \\entrada = principal.alma
        \\
        \\[dependencias]
        \\
    , .{nombre});
    defer gpa.free(manifiesto);
    cwd.writeFile(io, .{ .sub_path = ruta_manifiesto, .data = manifiesto }) catch |err| {
        std.debug.print("No se pudo escribir '{s}': {s}\n", .{ ruta_manifiesto, @errorName(err) });
        return err;
    };

    const resumen = try std.fmt.allocPrint(gpa,
        \\Proyecto '{s}' creado:
        \\  {s}/alma.paquete
        \\  {s}/principal.alma
        \\  {s}/README.md
        \\
        \\Para ejecutarlo:
        \\  cd {s}
        \\  alma ejecutar principal.alma
        \\
    , .{ nombre, nombre, nombre, nombre, nombre });
    defer gpa.free(resumen);
    try escribir(io, resumen);
}

fn cmdPaquete(io: std.Io, gpa: std.mem.Allocator, sub: []const u8) !void {
    const cwd: std.Io.Dir = .cwd();
    const fuente = cwd.readFileAlloc(io, "alma.paquete", gpa, .unlimited) catch |err| {
        std.debug.print("No se encontró 'alma.paquete' en el directorio actual.\n", .{});
        return err;
    };
    defer gpa.free(fuente);

    var arena_st = std.heap.ArenaAllocator.init(gpa);
    defer arena_st.deinit();
    const arena = arena_st.allocator();
    const man = try paquete.parsear(arena, fuente);

    if (esIgual(sub, "info")) {
        const info = try std.fmt.allocPrint(arena, "Paquete:      {s}\nVersión:      {s}\nEntrada:      {s}\nDependencias: {d}\n", .{ man.nombre, man.version, man.entrada, man.dependencias.len });
        try escribir(io, info);
        for (man.dependencias) |d| {
            const linea = try std.fmt.allocPrint(arena, "  - {s} -> {s}\n", .{ d.alias, d.ruta });
            try escribir(io, linea);
        }
        return;
    }

    if (esIgual(sub, "validar")) {
        var problemas: usize = 0;
        if (man.nombre.len == 0) {
            std.debug.print("- falta la clave 'nombre'\n", .{});
            problemas += 1;
        }
        if (man.version.len == 0) {
            std.debug.print("- falta la clave 'version'\n", .{});
            problemas += 1;
        }
        if (man.entrada.len == 0) {
            std.debug.print("- falta la clave 'entrada'\n", .{});
            problemas += 1;
        } else if (!archivoExiste(io, man.entrada)) {
            std.debug.print("- el archivo de entrada '{s}' no existe\n", .{man.entrada});
            problemas += 1;
        }
        for (man.dependencias) |d| {
            if (!archivoExiste(io, d.ruta)) {
                std.debug.print("- la dependencia '{s}' apunta a '{s}' que no existe\n", .{ d.alias, d.ruta });
                problemas += 1;
            }
        }
        if (problemas == 0) {
            try escribir(io, "Paquete válido.\n");
        } else {
            std.debug.print("{d} problema(s) en alma.paquete.\n", .{problemas});
            return error.PaqueteInvalido;
        }
        return;
    }

    std.debug.print("Uso: alma paquete <validar|info>\n", .{});
    return error.SubcomandoInvalido;
}

fn archivoExiste(io: std.Io, ruta: []const u8) bool {
    const cwd: std.Io.Dir = .cwd();
    const f = cwd.openFile(io, ruta, .{}) catch return false;
    f.close(io);
    return true;
}

// — Utilidades de E/S (std.Io 0.16) —

fn leerArchivo(io: std.Io, gpa: std.mem.Allocator, ruta: []const u8) ![]u8 {
    const cwd: std.Io.Dir = .cwd();
    return cwd.readFileAlloc(io, ruta, gpa, .unlimited);
}

fn escribir(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn errorArchivo(ruta: []const u8, err: anyerror) anyerror {
    std.debug.print("No se pudo leer '{s}': {s}\n", .{ ruta, @errorName(err) });
    return err;
}

fn imprimirAyuda(io: std.Io) !void {
    const ayuda =
        \\Alma — compilador y herramientas del lenguaje Alma (Auralix)
        \\
        \\Uso: alma <comando> [argumentos]
        \\
        \\Comandos disponibles:
        \\  nuevo    <nombre>         Crea un proyecto nuevo.
        \\  ejecutar <archivo.alma>   Compila al vuelo y ejecuta el programa.
        \\  compilar <archivo.alma>   Compila a un binario nativo (subconjunto; requiere zig cc).
        \\  analizar <archivo.alma>   Revisa el código en busca de errores (linter).
        \\  paquete  <validar|info>   Valida el manifiesto alma.paquete.
        \\  tokens   <archivo.alma>   Muestra el flujo de tokens (desarrollo).
        \\  ast      <archivo.alma>   Muestra el AST del programa (desarrollo).
        \\  version                   Muestra la versión de Alma.
        \\  ayuda                     Muestra esta ayuda.
        \\
        \\Comandos oficiales aún no implementados:
        \\  formatear, probar, doc, lsp
        \\
    ;
    try escribir(io, ayuda);
}
