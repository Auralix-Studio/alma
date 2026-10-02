//! parser.zig — Analizador sintáctico (Parser) del lenguaje Alma.
//! Contrato: docs/especificacion/02-gramatica.md
//!
//! Recursivo-descendente con precedencia por niveles para expresiones. Construye el
//! AST (ast.zig) en una arena propia. Modelo híbrido: bloques por indentación
//! (`sangria`/`desangria`) cerrados con `fin`.

const std = @import("std");
const lexer = @import("../lexico/lexer.zig");
const tk = @import("../lexico/token.zig");
const ast = @import("ast.zig");

const Token = tk.Token;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const ErrorParser = error{ ErrorSintaxis, OutOfMemory };

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,
    diag: ?Diagnostico = null,

    pub const Diagnostico = struct { mensaje: []const u8, linea: usize, columna: usize };

    pub fn init(child: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .tokens = tokens, .arena = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn a(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    // — Navegación de tokens —

    fn actual(self: *Parser) Token {
        return self.mirar(0);
    }

    fn mirar(self: *Parser, offset: usize) Token {
        const i = self.pos + offset;
        if (i >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[i];
    }

    fn avanzar(self: *Parser) Token {
        const t = self.actual();
        if (self.pos < self.tokens.len - 1) self.pos += 1;
        return t;
    }

    fn verificar(self: *Parser, tipo: tk.TipoToken) bool {
        return self.actual().tipo == tipo;
    }

    fn consumir(self: *Parser, tipo: tk.TipoToken) ErrorParser!Token {
        if (self.verificar(tipo)) return self.avanzar();
        return self.fallar("se esperaba {s} pero se encontró {s}", .{ @tagName(tipo), @tagName(self.actual().tipo) });
    }

    fn consumirNuevaLinea(self: *Parser) ErrorParser!void {
        if (self.verificar(.fin_de_archivo)) return;
        _ = try self.consumir(.nueva_linea);
    }

    fn fallar(self: *Parser, comptime fmt: []const u8, args: anytype) ErrorParser {
        const t = self.actual();
        self.diag = .{
            .mensaje = std.fmt.allocPrint(self.a(), fmt, args) catch "error de sintaxis (sin memoria)",
            .linea = t.linea,
            .columna = t.columna,
        };
        return error.ErrorSintaxis;
    }

    fn nuevoExpr(self: *Parser, e: Expr) ErrorParser!*Expr {
        const p = try self.a().create(Expr);
        p.* = e;
        return p;
    }

    // — Programa y bloques —

    pub fn parsePrograma(self: *Parser) ErrorParser![]Stmt {
        var lista: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.verificar(.fin_de_archivo)) {
            if (self.verificar(.nueva_linea)) {
                _ = self.avanzar();
                continue;
            }
            const s = try self.parseStmt();
            try lista.append(self.a(), s);
        }
        return lista.toOwnedSlice(self.a());
    }

    fn parseBloque(self: *Parser) ErrorParser![]Stmt {
        _ = try self.consumir(.sangria);
        var lista: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.verificar(.desangria) and !self.verificar(.fin_de_archivo)) {
            if (self.verificar(.nueva_linea)) {
                _ = self.avanzar();
                continue;
            }
            const s = try self.parseStmt();
            try lista.append(self.a(), s);
        }
        _ = try self.consumir(.desangria);
        return lista.toOwnedSlice(self.a());
    }

    // — Sentencias —

    fn posActual(self: *Parser) ast.Pos {
        const t = self.actual();
        return .{ .linea = t.linea, .columna = t.columna };
    }

    fn parseStmt(self: *Parser) ErrorParser!Stmt {
        const pos = self.posActual();
        const dato = try self.parseStmtInterno();
        return .{ .pos = pos, .dato = dato };
    }

    fn parseStmtInterno(self: *Parser) ErrorParser!Stmt.Dato {
        switch (self.actual().tipo) {
            .kw_fijo => return self.parseDeclFija(),
            .kw_importar => return self.parseImportar(),
            .kw_exportar => return self.parseExportar(),
            .kw_si => return self.parseSi(),
            .kw_mientras => return self.parseMientras(),
            .kw_para => return self.parsePara(),
            .kw_funcion => return .{ .funcion = try self.parseFuncion(false, false) },
            .kw_asincrona => {
                _ = self.avanzar();
                return .{ .funcion = try self.parseFuncion(false, true) };
            },
            .kw_estructura => return self.parseEstructura(false),
            .kw_modelo => return self.parseModelo(false),
            .kw_intentar => return self.parseIntentar(),
            .kw_lanzar => return self.parseLanzar(),
            .kw_hilo => return self.parseHilo(),
            .kw_retornar => return self.parseRetornar(),
            .kw_romper => {
                _ = self.avanzar();
                try self.consumirNuevaLinea();
                return .romper;
            },
            .kw_continuar => {
                _ = self.avanzar();
                try self.consumirNuevaLinea();
                return .continuar;
            },
            else => return self.parseExprOAsignacion(),
        }
    }

    fn parseExprOAsignacion(self: *Parser) ErrorParser!Stmt.Dato {
        const e = try self.parseExpr();
        if (self.verificar(.asignar)) {
            _ = self.avanzar();
            const valor = try self.parseExpr();
            try self.consumirNuevaLinea();
            return .{ .asignacion = .{ .objetivo = e, .valor = valor } };
        }
        if (self.verificar(.dos_puntos)) {
            const nombre = switch (e.*) {
                .identificador => |n| n,
                else => return self.fallar("solo un identificador puede llevar anotación de tipo antes de '='", .{}),
            };
            _ = self.avanzar();
            const tipo = try self.consumir(.identificador);
            _ = try self.consumir(.asignar);
            const valor = try self.parseExpr();
            try self.consumirNuevaLinea();
            return .{ .declaracion = .{ .nombre = nombre, .tipo = tipo.lexema, .fijo = false, .valor = valor } };
        }
        try self.consumirNuevaLinea();
        return .{ .expresion = e };
    }

    fn parseDeclFija(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_fijo);
        const nombre = try self.consumir(.identificador);
        var tipo: ?[]const u8 = null;
        if (self.verificar(.dos_puntos)) {
            _ = self.avanzar();
            tipo = (try self.consumir(.identificador)).lexema;
        }
        _ = try self.consumir(.asignar);
        const valor = try self.parseExpr();
        try self.consumirNuevaLinea();
        return .{ .declaracion = .{ .nombre = nombre.lexema, .tipo = tipo, .fijo = true, .valor = valor } };
    }

    fn parseImportar(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_importar);
        const que = try self.consumir(.identificador);
        var desde: ?[]const u8 = null;
        if (self.verificar(.kw_desde)) {
            _ = self.avanzar();
            desde = (try self.consumir(.lit_texto)).lexema;
        }
        try self.consumirNuevaLinea();
        return .{ .importar = .{ .que = que.lexema, .desde = desde } };
    }

    fn parseExportar(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_exportar);
        switch (self.actual().tipo) {
            .kw_funcion => return .{ .funcion = try self.parseFuncion(true, false) },
            .kw_asincrona => {
                _ = self.avanzar();
                return .{ .funcion = try self.parseFuncion(true, true) };
            },
            .kw_estructura => return self.parseEstructura(true),
            .kw_modelo => return self.parseModelo(true),
            else => return self.fallar("'exportar' debe preceder a funcion/estructura/modelo, no {s}", .{@tagName(self.actual().tipo)}),
        }
    }

    fn parseIntentar(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_intentar);
        try self.consumirNuevaLinea();
        const cuerpo = try self.parseBloque();
        _ = try self.consumir(.kw_capturar);
        _ = try self.consumir(.paren_izq);
        const variable = try self.consumir(.identificador);
        _ = try self.consumir(.paren_der);
        try self.consumirNuevaLinea();
        const captura = try self.parseBloque();
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .intentar = .{ .cuerpo = cuerpo, .variable = variable.lexema, .captura = captura } };
    }

    fn parseLanzar(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_lanzar);
        const e = try self.parseExpr();
        try self.consumirNuevaLinea();
        return .{ .lanzar = e };
    }

    fn parseHilo(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_hilo);
        const e = try self.parseExpr();
        try self.consumirNuevaLinea();
        return .{ .hilo = e };
    }

    fn parseRetornar(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_retornar);
        var valor: ?*Expr = null;
        if (!self.verificar(.nueva_linea) and !self.verificar(.fin_de_archivo)) {
            valor = try self.parseExpr();
        }
        try self.consumirNuevaLinea();
        return .{ .retornar = valor };
    }

    fn parseSi(self: *Parser) ErrorParser!Stmt.Dato {
        var ramas: std.ArrayListUnmanaged(ast.RamaSi) = .empty;
        _ = try self.consumir(.kw_si);
        {
            const cond = try self.parseExpr();
            try self.consumirNuevaLinea();
            const cuerpo = try self.parseBloque();
            try ramas.append(self.a(), .{ .condicion = cond, .cuerpo = cuerpo });
        }
        while (self.verificar(.kw_sino) and self.mirar(1).tipo == .kw_si) {
            _ = self.avanzar(); // sino
            _ = self.avanzar(); // si
            const cond = try self.parseExpr();
            try self.consumirNuevaLinea();
            const cuerpo = try self.parseBloque();
            try ramas.append(self.a(), .{ .condicion = cond, .cuerpo = cuerpo });
        }
        var sino_cuerpo: ?[]Stmt = null;
        if (self.verificar(.kw_sino)) {
            _ = self.avanzar();
            try self.consumirNuevaLinea();
            sino_cuerpo = try self.parseBloque();
        }
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .si = .{ .ramas = try ramas.toOwnedSlice(self.a()), .sino = sino_cuerpo } };
    }

    fn parseMientras(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_mientras);
        const cond = try self.parseExpr();
        try self.consumirNuevaLinea();
        const cuerpo = try self.parseBloque();
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .mientras = .{ .condicion = cond, .cuerpo = cuerpo } };
    }

    fn parsePara(self: *Parser) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_para);
        const variable = try self.consumir(.identificador);
        _ = try self.consumir(.kw_en);
        const iterable = try self.parseExpr();
        try self.consumirNuevaLinea();
        const cuerpo = try self.parseBloque();
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .para = .{ .variable = variable.lexema, .iterable = iterable, .cuerpo = cuerpo } };
    }

    fn parseFuncion(self: *Parser, exportar: bool, asincrona: bool) ErrorParser!Stmt.Funcion {
        _ = try self.consumir(.kw_funcion);
        const nombre = try self.consumir(.identificador);
        _ = try self.consumir(.paren_izq);
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        if (!self.verificar(.paren_der)) {
            while (true) {
                const pn = try self.consumir(.identificador);
                var pt: ?[]const u8 = null;
                if (self.verificar(.dos_puntos)) {
                    _ = self.avanzar();
                    pt = (try self.consumir(.identificador)).lexema;
                }
                try params.append(self.a(), .{ .nombre = pn.lexema, .tipo = pt });
                if (self.verificar(.coma)) {
                    _ = self.avanzar();
                    continue;
                }
                break;
            }
        }
        _ = try self.consumir(.paren_der);
        var retorno: ?[]const u8 = null;
        if (self.verificar(.flecha)) {
            _ = self.avanzar();
            retorno = (try self.consumir(.identificador)).lexema;
        }
        try self.consumirNuevaLinea();
        const cuerpo = try self.parseBloque();
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return Stmt.Funcion{
            .nombre = nombre.lexema,
            .params = try params.toOwnedSlice(self.a()),
            .retorno = retorno,
            .cuerpo = cuerpo,
            .exportar = exportar,
            .asincrona = asincrona,
        };
    }

    fn parseEstructura(self: *Parser, exportar: bool) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_estructura);
        const nombre = try self.consumir(.identificador);
        try self.consumirNuevaLinea();
        _ = try self.consumir(.sangria);
        var campos: std.ArrayListUnmanaged(ast.Campo) = .empty;
        while (!self.verificar(.desangria) and !self.verificar(.fin_de_archivo)) {
            if (self.verificar(.nueva_linea)) {
                _ = self.avanzar();
                continue;
            }
            const cn = try self.consumir(.identificador);
            _ = try self.consumir(.dos_puntos);
            const ct = try self.consumir(.identificador);
            try self.consumirNuevaLinea();
            try campos.append(self.a(), .{ .nombre = cn.lexema, .tipo = ct.lexema });
        }
        _ = try self.consumir(.desangria);
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .estructura = .{ .nombre = nombre.lexema, .campos = try campos.toOwnedSlice(self.a()), .exportar = exportar } };
    }

    fn parseModelo(self: *Parser, exportar: bool) ErrorParser!Stmt.Dato {
        _ = try self.consumir(.kw_modelo);
        const nombre = try self.consumir(.identificador);
        try self.consumirNuevaLinea();
        _ = try self.consumir(.sangria);
        var campos: std.ArrayListUnmanaged(ast.Campo) = .empty;
        var metodos: std.ArrayListUnmanaged(Stmt.Funcion) = .empty;
        while (!self.verificar(.desangria) and !self.verificar(.fin_de_archivo)) {
            if (self.verificar(.nueva_linea)) {
                _ = self.avanzar();
                continue;
            }
            if (self.verificar(.kw_funcion)) {
                const f = try self.parseFuncion(false, false);
                try metodos.append(self.a(), f);
            } else {
                const cn = try self.consumir(.identificador);
                _ = try self.consumir(.dos_puntos);
                const ct = try self.consumir(.identificador);
                try self.consumirNuevaLinea();
                try campos.append(self.a(), .{ .nombre = cn.lexema, .tipo = ct.lexema });
            }
        }
        _ = try self.consumir(.desangria);
        _ = try self.consumir(.kw_fin);
        try self.consumirNuevaLinea();
        return .{ .modelo = .{
            .nombre = nombre.lexema,
            .campos = try campos.toOwnedSlice(self.a()),
            .metodos = try metodos.toOwnedSlice(self.a()),
            .exportar = exportar,
        } };
    }

    // — Expresiones (precedencia de menor a mayor) —

    fn parseExpr(self: *Parser) ErrorParser!*Expr {
        return self.parseDisy();
    }

    fn parseDisy(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseConj();
        while (self.verificar(.o_logico)) {
            const op = self.avanzar().tipo;
            const der = try self.parseConj();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseConj(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseIgualdad();
        while (self.verificar(.y_logico)) {
            const op = self.avanzar().tipo;
            const der = try self.parseIgualdad();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseIgualdad(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseComparacion();
        while (self.verificar(.igual) or self.verificar(.distinto)) {
            const op = self.avanzar().tipo;
            const der = try self.parseComparacion();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseComparacion(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseTermino();
        while (self.verificar(.menor) or self.verificar(.mayor) or
            self.verificar(.menor_igual) or self.verificar(.mayor_igual))
        {
            const op = self.avanzar().tipo;
            const der = try self.parseTermino();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseTermino(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseFactor();
        while (self.verificar(.mas) or self.verificar(.menos)) {
            const op = self.avanzar().tipo;
            const der = try self.parseFactor();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseFactor(self: *Parser) ErrorParser!*Expr {
        var izq = try self.parseUnario();
        while (self.verificar(.por) or self.verificar(.entre) or self.verificar(.modulo)) {
            const op = self.avanzar().tipo;
            const der = try self.parseUnario();
            izq = try self.nuevoExpr(.{ .binaria = .{ .op = op, .izq = izq, .der = der } });
        }
        return izq;
    }

    fn parseUnario(self: *Parser) ErrorParser!*Expr {
        if (self.verificar(.no_logico) or self.verificar(.menos) or self.verificar(.kw_esperar)) {
            const op = self.avanzar().tipo;
            const operando = try self.parseUnario();
            return self.nuevoExpr(.{ .unaria = .{ .op = op, .operando = operando } });
        }
        return self.parsePostfijo();
    }

    fn parsePostfijo(self: *Parser) ErrorParser!*Expr {
        var e = try self.parsePrimario();
        while (true) {
            if (self.verificar(.paren_izq)) {
                e = try self.finLlamada(e);
            } else if (self.verificar(.punto)) {
                _ = self.avanzar();
                const campo = try self.consumir(.identificador);
                e = try self.nuevoExpr(.{ .acceso = .{ .objeto = e, .campo = campo.lexema } });
            } else if (self.verificar(.corchete_izq)) {
                _ = self.avanzar();
                const idx = try self.parseExpr();
                _ = try self.consumir(.corchete_der);
                e = try self.nuevoExpr(.{ .indice = .{ .objeto = e, .indice = idx } });
            } else break;
        }
        return e;
    }

    fn finLlamada(self: *Parser, callee: *Expr) ErrorParser!*Expr {
        _ = try self.consumir(.paren_izq);
        var args: std.ArrayListUnmanaged(*Expr) = .empty;
        if (!self.verificar(.paren_der)) {
            while (true) {
                const arg = try self.parseExpr();
                try args.append(self.a(), arg);
                if (self.verificar(.coma)) {
                    _ = self.avanzar();
                    continue;
                }
                break;
            }
        }
        _ = try self.consumir(.paren_der);
        return self.nuevoExpr(.{ .llamada = .{ .callee = callee, .args = try args.toOwnedSlice(self.a()) } });
    }

    fn parsePrimario(self: *Parser) ErrorParser!*Expr {
        const t = self.actual();
        switch (t.tipo) {
            .lit_entero => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .literal_entero = t.lexema });
            },
            .lit_decimal => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .literal_decimal = t.lexema });
            },
            .lit_texto => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .literal_texto = t.lexema });
            },
            .lit_verdadero => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .literal_bool = true });
            },
            .lit_falso => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .literal_bool = false });
            },
            .lit_nulo => {
                _ = self.avanzar();
                return self.nuevoExpr(.literal_nulo);
            },
            .identificador => {
                _ = self.avanzar();
                return self.nuevoExpr(.{ .identificador = t.lexema });
            },
            .paren_izq => {
                _ = self.avanzar();
                const e = try self.parseExpr();
                _ = try self.consumir(.paren_der);
                return e;
            },
            .corchete_izq => return self.parseListaLiteral(),
            .llave_izq => return self.parseDiccLiteral(),
            else => return self.fallar("expresión inesperada: {s}", .{@tagName(t.tipo)}),
        }
    }

    fn parseListaLiteral(self: *Parser) ErrorParser!*Expr {
        _ = try self.consumir(.corchete_izq);
        var elems: std.ArrayListUnmanaged(*Expr) = .empty;
        if (!self.verificar(.corchete_der)) {
            while (true) {
                const el = try self.parseExpr();
                try elems.append(self.a(), el);
                if (self.verificar(.coma)) {
                    _ = self.avanzar();
                    continue;
                }
                break;
            }
        }
        _ = try self.consumir(.corchete_der);
        return self.nuevoExpr(.{ .lista = try elems.toOwnedSlice(self.a()) });
    }

    fn parseDiccLiteral(self: *Parser) ErrorParser!*Expr {
        _ = try self.consumir(.llave_izq);
        var pares: std.ArrayListUnmanaged(ast.Expr.ParClaveValor) = .empty;
        if (!self.verificar(.llave_der)) {
            while (true) {
                const clave = try self.parseExpr();
                _ = try self.consumir(.dos_puntos);
                const valor = try self.parseExpr();
                try pares.append(self.a(), .{ .clave = clave, .valor = valor });
                if (self.verificar(.coma)) {
                    _ = self.avanzar();
                    continue;
                }
                break;
            }
        }
        _ = try self.consumir(.llave_der);
        return self.nuevoExpr(.{ .diccionario = try pares.toOwnedSlice(self.a()) });
    }
};

