//! numeros.zig — Semántica numérica y de escapes compartida por los motores.
//!
//! Contrato: docs/PROPUESTA-NUMEROS.md. El runtime C (runtime/escalar.h) implementa
//! el mismo contrato en C; las pruebas diferenciales comparan ambos con el intérprete.

const std = @import("std");
const float = std.fmt.float;

/// Tamaño suficiente para cualquier `decimal` formateado (máximo real: 25 bytes).
pub const max_decimal = 32;

/// Formato canónico de un binary64: dígitos shortest round-trip (Ryu), notación fija
/// si el exponente decimal normalizado está en [-6, 20] y científica fuera de ese
/// intervalo (`1e21`, `1.5e-7`). Sin `+`, sin ceros finales, sin `.0` en integrales.
pub fn formatearDecimal(buf: *[max_decimal]u8, d: f64) []const u8 {
    if (std.math.isNan(d)) return copiar(buf, "nan");
    if (std.math.isInf(d)) return copiar(buf, if (d < 0) "-inf" else "inf");
    const bits: u64 = @bitCast(d);
    const fd = float.binaryToDecimal(u64, bits, std.math.floatMantissaBits(f64), std.math.floatExponentBits(f64), false, &float.Backend64_TablesFull);
    var n: usize = 0;
    if (fd.sign) {
        buf[0] = '-';
        n = 1;
    }
    if (fd.mantissa == 0) {
        buf[n] = '0';
        return buf[0 .. n + 1];
    }
    var m = fd.mantissa;
    var e = fd.exponent;
    while (m % 10 == 0) {
        m /= 10;
        e += 1;
    }
    var digitos_buf: [20]u8 = undefined;
    const digitos = std.fmt.bufPrint(&digitos_buf, "{d}", .{m}) catch unreachable; // u64 ≤ 20 dígitos
    const k: i32 = @intCast(digitos.len);
    const exp10 = e + k - 1; // exponente del primer dígito
    if (exp10 < -6 or exp10 > 20) {
        buf[n] = digitos[0];
        n += 1;
        if (digitos.len > 1) {
            buf[n] = '.';
            n += 1;
            @memcpy(buf[n..][0 .. digitos.len - 1], digitos[1..]);
            n += digitos.len - 1;
        }
        buf[n] = 'e';
        n += 1;
        const exp_txt = std.fmt.bufPrint(buf[n..], "{d}", .{exp10}) catch unreachable;
        return buf[0 .. n + exp_txt.len];
    }
    if (e >= 0) {
        @memcpy(buf[n..][0..digitos.len], digitos);
        n += digitos.len;
        const ceros: usize = @intCast(e);
        @memset(buf[n..][0..ceros], '0');
        return buf[0 .. n + ceros];
    }
    if (exp10 >= 0) {
        const enteros: usize = @intCast(exp10 + 1);
        @memcpy(buf[n..][0..enteros], digitos[0..enteros]);
        n += enteros;
        buf[n] = '.';
        n += 1;
        @memcpy(buf[n..][0 .. digitos.len - enteros], digitos[enteros..]);
        return buf[0 .. n + digitos.len - enteros];
    }
    const ceros: usize = @intCast(-exp10 - 1);
    @memcpy(buf[n..][0..2], "0.");
    n += 2;
    @memset(buf[n..][0..ceros], '0');
    n += ceros;
    @memcpy(buf[n..][0..digitos.len], digitos);
    return buf[0 .. n + digitos.len];
}

fn copiar(buf: *[max_decimal]u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Compara un entero con un decimal por su valor matemático exacto, sin convertir
/// el entero a binary64. Devuelve null si `d` es NaN (no ordenable).
pub fn compararEnteroDecimal(i: i64, d: f64) ?std.math.Order {
    if (std.math.isNan(d)) return null;
    const limite: f64 = 9223372036854775808.0; // 2^63, exacto en binary64
    if (d >= limite) return .lt;
    if (d < -limite) return .gt;
    // d ∈ [-2^63, 2^63): su parte entera cabe en i64 sin redondeo.
    const t = @trunc(d);
    const ti: i64 = @intFromFloat(t);
    if (i != ti) return std.math.order(i, ti);
    const fraccion = d - t;
    if (fraccion > 0) return .lt;
    if (fraccion < 0) return .gt;
    return .eq;
}

/// Byte que produce el escape `\c` en un literal de texto. Lista cerrada:
/// `\n \t \r \0 \\ \"`; un escape desconocido conserva el carácter (sin la barra),
/// comportamiento previo compartido por todos los motores hasta que se apruebe
/// su rechazo léxico (especificación 01, §8.3).
pub fn byteDeEscape(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => c,
    };
}

/// Decodifica el lexema de un literal de texto (con comillas) en `out`.
pub fn decodificarTexto(a: std.mem.Allocator, lexema: []const u8) error{OutOfMemory}![]u8 {
    const inner = if (lexema.len >= 2) lexema[1 .. lexema.len - 1] else lexema;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            i += 1;
            out.appendAssumeCapacity(byteDeEscape(inner[i]));
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(a);
}

