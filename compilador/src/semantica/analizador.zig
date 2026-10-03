//! analizador.zig — Análisis semántico del lenguaje Alma (comando `alma analizar`).
//!
//! Recorre el AST y detecta errores *antes* de ejecutar:
//!   - nombres no definidos (variables, funciones, tipos);
//!   - aridad incorrecta al llamar funciones o construir tipos;
//!   - `retornar` fuera de una función; `romper`/`continuar` fuera de un bucle;
//!   - reasignación de constantes (`fijo`);
//!   - redefiniciones y campos/parámetros duplicados.
//!
//! Usa resolución de nombres con una pila de ámbitos. Coherente con el intérprete,
//! el alcance de las variables es a nivel de función (los bloques no crean ámbito).
//! Nota: v0.1 reporta por nombre; las posiciones exactas (línea/columna) son un paso
//! posterior (requiere propagar posiciones por el AST).

const std = @import("std");
const lexer = @import("../lexico/lexer.zig");
const parser = @import("../sintaxis/parser.zig");
const ast = @import("../sintaxis/ast.zig");
const modulos = @import("../modulos.zig");

const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Error = std.mem.Allocator.Error;

const sin_campos = [_]ast.Campo{};

pub const Diagnostico = struct {
    mensaje: []const u8,
    pos: ast.Pos = .{},
};

const Clase = enum { variable, constante, funcion, tipo, parametro, campo, nativa };

/// Tipo de un valor para el chequeo gradual. `desconocido` es dinámico: nunca produce
/// un error de tipo, así el código sin anotaciones no genera falsos positivos.
const Tipo = union(enum) {
    desconocido,
    entero,
    decimal,
    texto,
    logico,
    nulo,
    lista,
    diccionario,
    funcion,
    modulo,
    instancia: []const u8,
};

fn esNumero(t: Tipo) bool {
    return t == .entero or t == .decimal;
}

fn compatible(a: Tipo, b: Tipo) bool {
    if (a == .desconocido or b == .desconocido) return true;
    if (esNumero(a) and esNumero(b)) return true;
    return switch (a) {
        .instancia => |na| switch (b) {
            .instancia => |nb| std.mem.eql(u8, na, nb),
            else => false,
        },
        else => std.meta.activeTag(a) == std.meta.activeTag(b),
    };
}

fn nombreATipo(s: []const u8) Tipo {
    if (std.mem.eql(u8, s, "entero")) return .entero;
    if (std.mem.eql(u8, s, "decimal")) return .decimal;
    if (std.mem.eql(u8, s, "texto")) return .texto;
    if (std.mem.eql(u8, s, "logico")) return .logico;
    if (std.mem.eql(u8, s, "nulo")) return .nulo;
    if (std.mem.eql(u8, s, "lista")) return .lista;
    if (std.mem.eql(u8, s, "diccionario")) return .diccionario;
    return .{ .instancia = s };
}

fn nombreTipo(t: Tipo) []const u8 {
    return switch (t) {
        .desconocido => "desconocido",
        .entero => "entero",
        .decimal => "decimal",
        .texto => "texto",
        .logico => "logico",
        .nulo => "nulo",
        .lista => "lista",
        .diccionario => "diccionario",
        .funcion => "funcion",
        .modulo => "modulo",
        .instancia => |n| n,
    };
}

const Simbolo = struct {
    importado: bool = false,
    clase: Clase,
    aridad: usize = 0,
    /// Tipo del valor (variables, parámetros; para funciones = tipo de retorno).
    tipo: Tipo = .desconocido,
    /// Para funciones de usuario: nodo AST (permite chequear tipos de argumentos).
    func: ?*const ast.Stmt.Funcion = null,
};

const Ambito = std.StringHashMapUnmanaged(Simbolo);

