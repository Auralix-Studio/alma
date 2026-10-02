//! lexer.zig — Analizador léxico (Lexer) del lenguaje Alma.
//!
//! Convierte texto fuente `.alma` (UTF-8) en un flujo de tokens, aplicando la
//! regla del *off-side* (indentación significativa) con terminador `fin`.
//! Contrato: docs/especificacion/01-lexico-y-tokens.md
//!
//! Es un lexer "pull": cada llamada a `next()` devuelve un token. Los tokens de
//! estructura de línea (`nueva_linea`, `sangria`, `desangria`) se sintetizan a
//! partir de la indentación usando una pila de niveles.

const std = @import("std");
const tk = @import("token.zig");
const Token = tk.Token;
const TipoToken = tk.TipoToken;

/// Profundidad máxima de anidamiento de bloques (niveles de indentación).
pub const MAX_ANIDAMIENTO = 256;

const ResultadoIndent = enum { linea_vacia, indent, dedent, igual, fin };

pub const Lexer = struct {
    fuente: []const u8,
    pos: usize = 0,
    linea: usize = 1,
    inicio_linea: usize = 0,

    // Pila de indentación (en columnas de espacios). niveles[0] siempre es 0.
    niveles: [MAX_ANIDAMIENTO]usize = undefined,
    niveles_len: usize = 1,
    dedentes_pendientes: usize = 0,

    // Estado de la línea lógica en curso.
    al_inicio: bool = true,
    linea_con_contenido: bool = false,

    // Anidamiento de () [] {} para la unión implícita de líneas.
    profundidad_grupo: usize = 0,

    // Diagnóstico best-effort (tabs en indentación / indentación inconsistente).
    error_indentacion: bool = false,

    pub fn init(fuente: []const u8) Lexer {
        var l = Lexer{ .fuente = fuente };
        l.niveles[0] = 0;
        return l;
    }

    /// Devuelve el siguiente token. Al llegar al final produce `fin_de_archivo`
    /// (precedido por las `desangria` necesarias para cerrar la pila).
    pub fn next(self: *Lexer) Token {
        while (true) {
            // 1) DESANGRÍAS pendientes acumuladas por un dedent múltiple.
            if (self.dedentes_pendientes > 0) {
                self.dedentes_pendientes -= 1;
                return self.estructural(.desangria);
            }

            // 2) Indentación al inicio de una línea lógica (salvo dentro de grupos).
            if (self.al_inicio) {
                if (self.profundidad_grupo == 0) {
                    switch (self.procesarIndentacion()) {
                        .linea_vacia => continue,
                        .indent => return self.estructural(.sangria),
                        .dedent => continue,
                        .igual => {},
                        .fin => self.al_inicio = false,
                    }
                } else {
                    self.al_inicio = false;
                }
            }

            // 3) Espacios y comentarios dentro de la línea.
            self.saltarEspaciosYComentarios();

            // 4) Fin de archivo.
            if (self.finDeFuente()) {
                if (self.linea_con_contenido and self.profundidad_grupo == 0) {
                    self.linea_con_contenido = false;
                    return self.estructural(.nueva_linea);
                }
                if (self.niveles_len > 1) {
                    self.niveles_len -= 1;
                    return self.estructural(.desangria);
                }
                return self.estructural(.fin_de_archivo);
            }

            // 5) Fin de línea.
            const c = self.fuente[self.pos];
            if (c == '\n' or c == '\r') {
                self.consumirFinDeLinea();
                self.al_inicio = true;
                if (self.profundidad_grupo == 0 and self.linea_con_contenido) {
                    self.linea_con_contenido = false;
                    return self.estructural(.nueva_linea);
                }
                continue;
            }

            // 6) Token real.
            return self.escanearToken();
        }
    }

    fn procesarIndentacion(self: *Lexer) ResultadoIndent {
        var col: usize = 0;
        while (!self.finDeFuente()) {
            const c = self.fuente[self.pos];
            if (c == ' ') {
                col += 1;
                self.pos += 1;
            } else if (c == '\t') {
                self.error_indentacion = true; // en la indentación solo se admiten espacios
                col += 1;
                self.pos += 1;
            } else break;
        }

        if (self.finDeFuente()) return .fin;

        const c = self.fuente[self.pos];
        // Línea en blanco: no afecta la indentación.
        if (c == '\n' or c == '\r') {
            self.consumirFinDeLinea();
            return .linea_vacia;
        }
        // Línea solo-comentario (`// …`, `/// …`, `//! …`): tampoco afecta.
        if (c == '/' and self.siguienteEs(1, '/')) {
            self.saltarHastaFinDeLinea();
            if (!self.finDeFuente()) self.consumirFinDeLinea();
            return .linea_vacia;
        }

        // Línea con contenido: comparar contra la cima de la pila.
        self.al_inicio = false;
        const cima = self.niveles[self.niveles_len - 1];
        if (col > cima) {
            if (self.niveles_len < MAX_ANIDAMIENTO) {
                self.niveles[self.niveles_len] = col;
                self.niveles_len += 1;
            }
            return .indent;
        } else if (col < cima) {
            var cuenta: usize = 0;
            while (self.niveles_len > 1 and self.niveles[self.niveles_len - 1] > col) {
                self.niveles_len -= 1;
                cuenta += 1;
            }
            if (self.niveles[self.niveles_len - 1] != col) {
                // Indentación inconsistente: recuperación best-effort alineando a `col`.
                self.error_indentacion = true;
                self.niveles[self.niveles_len - 1] = col;
            }
            self.dedentes_pendientes = cuenta;
            return .dedent;
        }
        return .igual;
    }

    fn escanearToken(self: *Lexer) Token {
        self.linea_con_contenido = true;
        const inicio = self.pos;
        const col = self.columnaActual();
        const c = self.fuente[self.pos];

        if (esInicioIdent(c)) {
            self.pos += 1;
            while (!self.finDeFuente() and esParteIdent(self.fuente[self.pos])) self.pos += 1;
            const lex = self.fuente[inicio..self.pos];
            const tipo = tk.palabraClave(lex) orelse TipoToken.identificador;
            return .{ .tipo = tipo, .lexema = lex, .linea = self.linea, .columna = col };
        }
        if (esDigito(c)) return self.escanearNumero(inicio, col);
        if (c == '"') return self.escanearTexto(inicio, col);
        return self.escanearSimbolo(inicio, col);
    }

    fn escanearNumero(self: *Lexer, inicio: usize, col: usize) Token {
        while (!self.finDeFuente() and esDigitoOsub(self.fuente[self.pos])) self.pos += 1;
        var es_decimal = false;

        // Parte fraccionaria: `.` seguido de dígito.
        if (!self.finDeFuente() and self.fuente[self.pos] == '.') {
            if (self.ojear(1)) |n| {
                if (esDigito(n)) {
                    es_decimal = true;
                    self.pos += 1;
                    while (!self.finDeFuente() and esDigitoOsub(self.fuente[self.pos])) self.pos += 1;
                }
            }
        }

        // Exponente: `e`/`E` con signo opcional.
        if (!self.finDeFuente() and (self.fuente[self.pos] == 'e' or self.fuente[self.pos] == 'E')) {
            if (self.ojear(1)) |n1| {
                if (esDigito(n1)) {
                    es_decimal = true;
                    self.pos += 1;
                    while (!self.finDeFuente() and esDigitoOsub(self.fuente[self.pos])) self.pos += 1;
                } else if (n1 == '+' or n1 == '-') {
                    if (self.ojear(2)) |n2| {
                        if (esDigito(n2)) {
                            es_decimal = true;
                            self.pos += 2;
                            while (!self.finDeFuente() and esDigitoOsub(self.fuente[self.pos])) self.pos += 1;
                        }
                    }
                }
            }
        }

        const lex = self.fuente[inicio..self.pos];
        return .{
            .tipo = if (es_decimal) TipoToken.lit_decimal else TipoToken.lit_entero,
            .lexema = lex,
            .linea = self.linea,
            .columna = col,
        };
    }

    fn escanearTexto(self: *Lexer, inicio: usize, col: usize) Token {
        self.pos += 1; // comilla de apertura
        var cerrado = false;
        while (!self.finDeFuente()) {
            const c = self.fuente[self.pos];
            if (c == '\\') {
                self.pos += 1;
                if (!self.finDeFuente()) self.pos += 1; // consume el carácter escapado
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                cerrado = true;
                break;
            }
            if (c == '\n' or c == '\r') break; // texto sin cerrar en la línea
            self.pos += 1;
        }
        const lex = self.fuente[inicio..self.pos];
        return .{
            .tipo = if (cerrado) TipoToken.lit_texto else TipoToken.invalido,
            .lexema = lex,
            .linea = self.linea,
            .columna = col,
        };
    }

    fn escanearSimbolo(self: *Lexer, inicio: usize, col: usize) Token {
        const c = self.fuente[self.pos];
        self.pos += 1;
        var tipo: TipoToken = .invalido;
        switch (c) {
            '+' => tipo = if (self.coincide('=')) .mas_asignar else .mas,
            '-' => {
                if (self.coincide('>')) {
                    tipo = .flecha;
                } else if (self.coincide('=')) {
                    tipo = .menos_asignar;
                } else {
                    tipo = .menos;
                }
            },
            '*' => tipo = if (self.coincide('=')) .por_asignar else .por,
            '/' => tipo = if (self.coincide('=')) .entre_asignar else .entre,
            '%' => tipo = .modulo,
            '=' => tipo = if (self.coincide('=')) .igual else .asignar,
            '!' => tipo = if (self.coincide('=')) .distinto else .no_logico,
            '&' => tipo = if (self.coincide('&')) .y_logico else .invalido,
            '|' => tipo = if (self.coincide('|')) .o_logico else .invalido,
            '<' => tipo = if (self.coincide('=')) .menor_igual else .menor,
            '>' => tipo = if (self.coincide('=')) .mayor_igual else .mayor,
            '.' => tipo = .punto,
            '(' => {
                tipo = .paren_izq;
                self.profundidad_grupo += 1;
            },
            ')' => {
                tipo = .paren_der;
                if (self.profundidad_grupo > 0) self.profundidad_grupo -= 1;
            },
            '[' => {
                tipo = .corchete_izq;
                self.profundidad_grupo += 1;
            },
            ']' => {
                tipo = .corchete_der;
                if (self.profundidad_grupo > 0) self.profundidad_grupo -= 1;
            },
            '{' => {
                tipo = .llave_izq;
                self.profundidad_grupo += 1;
            },
            '}' => {
                tipo = .llave_der;
                if (self.profundidad_grupo > 0) self.profundidad_grupo -= 1;
            },
            ',' => tipo = .coma,
            ':' => tipo = .dos_puntos,
            else => tipo = .invalido,
        }
        const lex = self.fuente[inicio..self.pos];
        return .{ .tipo = tipo, .lexema = lex, .linea = self.linea, .columna = col };
    }

    // — Utilidades internas —

    fn coincide(self: *Lexer, esperado: u8) bool {
        if (self.finDeFuente()) return false;
        if (self.fuente[self.pos] != esperado) return false;
        self.pos += 1;
        return true;
    }

    fn saltarEspaciosYComentarios(self: *Lexer) void {
        while (!self.finDeFuente()) {
            const c = self.fuente[self.pos];
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else if (c == '/' and self.siguienteEs(1, '/')) {
                self.saltarHastaFinDeLinea(); // deja el salto de línea para el paso 5
            } else break;
        }
    }

    fn saltarHastaFinDeLinea(self: *Lexer) void {
        while (!self.finDeFuente() and self.fuente[self.pos] != '\n' and self.fuente[self.pos] != '\r') self.pos += 1;
    }

    fn consumirFinDeLinea(self: *Lexer) void {
        if (!self.finDeFuente() and self.fuente[self.pos] == '\r') self.pos += 1;
        if (!self.finDeFuente() and self.fuente[self.pos] == '\n') self.pos += 1;
        self.linea += 1;
        self.inicio_linea = self.pos;
    }

    fn estructural(self: *Lexer, tipo: TipoToken) Token {
        return .{ .tipo = tipo, .lexema = "", .linea = self.linea, .columna = self.columnaActual() };
    }

    fn columnaActual(self: *Lexer) usize {
        return self.pos - self.inicio_linea + 1;
    }

    fn finDeFuente(self: *Lexer) bool {
        return self.pos >= self.fuente.len;
    }

    fn ojear(self: *Lexer, n: usize) ?u8 {
        const i = self.pos + n;
        if (i < self.fuente.len) return self.fuente[i];
        return null;
    }

    fn siguienteEs(self: *Lexer, offset: usize, ch: u8) bool {
        const i = self.pos + offset;
        return i < self.fuente.len and self.fuente[i] == ch;
    }
};