// — Pruebas —

fn esperarAST(fuente: []const u8, esperado: []const u8) !void {
    const toks = try lexer.tokenizar(std.testing.allocator, fuente);
    defer std.testing.allocator.free(toks);
    var p = Parser.init(std.testing.allocator, toks);
    defer p.deinit();
    const programa = p.parsePrograma() catch |err| {
        if (p.diag) |d| std.debug.print("diag: {s} (L{d}:C{d})\n", .{ d.mensaje, d.linea, d.columna });
        return err;
    };
    const texto = try ast.escribirPrograma(std.testing.allocator, programa);
    defer std.testing.allocator.free(texto);
    try std.testing.expectEqualStrings(esperado, texto);
}

test "precedencia aritmética" {
    try esperarAST("x = 1 + 2 * 3", "(programa (asignar x (mas 1 (por 2 3))))");
}

test "comparación y lógico" {
    try esperarAST("b = a > 3 && c", "(programa (asignar b (y_logico (mayor a 3) c)))");
}

test "declaración con tipo y constante" {
    try esperarAST("edad: entero = 22", "(programa (declarar edad :entero 22))");
    try esperarAST("fijo version = \"1.0.0\"", "(programa (fijo version \"1.0.0\"))");
}

test "función con retorno" {
    const src =
        \\funcion sumar(a: entero, b: entero) -> entero
        \\    retornar a + b
        \\fin
    ;
    try esperarAST(src, "(programa (funcion sumar (params a:entero b:entero) ->entero (bloque (retornar (mas a b)))))");
}