pub const Analizador = struct {
    arena: std.heap.ArenaAllocator,
    diagnosticos: std.ArrayListUnmanaged(Diagnostico) = .empty,
    ambitos: std.ArrayListUnmanaged(Ambito) = .empty,
    prof_func: usize = 0,
    prof_bucle: usize = 0,
    pos_actual: ast.Pos = .{},
    /// Tipo de retorno declarado de la función que se está analizando.
    retorno_actual: Tipo = .desconocido,

    pub fn init(gpa: std.mem.Allocator) Analizador {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Analizador) void {
        self.arena.deinit();
    }

    fn a(self: *Analizador) std.mem.Allocator {
        return self.arena.allocator();
    }

    // — Ámbitos —

    fn push(self: *Analizador) Error!void {
        try self.ambitos.append(self.a(), .{});
    }

    fn pop(self: *Analizador) void {
        self.ambitos.items.len -= 1; // la memoria se libera con la arena
    }

    fn cima(self: *Analizador) *Ambito {
        return &self.ambitos.items[self.ambitos.items.len - 1];
    }

    fn definir(self: *Analizador, nombre: []const u8, sim: Simbolo) Error!void {
        try self.cima().put(self.a(), nombre, sim);
    }

    fn resolver(self: *Analizador, nombre: []const u8) ?Simbolo {
        var i = self.ambitos.items.len;
        while (i > 0) {
            i -= 1;
            if (self.ambitos.items[i].get(nombre)) |s| return s;
        }
        return null;
    }

    fn err(self: *Analizador, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.a(), fmt, args);
        try self.diagnosticos.append(self.a(), .{ .mensaje = msg, .pos = self.pos_actual });
    }

    // — Entrada principal —

    /// Analiza el programa y devuelve la lista de diagnósticos (vacía = sin problemas).
    pub fn analizar(self: *Analizador, programa: []const Stmt) Error![]Diagnostico {
        try self.push(); // ámbito de funciones nativas
        try self.registrarNativas();
        try self.push(); // ámbito global del usuario

        // Pase 1: registrar funciones y tipos de nivel superior (permite recursión mutua).
        for (programa) |*s| try self.registrarGlobal(s);
        // Pase 2: analizar en orden.
        for (programa) |s| try self.analizarStmt(s);

        return self.diagnosticos.toOwnedSlice(self.a());
    }

    pub fn analizarModulos(self: *Analizador, programa: *const modulos.Programa) Error![]Diagnostico {
        for (programa.unidades) |unidad| {
            self.ambitos.items.len = 0;
            try self.push();
            try self.registrarNativas();
            try self.push();
            for (unidad.stmts) |*s| {
                if (s.dato == .importar and s.dato.importar.desde != null) continue;
                try self.registrarGlobal(s);
                if (s.dato == .declaracion) {
                    const d = s.dato.declaracion;
                    try self.definir(d.nombre, .{ .clase = if (d.fijo) .constante else .variable, .tipo = if (d.tipo) |t| nombreATipo(t) else .desconocido });
                }
            }
            for (unidad.enlaces) |enlace| {
                try self.registrarGlobal(enlace.simbolo);
                if (enlace.simbolo.dato == .declaracion) {
                    const d = enlace.simbolo.dato.declaracion;
                    try self.definir(d.nombre, .{ .clase = if (d.fijo) .constante else .variable, .tipo = if (d.tipo) |t| nombreATipo(t) else .desconocido });
                }
                self.cima().getPtr(enlace.nombre).?.importado = true;
            }
            for (unidad.stmts) |s| try self.analizarStmt(s);
        }
        return self.diagnosticos.toOwnedSlice(self.a());
    }

    fn registrarNativas(self: *Analizador) Error!void {
        const nombres = [_][]const u8{ "imprimir", "rango", "longitud", "agregar", "texto", "claves", "tiene", "error" };
        for (nombres) |n| try self.definir(n, .{ .clase = .nativa });
    }

    fn registrarGlobal(self: *Analizador, s: *const Stmt) Error!void {
        self.pos_actual = s.pos;
        switch (s.dato) {
            .funcion => |*f| {
                if (self.cima().get(f.nombre)) |_| {
                    try self.err("redefinición de '{s}'", .{f.nombre});
                } else {
                    const ret = if (f.retorno) |ts| nombreATipo(ts) else Tipo.desconocido;
                    try self.definir(f.nombre, .{ .clase = .funcion, .aridad = f.params.len, .tipo = ret, .func = f });
                }
            },
            .estructura => |e| try self.registrarTipoGlobal(e.nombre, e.campos.len),
            .modelo => |m| try self.registrarTipoGlobal(m.nombre, m.campos.len),
            .importar => |imp| {
                // Si el símbolo ya existe (p. ej. lo aportó el módulo cargado), no lo redefinas.
                if (self.cima().get(imp.que) == null) try self.definir(imp.que, .{ .clase = .nativa });
            },
            else => {},
        }
    }

    fn registrarTipoGlobal(self: *Analizador, nombre: []const u8, aridad: usize) Error!void {
        if (self.cima().get(nombre)) |_| {
            try self.err("redefinición de '{s}'", .{nombre});
        } else {
            try self.definir(nombre, .{ .clase = .tipo, .aridad = aridad, .tipo = .{ .instancia = nombre } });
        }
    }

    // — Sentencias —

    fn analizarBloque(self: *Analizador, cuerpo: []const Stmt) Error!void {
        for (cuerpo) |s| try self.analizarStmt(s);
    }

    fn analizarStmt(self: *Analizador, s: Stmt) Error!void {
        self.pos_actual = s.pos;
        switch (s.dato) {
            .declaracion => |d| {
                if (self.cima().get(d.nombre)) |sim| {
                    if (sim.importado) try self.err("no se puede redefinir el nombre importado '{s}'", .{d.nombre});
                }
                try self.analizarExpr(d.valor);
                const vt = self.tipoDeExpr(d.valor);
                var tipo_var: Tipo = .desconocido;
                if (d.tipo) |ts| {
                    tipo_var = nombreATipo(ts);
                    if (!compatible(tipo_var, vt)) {
                        try self.err("'{s}' es {s} pero se le asigna un valor {s}", .{ d.nombre, nombreTipo(tipo_var), nombreTipo(vt) });
                    }
                } else if (d.fijo) {
                    tipo_var = vt; // constante sin anotación: inferimos el tipo del valor
                }
                try self.definir(d.nombre, .{ .clase = if (d.fijo) .constante else .variable, .tipo = tipo_var });
            },
            .asignacion => |asig| {
                try self.analizarExpr(asig.valor);
                switch (asig.objetivo.*) {
                    .identificador => |nombre| {
                        if (self.resolver(nombre)) |sim| {
                            if (sim.importado) {
                                try self.err("no se puede reasignar el nombre importado '{s}'", .{nombre});
                            } else if (sim.clase == .constante) {
                                try self.err("no se puede reasignar la constante '{s}'", .{nombre});
                            } else if (sim.tipo != .desconocido) {
                                const vt = self.tipoDeExpr(asig.valor);
                                if (!compatible(sim.tipo, vt)) {
                                    try self.err("'{s}' es {s} pero se le asigna un valor {s}", .{ nombre, nombreTipo(sim.tipo), nombreTipo(vt) });
                                }
                            }
                        } else {
                            try self.definir(nombre, .{ .clase = .variable }); // sin anotación → dinámico
                        }
                    },
                    else => try self.analizarExpr(asig.objetivo),
                }
            },
            .expresion => |e| try self.analizarExpr(e),
            .retornar => |maybe| {
                if (self.prof_func == 0) try self.err("'retornar' fuera de una función", .{});
                if (maybe) |e| {
                    try self.analizarExpr(e);
                    if (self.retorno_actual != .desconocido) {
                        const vt = self.tipoDeExpr(e);
                        if (!compatible(self.retorno_actual, vt)) {
                            try self.err("la función debe devolver {s} pero se retorna {s}", .{ nombreTipo(self.retorno_actual), nombreTipo(vt) });
                        }
                    }
                }
            },
            .romper => {
                if (self.prof_bucle == 0) try self.err("'romper' fuera de un bucle", .{});
            },
            .continuar => {
                if (self.prof_bucle == 0) try self.err("'continuar' fuera de un bucle", .{});
            },
            .si => |si| {
                for (si.ramas) |r| {
                    try self.analizarExpr(r.condicion);
                    try self.checarCondicion(r.condicion);
                    try self.analizarBloque(r.cuerpo);
                }
                if (si.sino) |cuerpo| try self.analizarBloque(cuerpo);
            },
            .mientras => |m| {
                try self.analizarExpr(m.condicion);
                try self.checarCondicion(m.condicion);
                self.prof_bucle += 1;
                try self.analizarBloque(m.cuerpo);
                self.prof_bucle -= 1;
            },
            .para => |p| {
                try self.analizarExpr(p.iterable);
                try self.definir(p.variable, .{ .clase = .variable });
                self.prof_bucle += 1;
                try self.analizarBloque(p.cuerpo);
                self.prof_bucle -= 1;
            },
            .funcion => |f| {
                if (self.resolver(f.nombre) == null) {
                    const ret = if (f.retorno) |ts| nombreATipo(ts) else Tipo.desconocido;
                    try self.definir(f.nombre, .{ .clase = .funcion, .aridad = f.params.len, .tipo = ret });
                }
                try self.analizarFuncion(f, false, &sin_campos);
            },
            .estructura => |e| try self.checarCampos(e.campos),
            .modelo => |m| {
                try self.checarCampos(m.campos);
                for (m.metodos) |metodo| try self.analizarFuncion(metodo, true, m.campos);
            },
            .importar => {}, // ya registrado en el pase 1
            .intentar => |t| {
                try self.analizarBloque(t.cuerpo);
                try self.definir(t.variable, .{ .clase = .variable });
                try self.analizarBloque(t.captura);
            },
            .lanzar => |e| try self.analizarExpr(e),
            .hilo => |e| try self.analizarExpr(e),
        }
    }

    fn analizarFuncion(self: *Analizador, f: Stmt.Funcion, es_metodo: bool, campos: []const ast.Campo) Error!void {
        try self.push();
        defer self.pop();

        const ret_previo = self.retorno_actual;
        self.retorno_actual = if (f.retorno) |ts| nombreATipo(ts) else Tipo.desconocido;
        defer self.retorno_actual = ret_previo;

        if (es_metodo) {
            for (campos) |c| try self.definir(c.nombre, .{ .clase = .campo, .tipo = nombreATipo(c.tipo) });
            try self.definir("yo", .{ .clase = .variable });
        }
        for (f.params, 0..) |p, i| {
            for (f.params[0..i]) |p2| {
                if (std.mem.eql(u8, p.nombre, p2.nombre)) try self.err("parámetro duplicado '{s}' en '{s}'", .{ p.nombre, f.nombre });
            }
            const pt = if (p.tipo) |ts| nombreATipo(ts) else Tipo.desconocido;
            try self.definir(p.nombre, .{ .clase = .parametro, .tipo = pt });
        }

        self.prof_func += 1;
        try self.analizarBloque(f.cuerpo);
        self.prof_func -= 1;
    }

    fn checarCampos(self: *Analizador, campos: []const ast.Campo) Error!void {
        for (campos, 0..) |c, i| {
            for (campos[0..i]) |c2| {
                if (std.mem.eql(u8, c.nombre, c2.nombre)) try self.err("campo duplicado '{s}'", .{c.nombre});
            }
        }
    }

    // — Expresiones —

    fn analizarExpr(self: *Analizador, e: *const Expr) Error!void {
        switch (e.*) {
            .literal_entero, .literal_decimal, .literal_texto, .literal_bool, .literal_nulo => {},
            .identificador => |nombre| {
                if (self.resolver(nombre) == null) try self.err("nombre no definido: '{s}'", .{nombre});
            },
            .unaria => |u| {
                try self.analizarExpr(u.operando);
                try self.checarUnaria(u);
            },
            .binaria => |b| {
                try self.analizarExpr(b.izq);
                try self.analizarExpr(b.der);
                try self.checarBinaria(b);
            },
            .llamada => |l| {
                try self.analizarExpr(l.callee);
                for (l.args) |arg| try self.analizarExpr(arg);
                if (l.callee.* == .identificador) {
                    const nombre = l.callee.identificador;
                    if (self.resolver(nombre)) |sim| {
                        if (sim.clase == .funcion) {
                            if (l.args.len != sim.aridad) {
                                try self.err("la función '{s}' espera {d} argumento(s), se pasaron {d}", .{ nombre, sim.aridad, l.args.len });
                            } else if (sim.func) |f| {
                                for (f.params, l.args) |p, arg| {
                                    if (p.tipo) |ts| {
                                        const pt = nombreATipo(ts);
                                        const at = self.tipoDeExpr(arg);
                                        if (!compatible(pt, at)) {
                                            try self.err("el argumento '{s}' de '{s}' espera {s} pero recibe {s}", .{ p.nombre, nombre, nombreTipo(pt), nombreTipo(at) });
                                        }
                                    }
                                }
                            }
                        } else if (sim.clase == .tipo and l.args.len != sim.aridad) {
                            try self.err("el tipo '{s}' espera {d} campo(s), se pasaron {d}", .{ nombre, sim.aridad, l.args.len });
                        }
                    }
                }
            },
            .acceso => |ac| try self.analizarExpr(ac.objeto),
            .lista => |elems| {
                for (elems) |el| try self.analizarExpr(el);
            },
            .indice => |ix| {
                try self.analizarExpr(ix.objeto);
                try self.analizarExpr(ix.indice);
            },
            .diccionario => |pares| {
                for (pares) |par| {
                    try self.analizarExpr(par.clave);
                    try self.analizarExpr(par.valor);
                }
            },
        }
    }

    // — Chequeo de tipos (gradual) —

    fn checarCondicion(self: *Analizador, e: *const Expr) Error!void {
        const t = self.tipoDeExpr(e);
        if (t != .desconocido and t != .logico) {
            try self.err("la condición debe ser lógica (verdadero/falso), no {s}", .{nombreTipo(t)});
        }
    }

    fn exigirNumero(self: *Analizador, t: Tipo, ctx: []const u8) Error!void {
        if (t != .desconocido and !esNumero(t)) try self.err("{s} debe ser un número, no {s}", .{ ctx, nombreTipo(t) });
    }

    fn exigirLogico(self: *Analizador, t: Tipo, ctx: []const u8) Error!void {
        if (t != .desconocido and t != .logico) try self.err("{s} debe ser lógico, no {s}", .{ ctx, nombreTipo(t) });
    }

    fn checarUnaria(self: *Analizador, u: Expr.Unaria) Error!void {
        const t = self.tipoDeExpr(u.operando);
        switch (u.op) {
            .menos => try self.exigirNumero(t, "la negación"),
            .no_logico => try self.exigirLogico(t, "'!'"),
            else => {}, // esperar, etc.
        }
    }

    fn checarBinaria(self: *Analizador, b: Expr.Binaria) Error!void {
        const ti = self.tipoDeExpr(b.izq);
        const td = self.tipoDeExpr(b.der);
        switch (b.op) {
            .mas => {
                if (ti != .desconocido and td != .desconocido) {
                    const num = esNumero(ti) and esNumero(td);
                    const txt = ti == .texto and td == .texto;
                    if (!num and !txt) try self.err("'+' no se puede usar entre {s} y {s}", .{ nombreTipo(ti), nombreTipo(td) });
                }
            },
            .menos, .por, .entre, .modulo => {
                try self.exigirNumero(ti, "el operando izquierdo");
                try self.exigirNumero(td, "el operando derecho");
            },
            .menor, .mayor, .menor_igual, .mayor_igual => {
                try self.exigirNumero(ti, "el operando izquierdo de la comparación");
                try self.exigirNumero(td, "el operando derecho de la comparación");
            },
            .y_logico, .o_logico => {
                try self.exigirLogico(ti, "el operando izquierdo");
                try self.exigirLogico(td, "el operando derecho");
            },
            else => {}, // igual / distinto: cualquier tipo
        }
    }

    /// Infiere el tipo de una expresión (sin reportar errores). `desconocido` cuando no
    /// se puede determinar (parte del tipado gradual).
    fn tipoDeExpr(self: *Analizador, e: *const Expr) Tipo {
        return switch (e.*) {
            .literal_entero => .entero,
            .literal_decimal => .decimal,
            .literal_texto => .texto,
            .literal_bool => .logico,
            .literal_nulo => .nulo,
            .identificador => |n| if (self.resolver(n)) |sim| sim.tipo else .desconocido,
            .unaria => |u| switch (u.op) {
                .no_logico => .logico,
                .menos => self.tipoDeExpr(u.operando),
                else => .desconocido,
            },
            .binaria => |b| self.tipoBinaria(b),
            .llamada => |l| self.tipoLlamada(l),
            .lista => .lista,
            .diccionario => .diccionario,
            .acceso, .indice => .desconocido,
        };
    }

    fn tipoBinaria(self: *Analizador, b: Expr.Binaria) Tipo {
        return switch (b.op) {
            .menor, .mayor, .menor_igual, .mayor_igual, .igual, .distinto, .y_logico, .o_logico => .logico,
            .mas => blk: {
                const ti = self.tipoDeExpr(b.izq);
                const td = self.tipoDeExpr(b.der);
                if (ti == .texto or td == .texto) break :blk .texto;
                break :blk tipoNumerico(ti, td);
            },
            .menos, .por, .entre, .modulo => tipoNumerico(self.tipoDeExpr(b.izq), self.tipoDeExpr(b.der)),
            else => .desconocido,
        };
    }

    fn tipoLlamada(self: *Analizador, l: Expr.Llamada) Tipo {
        if (l.callee.* == .identificador) {
            if (self.resolver(l.callee.identificador)) |sim| {
                if (sim.clase == .funcion or sim.clase == .tipo) return sim.tipo;
            }
        }
        return .desconocido;
    }
};

