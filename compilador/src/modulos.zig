//! modulos.zig — Carga y enlazado de módulos (`importar … desde "ruta"`).
//!
//! Alma es multi-archivo: un programa puede repartirse en varios `.alma` y usar
//! `importar SIMBOLO desde "ruta"` para traer definiciones de otro archivo.
//!
//! Este "empaquetador" resuelve las importaciones a partir del archivo de entrada,
//! carga recursivamente los módulos referenciados y produce **un solo programa
//! combinado** (definiciones de los módulos + el archivo de entrada completo) que el
//! intérprete/analizador ejecutan sin cambios. Resolución relativa al archivo que
//! importa. Se cachea por ruta para evitar cargas repetidas y ciclos.

const std = @import("std");
const lexer = @import("lexico/lexer.zig");
const parser = @import("sintaxis/parser.zig");
const ast = @import("sintaxis/ast.zig");
const tk = @import("lexico/token.zig");

/// Error explícito: rompe el bucle de inferencia en la recursión mutua del cargador.
const Err = error{ ErrorCarga, OutOfMemory };

/// Programa combinado, listo para analizar/ejecutar. Es dueño de los recursos
/// (fuentes y parsers) que mantienen vivo el AST; liberar con `deinit`.
pub const Programa = struct {
    stmts: []ast.Stmt = &.{},
    gpa: std.mem.Allocator,
    fuentes: std.ArrayListUnmanaged([]u8) = .empty,
    parsers: std.ArrayListUnmanaged(*parser.Parser) = .empty,

    pub fn deinit(self: *Programa) void {
        if (self.stmts.len > 0) self.gpa.free(self.stmts);
        for (self.parsers.items) |p| {
            p.deinit();
            self.gpa.destroy(p);
        }
        for (self.fuentes.items) |f| self.gpa.free(f);
        self.parsers.deinit(self.gpa);
        self.fuentes.deinit(self.gpa);
    }
};

