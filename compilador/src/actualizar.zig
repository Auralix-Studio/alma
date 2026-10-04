//! actualizar.zig — `alma actualizar`: instala otra versión publicada en GitHub
//! Releases. Descarga el binario de la plataforma y el SHA256SUMS.txt de la misma
//! versión, verifica el SHA-256 y solo entonces reemplaza el ejecutable en uso.
//! Mismo contrato que distribucion/instalar.ps1 e instalar.sh.

const std = @import("std");
const builtin = @import("builtin");

pub const repositorio = "Auralix-Studio/alma";
const limite_binario = 128 * 1024 * 1024;
const limite_texto = 1024 * 1024;

pub const Opciones = struct {
    /// Solo informa si hay una versión más nueva; no descarga nada.
    solo_comprobar: bool = false,
    /// Versión concreta (`v0.1.0`, `0.1.0`, `v0.1.0-rc.1`). null = última estable.
    version: ?[]const u8 = null,
};

pub const Resultado = union(enum) {
    /// Ya está instalada la última versión estable (etiqueta publicada).
    al_dia: []const u8,
    /// Hay una versión más nueva y no se instaló (`--comprobar`).
    disponible: []const u8,
    /// Se instaló esta versión.
    actualizado: []const u8,
};

/// Nombre del binario publicado para la plataforma actual, o null si no hay.
pub fn nombreBinario() ?[]const u8 {
    return nombreBinarioPara(builtin.os.tag, builtin.cpu.arch);
}

/// Linux ARM64 cubre también Android/Termux: el binario es estático (musl).
fn nombreBinarioPara(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .windows => if (arch == .x86_64) "alma-windows-x64.exe" else null,
        .linux => switch (arch) {
            .x86_64 => "alma-linux-x64",
            .aarch64 => "alma-linux-arm64",
            else => null,
        },
        else => null,
    };
}

const Version = struct {
    numeros: [3]u64,
    /// Sufijo de prerelease (`rc.1`), vacío en versiones finales.
    previa: []const u8,

    fn leer(texto: []const u8) ?Version {
        var t = std.mem.trim(u8, texto, " \t\r\n");
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        const guion = std.mem.indexOfScalar(u8, t, '-');
        const base = if (guion) |g| t[0..g] else t;
        var v = Version{ .numeros = .{ 0, 0, 0 }, .previa = if (guion) |g| t[g + 1 ..] else "" };
        var partes = std.mem.splitScalar(u8, base, '.');
        var i: usize = 0;
        while (partes.next()) |parte| : (i += 1) {
            if (i >= 3) return null;
            v.numeros[i] = std.fmt.parseInt(u64, parte, 10) catch return null;
        }
        if (i != 3) return null;
        return v;
    }
};

/// Orden entre versiones `X.Y.Z[-previa]` (con o sin `v`). Una prerelease es
/// anterior a su versión final; dos prereleases se comparan por texto.
/// Las versiones ilegibles se consideran iguales (no se actualiza a ciegas).
pub fn compararVersiones(a: []const u8, b: []const u8) std.math.Order {
    const va = Version.leer(a) orelse return .eq;
    const vb = Version.leer(b) orelse return .eq;
    for (va.numeros, vb.numeros) |x, y| {
        if (x != y) return std.math.order(x, y);
    }
    if (va.previa.len == 0 and vb.previa.len == 0) return .eq;
    if (va.previa.len == 0) return .gt;
    if (vb.previa.len == 0) return .lt;
    return std.mem.order(u8, va.previa, vb.previa);
}

/// Hash esperado de `nombre` en un SHA256SUMS.txt (coincidencia exacta del
/// nombre; admite el prefijo `*` del modo binario de sha256sum).
pub fn hashEsperado(sumas: []const u8, nombre: []const u8) ?[64]u8 {
    var lineas = std.mem.splitScalar(u8, sumas, '\n');
    while (lineas.next()) |cruda| {
        const linea = std.mem.trim(u8, cruda, " \t\r");
        var campos = std.mem.tokenizeAny(u8, linea, " \t");
        const hash = campos.next() orelse continue;
        var archivo = campos.next() orelse continue;
        if (archivo.len > 0 and archivo[0] == '*') archivo = archivo[1..];
        if (hash.len != 64 or !std.mem.eql(u8, archivo, nombre)) continue;
        var salida: [64]u8 = undefined;
        for (hash, 0..) |c, i| {
            if (!std.ascii.isHex(c)) return null;
            salida[i] = std.ascii.toLower(c);
        }
        return salida;
    }
    return null;
}