test "si / sino si / sino" {
    const src =
        \\si x
        \\    y = 1
        \\sino si z
        \\    y = 2
        \\sino
        \\    y = 3
        \\fin
    ;
    try esperarAST(src, "(programa (si (rama x (bloque (asignar y 1))) (rama z (bloque (asignar y 2))) (sino (bloque (asignar y 3)))))");
}

test "estructura Vector3D" {
    const src =
        \\estructura Vector3D
        \\    x: decimal
        \\    y: decimal
        \\    z: decimal
        \\fin
    ;
    try esperarAST(src, "(programa (estructura Vector3D (campo x :decimal) (campo y :decimal) (campo z :decimal)))");
}

test "modelo con método" {
    const src =
        \\modelo Servidor
        \\    host: texto
        \\    funcion iniciar(h: texto)
        \\        host = h
        \\    fin
        \\fin
    ;
    try esperarAST(src, "(programa (modelo Servidor (campo host :texto) (funcion iniciar (params h:texto) (bloque (asignar host h)))))");
}

test "llamada y acceso a miembro" {
    try esperarAST("respuesta.json()", "(programa (expr (llamar (acceso respuesta json))))");
}

test "importar con desde" {
    try esperarAST("importar calcular_area desde \"modulos/matematicas\"", "(programa (importar calcular_area desde \"modulos/matematicas\"))");
}

