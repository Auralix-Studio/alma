//! paquete.zig — Manifiesto de proyecto `alma.paquete`.
//!
//! Formato simple de líneas: `clave = valor` y secciones `[nombre]`. Claves de nivel
//! superior: `nombre`, `version`, `entrada`. Sección `[dependencias]`: `alias = ruta`.
//! Comentarios con `#` o `//`. El comando `alma paquete validar` usa este parser.

const std = @import("std");

pub const Dependencia = struct {
    alias: []const u8,
    ruta: []const u8,
};

pub const Manifiesto = struct {
    nombre: []const u8 = "",
    version: []const u8 = "",
    entrada: []const u8 = "",
    dependencias: []const Dependencia = &.{},
};

/// Parsea el texto del manifiesto. Las cadenas devueltas apuntan a `texto` (mantenelo
/// vivo) salvo el slice de dependencias, asignado en `alloc`.
pub fn parsear(alloc: std.mem.Allocator, texto: []const u8) !Manifiesto {
    var man = Manifiesto{};
    var deps: std.ArrayListUnmanaged(Dependencia) = .empty;
    var seccion: []const u8 = "";

    var it = std.mem.tokenizeScalar(u8, texto, '\n');
    while (it.next()) |linea_raw| {
        const linea = std.mem.trim(u8, linea_raw, " \t\r");
        if (linea.len == 0 or linea[0] == '#') continue;
        if (std.mem.startsWith(u8, linea, "//")) continue;

        if (linea[0] == '[' and linea[linea.len - 1] == ']') {
            seccion = std.mem.trim(u8, linea[1 .. linea.len - 1], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, linea, '=') orelse continue;
        const clave = std.mem.trim(u8, linea[0..eq], " \t");
        const valor = quitarComillas(std.mem.trim(u8, linea[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, seccion, "dependencias")) {
            try deps.append(alloc, .{ .alias = clave, .ruta = valor });
        } else if (std.mem.eql(u8, clave, "nombre")) {
            man.nombre = valor;
        } else if (std.mem.eql(u8, clave, "version")) {
            man.version = valor;
        } else if (std.mem.eql(u8, clave, "entrada")) {
            man.entrada = valor;
        }
    }

    man.dependencias = try deps.toOwnedSlice(alloc);
    return man;
}

fn quitarComillas(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

test "parsear manifiesto" {
    const texto =
        \\# Proyecto de ejemplo
        \\nombre = mi-proyecto
        \\version = 0.1.0
        \\entrada = principal.alma
        \\
        \\[dependencias]
        \\mates = "matematicas.alma"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parsear(arena.allocator(), texto);
    try std.testing.expectEqualStrings("mi-proyecto", m.nombre);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqualStrings("principal.alma", m.entrada);
    try std.testing.expectEqual(@as(usize, 1), m.dependencias.len);
    try std.testing.expectEqualStrings("mates", m.dependencias[0].alias);
    try std.testing.expectEqualStrings("matematicas.alma", m.dependencias[0].ruta);
}