// — Clasificación de caracteres —
// El soporte Unicode es deliberadamente permisivo en v0.1: cualquier byte >= 0x80
// (secuencia UTF-8) se acepta como parte de identificador, habilitando `ñ`/acentos.
// Una categorización Unicode formal llegará más adelante.

fn esDigito(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn esDigitoOsub(c: u8) bool {
    return esDigito(c) or c == '_';
}
fn esAlfa(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn esInicioIdent(c: u8) bool {
    return esAlfa(c) or c >= 0x80;
}
fn esParteIdent(c: u8) bool {
    return esAlfa(c) or esDigito(c) or c >= 0x80;
}

/// Tokeniza toda la fuente y devuelve la lista de tokens (incluye `fin_de_archivo`).
/// El llamador es dueño del slice devuelto y debe liberarlo con `allocator.free`.
pub fn tokenizar(allocator: std.mem.Allocator, fuente: []const u8) ![]Token {
    // Ignora un BOM UTF-8 inicial (lo agregan varios editores).
    const src = if (std.mem.startsWith(u8, fuente, "\xEF\xBB\xBF")) fuente[3..] else fuente;
    var lex = Lexer.init(src);
    var lista: std.ArrayListUnmanaged(Token) = .empty;
    errdefer lista.deinit(allocator);
    while (true) {
        const t = lex.next();
        try lista.append(allocator, t);
        if (t.tipo == .fin_de_archivo) break;
    }
    return lista.toOwnedSlice(allocator);
}

// — Pruebas —

const testing = std.testing;

test {
    // Incluye en el binario de test las pruebas de token.zig.
    _ = @import("token.zig");
}

fn esperarTipos(fuente: []const u8, esperados: []const TipoToken) !void {
    const toks = try tokenizar(testing.allocator, fuente);
    defer testing.allocator.free(toks);
    try testing.expectEqual(esperados.len, toks.len);
    for (esperados, 0..) |esp, i| {
        try testing.expectEqual(esp, toks[i].tipo);
    }
}

test "función simple: flujo completo de tokens" {
    const src =
        \\funcion sumar(a: entero, b: entero) -> entero
        \\    retornar a + b
        \\fin
    ;
    try esperarTipos(src, &.{
        .kw_funcion,    .identificador, .paren_izq,     .identificador,  .dos_puntos,
        .identificador, .coma,          .identificador, .dos_puntos,     .identificador,
        .paren_der,     .flecha,        .identificador, .nueva_linea,    .sangria,
        .kw_retornar,   .identificador, .mas,           .identificador,  .nueva_linea,
        .desangria,     .kw_fin,        .nueva_linea,   .fin_de_archivo,
    });
}

test "indentación anidada: SANGRIA/DESANGRIA balanceados" {
    const src =
        \\si a
        \\    si b
        \\        x = 1
        \\    fin
        \\fin
    ;
    try esperarTipos(src, &.{
        .kw_si,          .identificador, .nueva_linea,
        .sangria,        .kw_si,         .identificador,
        .nueva_linea,    .sangria,       .identificador,
        .asignar,        .lit_entero,    .nueva_linea,
        .desangria,      .kw_fin,        .nueva_linea,
        .desangria,      .kw_fin,        .nueva_linea,
        .fin_de_archivo,
    });
}

test "números enteros y decimales" {
    const src =
        \\x = 19.99
        \\total = 42
    ;
    try esperarTipos(src, &.{
        .identificador,  .asignar, .lit_decimal, .nueva_linea,
        .identificador,  .asignar, .lit_entero,  .nueva_linea,
        .fin_de_archivo,
    });
}

test "texto y concatenación con +" {
    const src = "mensaje = \"hola \" + nombre";
    try esperarTipos(src, &.{
        .identificador,  .asignar, .lit_texto, .mas, .identificador, .nueva_linea,
        .fin_de_archivo,
    });
}

test "identificadores con acentos y ñ" {
    const src = "año = calculó";
    try esperarTipos(src, &.{
        .identificador,  .asignar, .identificador, .nueva_linea,
        .fin_de_archivo,
    });
}

test "operadores y comparaciones" {
    const src =
        \\a >= b
        \\c == d
        \\e -> f
    ;
    try esperarTipos(src, &.{
        .identificador,  .mayor_igual, .identificador, .nueva_linea,
        .identificador,  .igual,       .identificador, .nueva_linea,
        .identificador,  .flecha,      .identificador, .nueva_linea,
        .fin_de_archivo,
    });
}

test "unión implícita de líneas dentro de paréntesis" {
    const src =
        \\r = f(
        \\    1,
        \\    2,
        \\)
    ;
    try esperarTipos(src, &.{
        .identificador, .asignar,     .identificador,  .paren_izq,
        .lit_entero,    .coma,        .lit_entero,     .coma,
        .paren_der,     .nueva_linea, .fin_de_archivo,
    });
}

test "comentarios de línea ignorados" {
    const src =
        \\// comentario
        \\x = 1 // otro
        \\// final
    ;
    try esperarTipos(src, &.{
        .identificador,  .asignar, .lit_entero, .nueva_linea,
        .fin_de_archivo,
    });
}

test "operadores lógicos como símbolos" {
    const src = "r = a && b || !c";
    try esperarTipos(src, &.{
        .identificador, .asignar,        .identificador, .y_logico,
        .identificador, .o_logico,       .no_logico,     .identificador,
        .nueva_linea,   .fin_de_archivo,
    });
}

test "y/o/no son identificadores válidos (no palabras clave)" {
    const src = "y = o + no";
    try esperarTipos(src, &.{
        .identificador, .asignar,        .identificador, .mas, .identificador,
        .nueva_linea,   .fin_de_archivo,
    });
}

test "else-if con `sino si`" {
    const src =
        \\si a
        \\    x = 1
        \\sino si b
        \\    x = 2
        \\sino
        \\    x = 3
        \\fin
    ;
    try esperarTipos(src, &.{
        .kw_si,       .identificador, .nueva_linea,
        .sangria,     .identificador, .asignar,
        .lit_entero,  .nueva_linea,   .desangria,
        .kw_sino,     .kw_si,         .identificador,
        .nueva_linea, .sangria,       .identificador,
        .asignar,     .lit_entero,    .nueva_linea,
        .desangria,   .kw_sino,       .nueva_linea,
        .sangria,     .identificador, .asignar,
        .lit_entero,  .nueva_linea,   .desangria,
        .kw_fin,      .nueva_linea,   .fin_de_archivo,
    });
}

test "fuente vacía produce solo fin_de_archivo" {
    try esperarTipos("", &.{.fin_de_archivo});
}
