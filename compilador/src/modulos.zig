//! modulos.zig — Carga y enlazado de módulos (`importar … desde "ruta"`).
//!
//! Alma es multi-archivo: un programa puede repartirse en varios `.alma` y usar
//! `importar SIMBOLO desde "ruta"` para traer definiciones de otro archivo.
//!
//! Devuelve unidades en orden de dependencias y enlaces a símbolos exportados.
//! No mezcla los espacios de nombres ni modifica los identificadores del AST.

const std = @import("std");
const lexer = @import("lexico/lexer.zig");
const parser = @import("sintaxis/parser.zig");
const ast = @import("sintaxis/ast.zig");
const limites = @import("limites.zig");

pub const Enlace = struct { nombre: []const u8, unidad: *const Unidad, simbolo: *const ast.Stmt };
pub const Unidad = struct {
    ruta: []const u8,
    stmts: []ast.Stmt,
    enlaces: []const Enlace = &.{},
    cargando: bool = true,
};

/// Error explícito: rompe el bucle de inferencia en la recursión mutua del cargador.
const Err = error{ ErrorCarga, OutOfMemory };

/// Grafo de unidades, listo para analizar/ejecutar. Es dueño de los recursos
/// (fuentes y parsers) que mantienen vivo el AST; liberar con `deinit`.
pub const Programa = struct {
    unidades: []const *Unidad = &.{},
    entrada: *Unidad = undefined,
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    fuentes: std.ArrayListUnmanaged([]u8) = .empty,
    parsers: std.ArrayListUnmanaged(*parser.Parser) = .empty,

    pub fn deinit(self: *Programa) void {
        self.arena.deinit();
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
    unidades: std.ArrayListUnmanaged(*Unidad) = .empty,
    cargados: std.StringHashMapUnmanaged(*Unidad) = .empty,
    pila: std.ArrayListUnmanaged([]const u8) = .empty,

    fn a(self: *Cargador) std.mem.Allocator {
        return self.prog.arena.allocator();
    }

    /// Lee, tokeniza y parsea un archivo. El AST vive en el parser (retenido por
    /// `prog`). Devuelve error tras imprimir el diagnóstico si algo falla.
    fn parseArchivo(self: *Cargador, ruta: []const u8) Err![]ast.Stmt {
        const cwd: std.Io.Dir = .cwd();
        const fuente = cwd.readFileAlloc(self.io, ruta, self.gpa, @enumFromInt(limites.archivo_fuente)) catch |err| {
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

    fn cargarModulo(self: *Cargador, ruta: []const u8, pos: ast.Pos, entrada: bool) Err!*Unidad {
        if (self.cargados.get(ruta)) |u| {
            if (u.cargando) {
                std.debug.print("{s}:{d}:{d}: ciclo de importación: ", .{ pos.archivo orelse ruta, pos.linea, pos.columna });
                for (self.pila.items) |p| std.debug.print("{s} -> ", .{p});
                std.debug.print("{s}\n", .{ruta});
                return error.ErrorCarga;
            }
            return u;
        }
        const unidad = try self.a().create(Unidad);
        unidad.* = .{ .ruta = ruta, .stmts = try self.parseArchivo(ruta) };
        try self.cargados.put(self.a(), ruta, unidad);
        try self.pila.append(self.a(), ruta);
        defer self.pila.items.len -= 1;
        var nombres: std.StringHashMapUnmanaged(*const ast.Stmt) = .empty;
        var enlaces: std.ArrayListUnmanaged(Enlace) = .empty;
        for (unidad.stmts) |*s| {
            try validarImportaciones(s.*, true);
            const nombre: ?[]const u8 = switch (s.dato) {
                .funcion => |f| f.nombre,
                .estructura => |e| e.nombre,
                .modelo => |m| m.nombre,
                .declaracion => |d| d.nombre,
                .importar => null,
                else => blk: {
                    if (!entrada) return fallo(s.pos, "sentencia de nivel superior no permitida en un módulo");
                    break :blk null;
                },
            };
            if (!entrada and s.dato == .declaracion and !s.dato.declaracion.fijo)
                return fallo(s.pos, "solo fijo puede declarar valores globales de un módulo");
            if (nombre) |n| {
                if (nombres.contains(n)) return fallo(s.pos, "redefinición de nombre en el módulo");
                try nombres.put(self.a(), n, s);
            }
        }
        for (unidad.stmts) |*s| if (s.dato == .importar) {
            const imp = s.dato.importar;
            if (imp.desde) |desde| {
                const destino = try self.cargarModulo(try self.rutaModulo(dirname(ruta), desde), s.pos, false);
                var simbolo: ?*const ast.Stmt = null;
                for (destino.stmts) |*d| {
                    const n: ?[]const u8 = switch (d.dato) {
                        .funcion => |f| if (f.exportar) f.nombre else null,
                        .estructura => |e| if (e.exportar) e.nombre else null,
                        .modelo => |m| if (m.exportar) m.nombre else null,
                        .declaracion => |dc| if (dc.exportar) dc.nombre else null,
                        else => null,
                    };
                    if (n) |v| if (std.mem.eql(u8, v, imp.que)) {
                        simbolo = d;
                        break;
                    };
                }
                const d = simbolo orelse return fallo(s.pos, "símbolo no exportado por el módulo");
                if (nombres.get(imp.que)) |previo| {
                    if (previo == d) continue;
                    return fallo(s.pos, "conflicto de nombre importado");
                }
                try nombres.put(self.a(), imp.que, d);
                try enlaces.append(self.a(), .{ .nombre = imp.que, .unidad = destino, .simbolo = d });
            } else {
                if (nombres.get(imp.que)) |previo| {
                    if (previo.dato == .importar and previo.dato.importar.desde == null) continue;
                    return fallo(s.pos, "conflicto de nombre importado");
                }
                try nombres.put(self.a(), imp.que, s);
            }
        };
        unidad.enlaces = try enlaces.toOwnedSlice(self.a());
        unidad.cargando = false;
        try self.unidades.append(self.a(), unidad);
        return unidad;
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

/// Construye el grafo a partir del archivo de entrada. El llamador es
/// dueño del `Programa` devuelto y debe liberarlo con `deinit`.
pub fn construir(gpa: std.mem.Allocator, io: std.Io, ruta_entrada: []const u8) !Programa {
    var prog = Programa{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer prog.deinit();

    var c = Cargador{ .gpa = gpa, .io = io, .prog = &prog };
    const ruta = try c.canonicalizar(ruta_entrada);
    prog.entrada = try c.cargarModulo(ruta, .{}, true);
    prog.unidades = try c.unidades.toOwnedSlice(c.a());
    return prog;
}

fn fallo(pos: ast.Pos, mensaje: []const u8) Err {
    std.debug.print("{s}:{d}:{d}: {s}\n", .{ pos.archivo orelse "programa", pos.linea, pos.columna, mensaje });
    return error.ErrorCarga;
}

fn validarBloque(stmts: []const ast.Stmt) Err!void {
    for (stmts) |s| try validarImportaciones(s, false);
}
fn validarImportaciones(s: ast.Stmt, superior: bool) Err!void {
    switch (s.dato) {
        .importar => if (!superior) return fallo(s.pos, "importar solo se permite a nivel superior"),
        .funcion => |f| try validarBloque(f.cuerpo),
        .modelo => |m| for (m.metodos) |f| {
            try validarBloque(f.cuerpo);
        },
        .si => |v| {
            for (v.ramas) |r| try validarBloque(r.cuerpo);
            if (v.sino) |b| try validarBloque(b);
        },
        .mientras => |v| try validarBloque(v.cuerpo),
        .para => |v| try validarBloque(v.cuerpo),
        .intentar => |v| {
            try validarBloque(v.cuerpo);
            try validarBloque(v.captura);
        },
        else => {},
    }
}