fn tipoNumerico(a: Tipo, b: Tipo) Tipo {
    if (a == .decimal or b == .decimal) return .decimal;
    if (a == .entero and b == .entero) return .entero;
    return .desconocido;
}

// — Pruebas —

const testing = std.testing;

fn diagnosticar(an: *Analizador, fuente: []const u8) ![]Diagnostico {
    const toks = try lexer.tokenizar(testing.allocator, fuente);
    defer testing.allocator.free(toks);
    var p = parser.Parser.init(testing.allocator, toks);
    defer p.deinit();
    const programa = try p.parsePrograma();
    return an.analizar(programa);
}

fn esperarLimpio(fuente: []const u8) !void {
    var an = Analizador.init(testing.allocator);
    defer an.deinit();
    const diags = try diagnosticar(&an, fuente);
    if (diags.len != 0) std.debug.print("diag inesperado: {s}\n", .{diags[0].mensaje});
    try testing.expectEqual(@as(usize, 0), diags.len);
}

fn esperarProblema(fuente: []const u8, subcadena: []const u8) !void {
    var an = Analizador.init(testing.allocator);
    defer an.deinit();
    const diags = try diagnosticar(&an, fuente);
    var encontrado = false;
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.mensaje, subcadena) != null) encontrado = true;
    }
    try testing.expect(encontrado);
}

