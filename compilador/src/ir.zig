//! IR escalar de Alma: registros, control de flujo y vida útil explícita.
//! No contiene punteros al AST ni código C. Cada registro posee su valor.
const std = @import("std");
const ast = @import("sintaxis/ast.zig");

pub const Reg = usize;
pub const Literal = union(enum) { entero: i64, decimal: f64, texto: []const u8, logico: bool, nulo };
pub const Binaria = enum { sumar, restar, multiplicar, dividir, resto, menor, mayor, menor_igual, mayor_igual, igual, distinto };
pub const Unaria = enum { negar, no, logico, identidad };
pub const Destino = union(enum) { funcion: usize, imprimir, texto };
pub const Instr = struct {
    pos: ast.Pos,
    dato: union(enum) {
        literal: struct { dst: Reg, valor: Literal },
        copiar: struct { dst: Reg, src: Reg },
        liberar: Reg,
        binaria: struct { dst: Reg, izq: Reg, der: Reg, op: Binaria },
        unaria: struct { dst: Reg, src: Reg, op: Unaria },
        llamar: struct { dst: Reg, destino: Destino, args: []const Reg },
        etiqueta: usize,
        saltar: usize,
        condicional: struct { src: Reg, etiqueta: usize, cuando: bool },
        retornar: Reg,
    },
};
pub const Funcion = struct { nombre: []const u8, parametros: usize, registros: usize, instrucciones: []const Instr };
pub const Programa = struct {
    arena: std.heap.ArenaAllocator,
    funciones: []const Funcion = &.{},
    entrada: usize = 0,
    diag: ?[]const u8 = null,
    pub fn deinit(self: *Programa) void {
        self.arena.deinit();
    }
};
const Error = error{ OutOfMemory, NoSoportado };
const Bucle = struct { inicio: usize, fin: usize };
const Constructor = struct {
    a: std.mem.Allocator,
    programa: *Programa,
    nombres: std.StringHashMapUnmanaged(usize) = .{},
    archivos: std.StringHashMapUnmanaged([]const u8) = .{},
    aridades: std.ArrayListUnmanaged(usize) = .empty,
    variables: std.StringHashMapUnmanaged(Reg) = .{},
    instrucciones: std.ArrayListUnmanaged(Instr) = .empty,
    bucles: std.ArrayListUnmanaged(Bucle) = .empty,
    registros: usize = 0,
    etiquetas: usize = 0,
    pos: ast.Pos = .{},

    fn fallo(self: *Constructor, mensaje: []const u8) Error {
        self.programa.diag = self.a.dupe(u8, mensaje) catch return error.OutOfMemory;
        return error.NoSoportado;
    }
    fn emitir(self: *Constructor, dato: @FieldType(Instr, "dato")) Error!void {
        var pos = self.pos;
        if (pos.archivo) |archivo| {
            if (self.archivos.get(archivo)) |propio| {
                pos.archivo = propio;
            } else {
                const propio = try self.a.dupe(u8, archivo);
                try self.archivos.put(self.a, propio, propio);
                pos.archivo = propio;
            }
        }
        try self.instrucciones.append(self.a, .{ .pos = pos, .dato = dato });
    }
    fn reg(self: *Constructor) Reg {
        const r = self.registros;
        self.registros += 1;
        return r;
    }
    fn etiqueta(self: *Constructor) usize {
        const r = self.etiquetas;
        self.etiquetas += 1;
        return r;
    }
    fn liberar(self: *Constructor, r: Reg) Error!void {
        try self.emitir(.{ .liberar = r });
    }
    fn variable(self: *Constructor, nombre: []const u8) Error!Reg {
        if (self.variables.get(nombre)) |r| return r;
        const r = self.reg();
        try self.variables.put(self.a, try self.a.dupe(u8, nombre), r);
        return r;
    }
    fn literal(self: *Constructor, valor: Literal) Error!Reg {
        const r = self.reg();
        try self.emitir(.{ .literal = .{ .dst = r, .valor = valor } });
        return r;
    }
    fn decodificar(self: *Constructor, lex: []const u8) Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const inner = lex[1 .. lex.len - 1];
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            var c = inner[i];
            if (c == '\\' and i + 1 < inner.len) {
                i += 1;
                c = switch (inner[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => inner[i],
                };
            }
            try out.append(self.a, c);
        }
        return out.toOwnedSlice(self.a);
    }
    fn expr(self: *Constructor, e: *const ast.Expr) Error!Reg {
        switch (e.*) {
            .literal_entero => |s| return self.literal(.{ .entero = std.fmt.parseInt(i64, s, 10) catch return self.fallo("entero fuera del rango i64") }),
            .literal_decimal => |s| return self.literal(.{ .decimal = std.fmt.parseFloat(f64, s) catch return self.fallo("decimal inválido") }),
            .literal_texto => |s| return self.literal(.{ .texto = try self.decodificar(s) }),
            .literal_bool => |b| return self.literal(.{ .logico = b }),
            .literal_nulo => return self.literal(.nulo),
            .identificador => |n| {
                const origen = self.variables.get(n) orelse return self.fallo("variable no disponible en el subconjunto nativo");
                const dst = self.reg();
                try self.emitir(.{ .copiar = .{ .dst = dst, .src = origen } });
                return dst;
            },
            .unaria => |u| {
                const op: Unaria = switch (u.op) {
                    .menos => .negar,
                    .no_logico => .no,
                    .kw_esperar => .identidad,
                    else => return self.fallo("operador unario no soportado"),
                };
                const src = try self.expr(u.operando);
                const dst = self.reg();
                try self.emitir(.{ .unaria = .{ .dst = dst, .src = src, .op = op } });
                try self.liberar(src);
                return dst;
            },
            .binaria => |b| {
                const izq = try self.expr(b.izq);
                const dst = self.reg();
                if (b.op == .y_logico or b.op == .o_logico) {
                    const fin = self.etiqueta();
                    try self.emitir(.{ .unaria = .{ .dst = dst, .src = izq, .op = .logico } });
                    try self.liberar(izq);
                    try self.emitir(.{ .condicional = .{ .src = dst, .etiqueta = fin, .cuando = b.op == .o_logico } });
                    const der = try self.expr(b.der);
                    try self.emitir(.{ .unaria = .{ .dst = dst, .src = der, .op = .logico } });
                    try self.liberar(der);
                    try self.emitir(.{ .etiqueta = fin });
                } else {
                    const op: Binaria = switch (b.op) {
                        .mas => .sumar,
                        .menos => .restar,
                        .por => .multiplicar,
                        .entre => .dividir,
                        .modulo => .resto,
                        .menor => .menor,
                        .mayor => .mayor,
                        .menor_igual => .menor_igual,
                        .mayor_igual => .mayor_igual,
                        .igual => .igual,
                        .distinto => .distinto,
                        else => return self.fallo("operador binario no soportado"),
                    };
                    const der = try self.expr(b.der);
                    try self.emitir(.{ .binaria = .{ .dst = dst, .izq = izq, .der = der, .op = op } });
                    try self.liberar(izq);
                    try self.liberar(der);
                }
                return dst;
            },
            .llamada => |l| {
                if (l.callee.* != .identificador) return self.fallo("la compilación requiere una función con nombre");
                const n = l.callee.identificador;
                if (self.variables.contains(n)) return self.fallo("las llamadas mediante variables todavía no se compilan");
                const destino: Destino = if (self.nombres.get(n)) |id| blk: {
                    if (l.args.len != self.aridades.items[id]) return self.fallo("cantidad de argumentos incorrecta");
                    break :blk .{ .funcion = id };
                } else if (std.mem.eql(u8, n, "imprimir")) .imprimir else if (std.mem.eql(u8, n, "texto")) blk: {
                    if (l.args.len != 1) return self.fallo("texto() espera 1 argumento");
                    break :blk .texto;
                } else return self.fallo("función no soportada por el backend nativo");
                const args = try self.a.alloc(Reg, l.args.len);
                for (l.args, 0..) |arg, i| args[i] = try self.expr(arg);
                const dst = self.reg();
                try self.emitir(.{ .llamar = .{ .dst = dst, .destino = destino, .args = args } });
                for (args) |r| try self.liberar(r);
                return dst;
            },
            else => return self.fallo("expresión fuera del subconjunto nativo: colecciones/acceso a miembros pendientes"),
        }
    }
    fn bloque(self: *Constructor, cuerpo: []const ast.Stmt) Error!void {
        for (cuerpo) |s| {
            self.pos = s.pos;
            switch (s.dato) {
                .declaracion => |d| {
                    const src = try self.expr(d.valor);
                    const dst = try self.variable(d.nombre);
                    try self.emitir(.{ .copiar = .{ .dst = dst, .src = src } });
                    try self.liberar(src);
                },
                .asignacion => |d| {
                    if (d.objetivo.* != .identificador) return self.fallo("asignación a colecciones/objetos pendiente");
                    const src = try self.expr(d.valor);
                    const dst = try self.variable(d.objetivo.identificador);
                    try self.emitir(.{ .copiar = .{ .dst = dst, .src = src } });
                    try self.liberar(src);
                },
                .expresion => |e| try self.liberar(try self.expr(e)),
                .retornar => |e| try self.emitir(.{ .retornar = if (e) |v| try self.expr(v) else try self.literal(.nulo) }),
                .si => |sif| {
                    const fin = self.etiqueta();
                    for (sif.ramas) |rama| {
                        const siguiente = self.etiqueta();
                        const condicion = try self.expr(rama.condicion);
                        try self.emitir(.{ .condicional = .{ .src = condicion, .etiqueta = siguiente, .cuando = false } });
                        try self.liberar(condicion);
                        try self.bloque(rama.cuerpo);
                        try self.emitir(.{ .saltar = fin });
                        try self.emitir(.{ .etiqueta = siguiente });
                        try self.liberar(condicion);
                    }
                    if (sif.sino) |otro| try self.bloque(otro);
                    try self.emitir(.{ .etiqueta = fin });
                },
                .mientras => |m| {
                    const inicio = self.etiqueta();
                    const fin = self.etiqueta();
                    try self.bucles.append(self.a, .{ .inicio = inicio, .fin = fin });
                    try self.emitir(.{ .etiqueta = inicio });
                    const condicion = try self.expr(m.condicion);
                    try self.emitir(.{ .condicional = .{ .src = condicion, .etiqueta = fin, .cuando = false } });
                    try self.liberar(condicion);
                    try self.bloque(m.cuerpo);
                    try self.emitir(.{ .saltar = inicio });
                    try self.emitir(.{ .etiqueta = fin });
                    try self.liberar(condicion);
                    self.bucles.items.len -= 1;
                },
                .romper, .continuar => {
                    if (self.bucles.items.len == 0) return self.fallo("control de bucle fuera de un bucle");
                    const b = self.bucles.items[self.bucles.items.len - 1];
                    try self.emitir(.{ .saltar = if (s.dato == .romper) b.fin else b.inicio });
                },
                else => return self.fallo("sentencia fuera del subconjunto nativo: tipos, colecciones, errores y concurrencia pendientes"),
            }
        }
    }
    fn construir(self: *Constructor, stmts: []const ast.Stmt) Error!void {
        for (stmts) |s| switch (s.dato) {
            .funcion => |f| {
                if (f.asincrona) return self.fallo("las funciones asíncronas todavía no se compilan");
                if (self.nombres.contains(f.nombre)) return self.fallo("función duplicada");
                try self.nombres.put(self.a, try self.a.dupe(u8, f.nombre), self.aridades.items.len);
                try self.aridades.append(self.a, f.params.len);
            },
            .importar => {},
            else => return self.fallo("la compilación requiere código dentro de funciones"),
        };
        self.programa.entrada = self.nombres.get("principal") orelse return self.fallo("falta la función principal()");
        if (self.aridades.items[self.programa.entrada] != 0) return self.fallo("principal() no puede recibir parámetros");
        var funciones: std.ArrayListUnmanaged(Funcion) = .empty;
        for (stmts) |s| if (s.dato == .funcion) {
            const f = s.dato.funcion;
            self.variables = .{};
            self.instrucciones = .empty;
            self.registros = 0;
            self.etiquetas = 0;
            self.pos = s.pos;
            for (f.params) |p| {
                if (self.variables.contains(p.nombre)) return self.fallo("parámetro duplicado");
                _ = try self.variable(p.nombre);
            }
            try self.bloque(f.cuerpo);
            try self.emitir(.{ .retornar = try self.literal(.nulo) });
            try funciones.append(self.a, .{ .nombre = try self.a.dupe(u8, f.nombre), .parametros = f.params.len, .registros = self.registros, .instrucciones = try self.instrucciones.toOwnedSlice(self.a) });
        };
        self.programa.funciones = try funciones.toOwnedSlice(self.a);
    }
};