const Cargador = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    prog: *Programa,
    arena: std.heap.ArenaAllocator,
    defs: std.ArrayListUnmanaged(ast.Stmt) = .empty,
    cargados: std.StringHashMapUnmanaged(enum { cargando, cargado }) = .empty,
    pila: std.ArrayListUnmanaged([]const u8) = .empty,

    fn a(self: *Cargador) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Lee, tokeniza y parsea un archivo. El AST vive en el parser (retenido por
    /// `prog`). Devuelve error tras imprimir el diagnóstico si algo falla.
    fn parseArchivo(self: *Cargador, ruta: []const u8) Err![]ast.Stmt {
        const cwd: std.Io.Dir = .cwd();
        const fuente = cwd.readFileAlloc(self.io, ruta, self.gpa, .unlimited) catch |err| {
            std.debug.print("No se pudo leer '{s}': {s}\n", .{ ruta, @errorName(err) });
            return error.ErrorCarga;
        };
        self.prog.fuentes.append(self.gpa, fuente) catch |err| {
            self.gpa.free(fuente);
            return err;
        };

        const tokens = try lexer.tokenizar(self.gpa, fuente);
        defer self.gpa.free(tokens); // el AST referencia la fuente, no los tokens

        const p = try self.gpa.create(parser.Parser);
        p.* = parser.Parser.init(self.gpa, tokens);
        self.prog.parsers.append(self.gpa, p) catch |err| {
            p.deinit();
            self.gpa.destroy(p);
            return err;
        };

        const stmts = p.parsePrograma() catch {
            if (p.diag) |d| std.debug.print("{s}:{d}:{d}: error de sintaxis: {s}\n", .{ ruta, d.linea, d.columna, d.mensaje });
            return error.ErrorCarga;
        };
        const archivo = try p.arena.allocator().dupe(u8, ruta);
        ast.asignarArchivo(stmts, archivo);
        return stmts;
    }

    /// Carga las dependencias (`importar … desde`) de un programa ya parseado.
    fn cargarDeps(self: *Cargador, dir: []const u8, programa: []const ast.Stmt) Err!void {
        for (programa) |s| {
            switch (s.dato) {
                .importar => |imp| if (imp.desde) |desde| {
                    const ruta = try self.rutaModulo(dir, desde);
                    try self.cargarModulo(ruta, s.pos);
                },
                else => {},
            }
        }
    }

    /// Carga un módulo (si no está cargado): primero sus dependencias, luego acumula
    /// sus definiciones (funcion/estructura/modelo).
    fn cargarModulo(self: *Cargador, ruta: []const u8, pos: ast.Pos) Err!void {
        if (try self.visitado(ruta, pos)) return;
        try self.cargados.put(self.a(), ruta, .cargando);
        try self.pila.append(self.a(), ruta);
        defer self.pila.items.len -= 1;

        const programa = try self.parseArchivo(ruta);
        try self.cargarDeps(dirname(ruta), programa);
        for (programa) |s| {
            switch (s.dato) {
                .funcion, .estructura, .modelo => try self.defs.append(self.a(), s),
                else => {},
            }
        }
        try self.cargados.put(self.a(), ruta, .cargado);
    }

    fn visitado(self: *Cargador, ruta: []const u8, pos: ast.Pos) Err!bool {
        const estado = self.cargados.get(ruta) orelse return false;
        if (estado == .cargado) return true;
        std.debug.print("{s}:{d}:{d}: ciclo de importación: ", .{ pos.archivo orelse ruta, pos.linea, pos.columna });
        for (self.pila.items) |p| std.debug.print("{s} -> ", .{p});
        std.debug.print("{s}\n", .{ruta});
        return error.ErrorCarga;
    }

    fn canonicalizar(self: *Cargador, ruta: []const u8) Err![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, ruta, self.a()) catch |err| {
            std.debug.print("No se pudo resolver '{s}': {s}\n", .{ ruta, @errorName(err) });
            return error.ErrorCarga;
        };
    }

    fn rutaModulo(self: *Cargador, dir: []const u8, desde_lex: []const u8) Err![]const u8 {
        // El lexema de texto incluye las comillas: `"ruta"` -> `ruta`.
        const desde = if (desde_lex.len >= 2 and desde_lex[0] == '"' and desde_lex[desde_lex.len - 1] == '"')
            desde_lex[1 .. desde_lex.len - 1]
        else
            desde_lex;
        const ext = if (std.mem.endsWith(u8, desde, ".alma")) "" else ".alma";
        const archivo = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ desde, ext });
        const ruta = if (std.fs.path.isAbsolute(archivo)) archivo else try std.fs.path.join(self.a(), &.{ dir, archivo });
        return self.canonicalizar(ruta);
    }
};

fn dirname(ruta: []const u8) []const u8 {
    var i = ruta.len;
    while (i > 0) {
        i -= 1;
        if (ruta[i] == '/' or ruta[i] == '\\') return ruta[0..i];
    }
    return ".";
}

/// Construye el programa combinado a partir del archivo de entrada. El llamador es
/// dueño del `Programa` devuelto y debe liberarlo con `deinit`.
pub fn construir(gpa: std.mem.Allocator, io: std.Io, ruta_entrada: []const u8) !Programa {
    var prog = Programa{ .gpa = gpa };
    errdefer prog.deinit();

    var c = Cargador{ .gpa = gpa, .io = io, .prog = &prog, .arena = std.heap.ArenaAllocator.init(gpa) };
    defer c.arena.deinit();

    const ruta = try c.canonicalizar(ruta_entrada);
    try c.cargados.put(c.a(), ruta, .cargando);
    try c.pila.append(c.a(), ruta);
    const entrada = try c.parseArchivo(ruta);
    try c.cargarDeps(dirname(ruta), entrada);
    try c.cargados.put(c.a(), ruta, .cargado);

    // Combinado = definiciones de los módulos ++ programa de entrada completo.
    const total = c.defs.items.len + entrada.len;
    const combinado = try gpa.alloc(ast.Stmt, total);
    std.mem.copyForwards(ast.Stmt, combinado[0..c.defs.items.len], c.defs.items);
    std.mem.copyForwards(ast.Stmt, combinado[c.defs.items.len..], entrada);
    prog.stmts = combinado;

    return prog;
}