test "programa válido no produce diagnósticos" {
    const src =
        \\funcion factorial(n: entero) -> entero
        \\    si n <= 1
        \\        retornar 1
        \\    sino
        \\        retornar n * factorial(n - 1)
        \\    fin
        \\fin
        \\funcion principal()
        \\    imprimir(factorial(5))
        \\fin
    ;
    try esperarLimpio(src);
}

test "detecta nombre no definido" {
    try esperarProblema("imprimir(desconocido)", "no definido");
}

test "detecta aridad incorrecta de función" {
    const src =
        \\funcion sumar(a: entero, b: entero) -> entero
        \\    retornar a + b
        \\fin
        \\funcion principal()
        \\    imprimir(sumar(1))
        \\fin
    ;
    try esperarProblema(src, "espera 2 argumento");
}

test "detecta aridad incorrecta de constructor" {
    const src =
        \\estructura Punto
        \\    x: entero
        \\    y: entero
        \\fin
        \\funcion principal()
        \\    p = Punto(1)
        \\fin
    ;
    try esperarProblema(src, "espera 2 campo");
}

test "detecta retornar fuera de función" {
    try esperarProblema("retornar 5", "fuera de una función");
}

test "detecta romper fuera de bucle" {
    try esperarProblema("romper", "fuera de un bucle");
}

