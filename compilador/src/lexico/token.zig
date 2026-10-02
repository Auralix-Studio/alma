//! token.zig — Tipos y catálogo de tokens del lenguaje Alma.
//! Contrato: docs/especificacion/01-lexico-y-tokens.md

const std = @import("std");

/// Categoría de cada token producido por el lexer.
pub const TipoToken = enum {
    // — Estructura de línea —
    nueva_linea,
    sangria,
    desangria,
    fin_de_archivo,

    // — Literales —
    identificador,
    lit_entero,
    lit_decimal,
    lit_texto,
    lit_verdadero,
    lit_falso,
    lit_nulo,

    // — Palabras clave: declaración y módulos —
    kw_funcion,
    kw_retornar,
    kw_fijo,
    kw_estructura,
    kw_modelo,
    kw_fin,
    kw_exportar,
    kw_importar,
    kw_desde,
    kw_externa,

    // — Palabras clave: control de flujo —
    kw_si,
    kw_sino,
    kw_para,
    kw_en,
    kw_mientras,
    kw_romper,
    kw_continuar,

    // — Palabras clave: concurrencia y errores —
    kw_asincrona,
    kw_esperar,
    kw_hilo,
    kw_intentar,
    kw_capturar,
    kw_lanzar,

    // — Operadores —
    mas,
    menos,
    por,
    entre,
    modulo,
    asignar,
    igual,
    distinto,
    menor,
    mayor,
    menor_igual,
    mayor_igual,
    y_logico, // &&
    o_logico, // ||
    no_logico, // !
    mas_asignar,
    menos_asignar,
    por_asignar,
    entre_asignar,
    flecha,
    punto,

    // — Delimitadores —
    paren_izq,
    paren_der,
    corchete_izq,
    corchete_der,
    llave_izq,
    llave_der,
    coma,
    dos_puntos,

    // — Error —
    invalido,

    /// Nombre legible del tipo de token (para diagnósticos y LSP).
    pub fn nombre(self: TipoToken) []const u8 {
        return @tagName(self);
    }
};

/// Un token con su lexema y ubicación (línea/columna en base 1) en el fuente.
pub const Token = struct {
    tipo: TipoToken,
    lexema: []const u8,
    linea: usize,
    columna: usize,
};

/// Devuelve el `TipoToken` de palabra clave si `texto` es reservada; si no, `null`.
/// Nota: `imprimir` NO es palabra clave (es función de la librería estándar), y los
/// tipos primitivos (`entero`, `texto`, …) son identificadores predeclarados.
pub fn palabraClave(texto: []const u8) ?TipoToken {
    const Par = struct { []const u8, TipoToken };
    const tabla = [_]Par{
        .{ "funcion", .kw_funcion },
        .{ "retornar", .kw_retornar },
        .{ "fijo", .kw_fijo },
        .{ "estructura", .kw_estructura },
        .{ "modelo", .kw_modelo },
        .{ "fin", .kw_fin },
        .{ "exportar", .kw_exportar },
        .{ "importar", .kw_importar },
        .{ "desde", .kw_desde },
        .{ "externa", .kw_externa },
        .{ "si", .kw_si },
        .{ "sino", .kw_sino },
        .{ "para", .kw_para },
        .{ "en", .kw_en },
        .{ "mientras", .kw_mientras },
        .{ "romper", .kw_romper },
        .{ "continuar", .kw_continuar },
        .{ "asincrona", .kw_asincrona },
        .{ "esperar", .kw_esperar },
        .{ "hilo", .kw_hilo },
        .{ "intentar", .kw_intentar },
        .{ "capturar", .kw_capturar },
        .{ "lanzar", .kw_lanzar },
        .{ "verdadero", .lit_verdadero },
        .{ "falso", .lit_falso },
        .{ "nulo", .lit_nulo },
    };
    for (tabla) |par| {
        if (std.mem.eql(u8, texto, par[0])) return par[1];
    }
    return null;
}

test "palabraClave: reconoce reservadas y respeta identificadores" {
    try std.testing.expectEqual(TipoToken.kw_funcion, palabraClave("funcion").?);
    try std.testing.expectEqual(TipoToken.kw_modelo, palabraClave("modelo").?);
    try std.testing.expectEqual(TipoToken.kw_estructura, palabraClave("estructura").?);
    try std.testing.expectEqual(TipoToken.lit_verdadero, palabraClave("verdadero").?);
    try std.testing.expect(palabraClave("imprimir") == null);
    try std.testing.expect(palabraClave("usuario") == null);
    try std.testing.expect(palabraClave("entero") == null); // tipo primitivo = identificador
    // Los operadores lógicos son símbolos (`&&`/`||`/`!`), así que estas palabras
    // quedan libres como identificadores (p.ej. Vector3D.y).
    try std.testing.expect(palabraClave("y") == null);
    try std.testing.expect(palabraClave("o") == null);
    try std.testing.expect(palabraClave("no") == null);
}
