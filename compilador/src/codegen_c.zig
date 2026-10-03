//! Entrada del backend C: AST validado -> IR de Alma -> runtime y código C.
const std = @import("std");
const ast = @import("sintaxis/ast.zig");
const ir = @import("ir.zig");
const emision = @import("emision_c.zig");

/// El llamador libera fuente_c o diag con el allocator usado en generar.
pub const Resultado = struct { fuente_c: ?[]u8 = null, diag: ?[]const u8 = null };

pub fn generar(gpa: std.mem.Allocator, stmts: []const ast.Stmt) error{OutOfMemory}!Resultado {
    var programa = try ir.construir(gpa, stmts);
    defer programa.deinit();
    if (programa.diag) |diag| return .{ .diag = try gpa.dupe(u8, diag) };
    return .{ .fuente_c = try emision.generar(gpa, &programa) };
}

test "genera C para un programa simple mediante IR" {
    const lexer = @import("lexico/lexer.zig");
    const parser = @import("sintaxis/parser.zig");
    const src =
        \\funcion doble(n: entero) -> entero
        \\    retornar n * 2
        \\fin
        \\funcion principal()
        \\    imprimir(doble(21))
        \\fin
    ;
    const toks = try lexer.tokenizar(std.testing.allocator, src);
    defer std.testing.allocator.free(toks);
    var p = parser.Parser.init(std.testing.allocator, toks);
    defer p.deinit();
    const programa = try p.parsePrograma();
    const res = try generar(std.testing.allocator, programa);
    const c = res.fuente_c.?;
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "static Val af_0(Val ap_0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "alma_retornar(v,") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "int main(void)") != null);
}
