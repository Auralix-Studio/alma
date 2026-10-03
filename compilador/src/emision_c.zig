//! Emisor C de la IR. La semántica y el orden de evaluación viven en ir.zig.
const std = @import("std");
const ir = @import("ir.zig");
const limites = @import("limites.zig");
const Error = error{OutOfMemory};
const Emisor = struct {
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    fn e(self: *Emisor, s: []const u8) Error!void {
        try self.out.appendSlice(self.a, s);
    }
    fn f(self: *Emisor, comptime fmt: []const u8, args: anytype) Error!void {
        const s = try std.fmt.allocPrint(self.a, fmt, args);
        defer self.a.free(s);
        try self.e(s);
    }
    fn cadena(self: *Emisor, bytes: []const u8) Error!void {
        try self.e("\"");
        // Octal de ancho fijo: no depende de codificación ni de dígitos contiguos.
        for (bytes) |b| try self.f("\\{o:0>3}", .{b});
        try self.e("\"");
    }
    fn firma(self: *Emisor, id: usize, n: usize) Error!void {
        try self.f("static Val af_{d}(", .{id});
        if (n == 0) try self.e("void");
        for (0..n) |i| {
            if (i != 0) try self.e(", ");
            try self.f("Val ap_{d}", .{i});
        }
        try self.e(")");
    }
    fn funcion(self: *Emisor, id: usize, fun: ir.Funcion) Error!void {
        try self.firma(id, fun.parametros);
        try self.f(" {{\n  Val v[{d}];\n  for(size_t i=0;i<{d};i++) v[i]=indefinido();\n", .{ fun.registros, fun.registros });
        for (0..fun.parametros) |i| try self.f("  v[{d}]=alma_retener(ap_{d});\n", .{ i, i });
        for (fun.instrucciones) |inst| {
            if (inst.dato != .etiqueta) {
                try self.e("  alma_archivo=");
                try self.cadena(inst.pos.archivo orelse "programa");
                try self.f("; alma_linea={d}; alma_columna={d};\n", .{ inst.pos.linea, inst.pos.columna });
            }
            switch (inst.dato) {
                .literal => |l| {
                    try self.f("  alma_guardar(&v[{d}], ", .{l.dst});
                    switch (l.valor) {
                        .entero => |n| if (n == std.math.minInt(i64)) try self.e("ent(INT64_MIN)") else try self.f("ent(INT64_C({d}))", .{n}),
                        .decimal => |n| try self.f("dec_bits(UINT64_C({d}))", .{@as(u64, @bitCast(n))}),
                        .logico => |b| try self.e(if (b) "logv(true)" else "logv(false)"),
                        .nulo => try self.e("nulo()"),
                        .texto => |s| {
                            try self.e("txt_lit(");
                            try self.cadena(s);
                            try self.f(", {d})", .{s.len});
                        },
                    }
                    try self.e(");\n");
                },
                .copiar => |c| try self.f("  alma_guardar(&v[{d}], alma_retener(v[{d}]));\n", .{ c.dst, c.src }),
                .liberar => |r| try self.f("  alma_soltar(&v[{d}]);\n", .{r}),
                .binaria => |b| {
                    const nombre = switch (b.op) {
                        .sumar => "alma_mas",
                        .restar => "alma_menos",
                        .multiplicar => "alma_por",
                        .dividir => "alma_entre",
                        .resto => "alma_modulo",
                        .menor => "alma_menor",
                        .mayor => "alma_mayor",
                        .menor_igual => "alma_menor_ig",
                        .mayor_igual => "alma_mayor_ig",
                        .igual => "alma_igual",
                        .distinto => "alma_distinto",
                    };
                    try self.f("  alma_guardar(&v[{d}], {s}(v[{d}], v[{d}]));\n", .{ b.dst, nombre, b.izq, b.der });
                },
                .unaria => |u| {
                    const nombre = switch (u.op) {
                        .negar => "alma_neg",
                        .no => "alma_no",
                        .logico => "alma_logico",
                        .identidad => "alma_retener",
                    };
                    try self.f("  alma_guardar(&v[{d}], {s}(v[{d}]));\n", .{ u.dst, nombre, u.src });
                },
                .llamar => |l| {
                    // Comprobar antes de reservar el marco de la función destino.
                    if (l.destino == .funcion) try self.e("  alma_entrar_llamada();\n");
                    try self.f("  alma_guardar(&v[{d}], ", .{l.dst});
                    switch (l.destino) {
                        .funcion => |fid| try self.f("af_{d}(", .{fid}),
                        .texto => try self.e("alma_texto("),
                        .imprimir => try self.f("alma_imprimir({d}", .{l.args.len}),
                    }
                    for (l.args, 0..) |r, i| {
                        if (l.destino == .imprimir or i != 0) try self.e(", ");
                        try self.f("v[{d}]", .{r});
                    }
                    try self.e("));\n");
                },
                .etiqueta => |n| try self.f("al_{d}: ;\n", .{n}),
                .saltar => |n| try self.f("  goto al_{d};\n", .{n}),
                .condicional => |c| try self.f("  if(as_bool(v[{d}]) == {s}) goto al_{d};\n", .{ c.src, if (c.cuando) "true" else "false", c.etiqueta }),
                .retornar => |r| try self.f("  return alma_retornar(v, {d}, {d});\n", .{ fun.registros, r }),
            }
        }
        try self.e("}\n");
    }
};

pub fn generar(a: std.mem.Allocator, programa: *const ir.Programa) Error![]u8 {
    var e = Emisor{ .a = a };
    errdefer e.out.deinit(a);
    try e.f("#define ALMA_LIMITE_LLAMADAS {d}\n", .{limites.llamadas});
    try e.e(@embedFile("runtime/escalar.h"));
    try e.e("\n");
    for (programa.funciones, 0..) |fun, id| {
        try e.firma(id, fun.parametros);
        try e.e(";\n");
    }
    for (programa.funciones, 0..) |fun, id| try e.funcion(id, fun);
    try e.f("int main(void){{ alma_entrar_llamada(); Val resultado=af_{d}(); alma_soltar(&resultado);\n", .{programa.entrada});
    try e.e("#ifdef ALMA_VERIFICAR_MEMORIA\n  if(alma_textos_vivos) alma_error(\"textos sin liberar\");\n#endif\n  return 0;\n}\n");
    return e.out.toOwnedSlice(a);
}
