//! pruebas.zig — Raíz que agrega todos los tests del compilador.
//! Se ejecuta con `zig build test`.

test {
    _ = @import("lexico/token.zig");
    _ = @import("lexico/lexer.zig");
    _ = @import("sintaxis/ast.zig");
    _ = @import("sintaxis/parser.zig");
    _ = @import("ejecucion/interprete.zig");
    _ = @import("semantica/analizador.zig");
    _ = @import("paquete.zig");
    _ = @import("codegen_c.zig");
    _ = @import("codegen_pe.zig");
}