test "bucle para" {
    const src =
        \\para tec en lista
        \\    imprimir(tec)
        \\fin
    ;
    try esperarAST(src, "(programa (para tec en lista (bloque (expr (llamar imprimir tec)))))");
}

test "literal de lista e indexación" {
    try esperarAST("x = [1, 2, 3]", "(programa (asignar x (lista 1 2 3)))");
    try esperarAST("y = datos[0]", "(programa (asignar y (indice datos 0)))");
    try esperarAST("lista[i] = 9", "(programa (asignar (indice lista i) 9))");
}

test "literal de diccionario" {
    try esperarAST("d = {\"a\": 1, \"b\": 2}", "(programa (asignar d (dicc (par \"a\" 1) (par \"b\" 2))))");
    try esperarAST("e = {}", "(programa (asignar e (dicc)))");
}

test "intentar / capturar y lanzar" {
    const src =
        \\intentar
        \\    x = 1
        \\capturar (error)
        \\    imprimir(error)
        \\fin
    ;
    try esperarAST(src, "(programa (intentar (bloque (asignar x 1)) (capturar error (bloque (expr (llamar imprimir error))))))");
    try esperarAST("lanzar error(\"malo\")", "(programa (lanzar (llamar error \"malo\")))");
}

test "esperar e hilo" {
    try esperarAST("r = esperar tarea()", "(programa (asignar r (kw_esperar (llamar tarea))))");
    try esperarAST("hilo trabajar()", "(programa (hilo (llamar trabajar)))");
}