/// Magnitud de un literal entero (admite separadores `_`). null si no es un entero
/// decimal válido o excede u64.
pub fn magnitudLiteral(lexema: []const u8) ?u64 {
    return std.fmt.parseInt(u64, lexema, 10) catch null;
}

/// Valor i64 de un literal entero ya validado por el analizador (puede llevar `-`
/// cuando el parser plegó la negación del mínimo).
pub fn valorLiteral(lexema: []const u8) ?i64 {
    return std.fmt.parseInt(i64, lexema, 10) catch null;
}

// — Pruebas —

fn esperarFormato(d: f64, esperado: []const u8) !void {
    var buf: [max_decimal]u8 = undefined;
    try std.testing.expectEqualStrings(esperado, formatearDecimal(&buf, d));
}

test "formato decimal canonico de la propuesta numerica" {
    // Valores en tiempo de ejecución: en comptime 0.1 + 0.2 se calcula con
    // precisión exacta y daría 0.3.
    var tres: f64 = 3.0;
    var un_decimo: f64 = 0.1;
    _ = .{ &tres, &un_decimo };
    try esperarFormato(un_decimo + 0.2, "0.30000000000000004");
    try esperarFormato(10000000.0, "10000000");
    try esperarFormato(1.0 / tres, "0.3333333333333333");
    try esperarFormato(-0.0, "-0");
    try esperarFormato(0.0, "0");
    try esperarFormato(4.0, "4");
    try esperarFormato(1.5, "1.5");
    try esperarFormato(-2.25, "-2.25");
    try esperarFormato(1e20, "100000000000000000000");
    try esperarFormato(1e21, "1e21");
    try esperarFormato(123456789012345680000.0, "123456789012345680000");
    try esperarFormato(0.000001, "0.000001");
    try esperarFormato(0.0000001, "1e-7");
    try esperarFormato(1.5e-7, "1.5e-7");
    try esperarFormato(std.math.floatMax(f64), "1.7976931348623157e308");
    try esperarFormato(std.math.floatTrueMin(f64), "5e-324");
    try esperarFormato(std.math.floatMin(f64), "2.2250738585072014e-308");
    try esperarFormato(std.math.nan(f64), "nan");
    try esperarFormato(std.math.inf(f64), "inf");
    try esperarFormato(-std.math.inf(f64), "-inf");
    try esperarFormato(9007199254740993.0, "9007199254740992");
}

test "formato decimal: ida y vuelta con muestreo determinista de bits" {
    var prng = std.Random.DefaultPrng.init(0x416c6d61);
    const r = prng.random();
    var buf: [max_decimal]u8 = undefined;
    for (0..20000) |_| {
        const bits = r.int(u64);
        const d: f64 = @bitCast(bits);
        if (!std.math.isFinite(d)) continue;
        const s = formatearDecimal(&buf, d);
        const leido = try std.fmt.parseFloat(f64, s);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(leido)));
    }
}

test "comparacion exacta entre entero y decimal" {
    const o = compararEnteroDecimal;
    try std.testing.expectEqual(std.math.Order.gt, o(9007199254740993, 9007199254740992.0).?);
    try std.testing.expectEqual(std.math.Order.eq, o(9007199254740992, 9007199254740992.0).?);
    try std.testing.expectEqual(std.math.Order.eq, o(0, -0.0).?);
    try std.testing.expectEqual(std.math.Order.lt, o(1, 1.5).?);
    try std.testing.expectEqual(std.math.Order.gt, o(-1, -1.5).?);
    try std.testing.expectEqual(std.math.Order.lt, o(std.math.maxInt(i64), 9223372036854775808.0).?);
    try std.testing.expectEqual(std.math.Order.eq, o(std.math.minInt(i64), -9223372036854775808.0).?);
    try std.testing.expectEqual(std.math.Order.gt, o(std.math.minInt(i64), -9223372036854777856.0).?);
    try std.testing.expectEqual(std.math.Order.lt, o(std.math.maxInt(i64), std.math.inf(f64)).?);
    try std.testing.expectEqual(std.math.Order.gt, o(std.math.minInt(i64), -std.math.inf(f64)).?);
    try std.testing.expect(o(0, std.math.nan(f64)) == null);
}

test "escapes de texto compartidos" {
    const a = std.testing.allocator;
    const s = try decodificarTexto(a, "\"a\\n\\t\\r\\0\\\\\\\"z\"");
    defer a.free(s);
    try std.testing.expectEqualSlices(u8, "a\n\t\r\x00\\\"z", s);
}

test "magnitud y valor de literales enteros" {
    try std.testing.expectEqual(@as(?u64, 9223372036854775808), magnitudLiteral("9223372036854775808"));
    try std.testing.expectEqual(@as(?u64, 1000), magnitudLiteral("1_000"));
    try std.testing.expect(valorLiteral("9223372036854775808") == null);
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), valorLiteral("-9223372036854775808"));
}