test "detecta reasignación de constante" {
    const src =
        \\fijo x = 1
        \\x = 2
    ;
    try esperarProblema(src, "reasignar la constante");
}

test "detecta redefinición de función" {
    const src =
        \\funcion f()
        \\    retornar 1
        \\fin
        \\funcion f()
        \\    retornar 2
        \\fin
    ;
    try esperarProblema(src, "redefinición");
}

test "los campos de un modelo son visibles en sus métodos" {
    const src =
        \\modelo Caja
        \\    valor: entero
        \\    funcion doble() -> entero
        \\        retornar valor * 2
        \\    fin
        \\fin
    ;
    try esperarLimpio(src);
}

test "tipos: asignar texto a una variable entero" {
    try esperarProblema("edad: entero = \"hola\"", "es entero");
}

test "tipos: argumento de tipo incorrecto" {
    const src =
        \\funcion saludar(nombre: texto)
        \\    imprimir(nombre)
        \\fin
        \\funcion principal()
        \\    saludar(42)
        \\fin
    ;
    try esperarProblema(src, "espera texto");
}

test "tipos: retorno de tipo incorrecto" {
    const src =
        \\funcion edad() -> entero
        \\    retornar "viejo"
        \\fin
    ;
    try esperarProblema(src, "devolver entero");
}

test "tipos: condición que no es lógica" {
    const src =
        \\si 5
        \\    imprimir("x")
        \\fin
    ;
    try esperarProblema(src, "condición debe ser lógica");
}

test "tipos: aritmética sobre texto" {
    try esperarProblema("fijo x = \"a\" - 1", "número");
}

test "tipos: programa anotado válido no da falsos positivos" {
    const src =
        \\funcion doble(n: entero) -> entero
        \\    retornar n * 2
        \\fin
        \\funcion principal()
        \\    x: entero = 5
        \\    imprimir(doble(x))
        \\fin
    ;
    try esperarLimpio(src);
}