pub fn construir(gpa: std.mem.Allocator, stmts: []const ast.Stmt) error{OutOfMemory}!Programa {
    var programa = Programa{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer programa.deinit();
    var c = Constructor{ .a = programa.arena.allocator(), .programa = &programa };
    c.construir(stmts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSoportado => {},
    };
    return programa;
}

/// Formato de inspección versionado; no serializa allocators ni punteros al AST.
pub fn escribir(a: std.mem.Allocator, programa: *const Programa) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .version = @as(u32, 1),
        .entrada = programa.entrada,
        .funciones = programa.funciones,
    }, .{ .whitespace = .indent_2 });
}

fn programaPrueba(a: std.mem.Allocator, fuente: []const u8) !Programa {
    const lexer = @import("lexico/lexer.zig");
    const parser = @import("sintaxis/parser.zig");
    const tokens = try lexer.tokenizar(a, fuente);
    defer a.free(tokens);
    var p = parser.Parser.init(a, tokens);
    defer p.deinit();
    return construir(a, try p.parsePrograma());
}

test "IR conserva sus datos despues de liberar parser y tokens" {
    var p = try programaPrueba(std.testing.allocator,
        \\funcion principal()
        \\    imprimir("á\ntexto")
        \\fin
    );
    defer p.deinit();
    try std.testing.expect(p.diag == null);
    try std.testing.expectEqualStrings("principal", p.funciones[0].nombre);
    const literal_texto = p.funciones[0].instrucciones[0].dato.literal;
    try std.testing.expectEqualStrings("á\ntexto", literal_texto.valor.texto);
}

test "IR rechaza entrada con parametros y funciones asincronas" {
    for ([_][]const u8{
        "funcion principal(n: entero)\n    retornar nulo\nfin\n",
        "asincrona funcion principal()\n    retornar nulo\nfin\n",
    }) |src| {
        var p = try programaPrueba(std.testing.allocator, src);
        defer p.deinit();
        try std.testing.expect(p.diag != null);
    }
}

fn probarFalloAsignacion(a: std.mem.Allocator) !void {
    var p = try programaPrueba(a,
        \\funcion principal()
        \\    i = 0
        \\    mientras i < 2
        \\        imprimir(texto(i) + "x")
        \\        i = i + 1
        \\    fin
        \\fin
    );
    defer p.deinit();
    try std.testing.expect(p.diag == null);
}

test "IR libera recursos ante fallos de asignacion" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, probarFalloAsignacion, .{});
}