pub fn sha256Hex(datos: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(datos, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// GET con redirecciones y tope de bytes. Devuelve error.RespuestaHttp si el
/// estado final no es 200.
fn descargar(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8, limite: usize) ![]u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json, application/octet-stream" }},
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) {
        std.debug.print("{s}: HTTP {d}\n", .{ url, @intFromEnum(response.head.status) });
        return error.RespuestaHttp;
    }
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(limite)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
}

/// Etiqueta de la última versión estable publicada (las prereleases no cuentan).
fn ultimaEtiqueta(client: *std.http.Client, arena: std.mem.Allocator) ![]const u8 {
    const url = "https://api.github.com/repos/" ++ repositorio ++ "/releases/latest";
    const cuerpo = descargar(client, arena, url, limite_texto) catch |err| {
        if (err == error.RespuestaHttp) std.debug.print("No hay ninguna versión estable publicada todavía (usa --version para instalar una de prueba).\n", .{});
        return err;
    };
    const Respuesta = struct { tag_name: []const u8 };
    const datos = try std.json.parseFromSliceLeaky(Respuesta, arena, cuerpo, .{ .ignore_unknown_fields = true });
    return datos.tag_name;
}

/// Comprueba, descarga, verifica e instala. `arena` es dueña de todo lo devuelto.
pub fn actualizar(io: std.Io, arena: std.mem.Allocator, version_actual: []const u8, opciones: Opciones) !Resultado {
    const nombre = nombreBinario() orelse {
        std.debug.print("No se publican binarios de Alma para esta plataforma (Windows x64, Linux x64 y Linux ARM64, incluido Android/Termux).\n", .{});
        return error.PlataformaSinBinarios;
    };
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const etiqueta = if (opciones.version) |v|
        (if (v.len > 0 and v[0] == 'v') v else try std.fmt.allocPrint(arena, "v{s}", .{v}))
    else
        try ultimaEtiqueta(&client, arena);
    if (Version.leer(etiqueta) == null) {
        std.debug.print("Versión inválida: '{s}'\n", .{etiqueta});
        return error.VersionInvalida;
    }
    if (opciones.version == null and compararVersiones(etiqueta, version_actual) != .gt) return .{ .al_dia = etiqueta };
    if (opciones.solo_comprobar) return .{ .disponible = etiqueta };

    const base = try std.fmt.allocPrint(arena, "https://github.com/" ++ repositorio ++ "/releases/download/{s}/", .{etiqueta});
    const sumas = try descargar(&client, arena, try std.fmt.allocPrint(arena, "{s}SHA256SUMS.txt", .{base}), limite_texto);
    const esperado = hashEsperado(sumas, nombre) orelse {
        std.debug.print("{s} no figura en SHA256SUMS.txt de {s}: no se instala.\n", .{ nombre, etiqueta });
        return error.HashNoEncontrado;
    };
    const binario = try descargar(&client, arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ base, nombre }), limite_binario);
    const obtenido = sha256Hex(binario);
    if (!std.mem.eql(u8, &obtenido, &esperado)) {
        std.debug.print("El SHA-256 de {s} no coincide con SHA256SUMS.txt: no se instala.\n", .{nombre});
        return error.HashNoCoincide;
    }

    try reemplazarEjecutable(io, arena, binario);
    return .{ .actualizado = etiqueta };
}

/// Escribe el nuevo binario junto al actual y lo pone en su lugar. Linux: rename
/// atómico sobre el archivo en uso. Windows no permite sobrescribir un .exe en
/// ejecución, pero sí renombrarlo: el actual pasa a `.anterior` (se borra en la
/// próxima actualización) y el nuevo ocupa su nombre.
fn reemplazarEjecutable(io: std.Io, arena: std.mem.Allocator, binario: []const u8) !void {
    const actual = try std.process.executablePathAlloc(io, arena);
    const nuevo = try std.fmt.allocPrint(arena, "{s}.nuevo", .{actual});
    const anterior = try std.fmt.allocPrint(arena, "{s}.anterior", .{actual});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = nuevo, .data = binario, .flags = .{ .permissions = .executable_file } });
    errdefer cwd.deleteFile(io, nuevo) catch {};
    if (builtin.os.tag == .windows) {
        cwd.deleteFile(io, anterior) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        // std.Io.Dir.rename devuelve FileBusy con el .exe en ejecución;
        // MoveFileExW sí puede renombrar la imagen en uso.
        try moverWindows(arena, actual, anterior);
        moverWindows(arena, nuevo, actual) catch |err| {
            // Deja el ejecutable original en su sitio si el segundo paso falla.
            moverWindows(arena, anterior, actual) catch {};
            return err;
        };
    } else {
        try cwd.rename(nuevo, cwd, actual, io);
    }
}

extern "kernel32" fn MoveFileExW(existente: [*:0]const u16, nuevo: ?[*:0]const u16, banderas: u32) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn moverWindows(arena: std.mem.Allocator, desde: []const u8, hacia: []const u8) !void {
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    const a = try std.unicode.wtf8ToWtf16LeAllocZ(arena, desde);
    const b = try std.unicode.wtf8ToWtf16LeAllocZ(arena, hacia);
    if (MoveFileExW(a.ptr, b.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) {
        std.debug.print("No se pudo mover '{s}' a '{s}' (error de Windows {d}).\n", .{ desde, hacia, GetLastError() });
        return error.NoSePudoReemplazar;
    }
}

test "comparar versiones semánticas con prereleases" {
    const o = compararVersiones;
    try std.testing.expectEqual(std.math.Order.gt, o("v0.2.0", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.eq, o("v0.1.0", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.lt, o("0.1.9", "0.1.10"));
    try std.testing.expectEqual(std.math.Order.gt, o("1.0.0", "0.99.99"));
    try std.testing.expectEqual(std.math.Order.lt, o("v0.1.0-rc.1", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.gt, o("v0.1.0", "v0.1.0-rc.2"));
    try std.testing.expectEqual(std.math.Order.lt, o("v0.1.0-rc.1", "v0.1.0-rc.2"));
    try std.testing.expectEqual(std.math.Order.eq, o("basura", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.eq, o("1.2", "0.1.0"));
}

test "hash esperado: coincidencia exacta del nombre" {
    const sumas =
        "0000000000000000000000000000000000000000000000000000000000000001  alma-linux-x64\r\n" ++
        "ABCDEF0000000000000000000000000000000000000000000000000000000002 *alma-windows-x64.exe\n" ++
        "0000000000000000000000000000000000000000000000000000000000000003  alma\n";
    try std.testing.expectEqualStrings("abcdef0000000000000000000000000000000000000000000000000000000002", &hashEsperado(sumas, "alma-windows-x64.exe").?);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000003", &hashEsperado(sumas, "alma").?);
    try std.testing.expect(hashEsperado(sumas, "alma-macos-x64") == null);
    try std.testing.expect(hashEsperado("xyz  alma", "alma") == null);
}

test "binario publicado por plataforma" {
    try std.testing.expectEqualStrings("alma-windows-x64.exe", nombreBinarioPara(.windows, .x86_64).?);
    try std.testing.expectEqualStrings("alma-linux-x64", nombreBinarioPara(.linux, .x86_64).?);
    try std.testing.expectEqualStrings("alma-linux-arm64", nombreBinarioPara(.linux, .aarch64).?);
    try std.testing.expect(nombreBinarioPara(.linux, .arm) == null);
    try std.testing.expect(nombreBinarioPara(.windows, .aarch64) == null);
    try std.testing.expect(nombreBinarioPara(.macos, .aarch64) == null);
}

test "sha256 en hexadecimal" {
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
}
