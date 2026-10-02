//! codegen_c.zig — Generador de código C para `alma compilar`.
//!
//! Transpila un subconjunto de Alma a C, que luego se compila a binario nativo con
//! `zig cc`. Subconjunto v0.1: funciones + recursión, variables, aritmética/comparación/
//! lógica, texto (+ concatena), `si/sino si/sino`, `mientras`, `imprimir`, `texto()`.
//! No soportado (usá `alma ejecutar`): listas, diccionarios, estructura/modelo, `para`,
//! módulos/stdlib, async, try/catch.

const std = @import("std");
const ast = @import("sintaxis/ast.zig");
const tk = @import("lexico/token.zig");

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Buffer = std.ArrayListUnmanaged(u8);

pub const Error = error{ NoSoportado, OutOfMemory };

pub const Resultado = struct {
    fuente_c: ?[]u8 = null,
    diag: ?[]const u8 = null,
};

const PRELUDIO =
    \\#include <stdio.h>
    \\#include <stdint.h>
    \\#include <stdbool.h>
    \\#include <stdlib.h>
    \\#include <string.h>
    \\#include <stdarg.h>
    \\
    \\typedef enum { T_NULO, T_ENT, T_DEC, T_LOG, T_TXT } Tag;
    \\typedef struct { Tag tag; int64_t ent; double dec; bool logv; const char* txt; } Val;
    \\
    \\static Val nulo(void){ Val v; v.tag=T_NULO; return v; }
    \\static Val ent(int64_t n){ Val v; v.tag=T_ENT; v.ent=n; return v; }
    \\static Val dec(double d){ Val v; v.tag=T_DEC; v.dec=d; return v; }
    \\static Val logv(bool b){ Val v; v.tag=T_LOG; v.logv=b; return v; }
    \\static Val txt(const char* s){ Val v; v.tag=T_TXT; v.txt=s; return v; }
    \\
    \\static double as_num(Val v){ return v.tag==T_DEC ? v.dec : (double)v.ent; }
    \\static bool as_bool(Val v){ return v.tag==T_LOG ? v.logv : (v.tag!=T_NULO); }
    \\static bool ambos_ent(Val a, Val b){ return a.tag==T_ENT && b.tag==T_ENT; }
    \\
    \\static const char* a_cstr(Val v){
    \\  char* b;
    \\  switch(v.tag){
    \\    case T_TXT: return v.txt;
    \\    case T_LOG: return v.logv ? "verdadero" : "falso";
    \\    case T_NULO: return "nulo";
    \\    case T_ENT: b=malloc(24); snprintf(b,24,"%lld",(long long)v.ent); return b;
    \\    case T_DEC: b=malloc(32); snprintf(b,32,"%g",v.dec); return b;
    \\  }
    \\  return "";
    \\}
    \\static Val alma_mas(Val a, Val b){
    \\  if(a.tag==T_TXT || b.tag==T_TXT){
    \\    const char* sa=a_cstr(a); const char* sb=a_cstr(b);
    \\    char* r=malloc(strlen(sa)+strlen(sb)+1); strcpy(r,sa); strcat(r,sb); return txt(r);
    \\  }
    \\  if(ambos_ent(a,b)) return ent(a.ent+b.ent);
    \\  return dec(as_num(a)+as_num(b));
    \\}
    \\static Val alma_menos(Val a, Val b){ return ambos_ent(a,b)?ent(a.ent-b.ent):dec(as_num(a)-as_num(b)); }
    \\static Val alma_por(Val a, Val b){ return ambos_ent(a,b)?ent(a.ent*b.ent):dec(as_num(a)*as_num(b)); }
    \\static Val alma_entre(Val a, Val b){ if(ambos_ent(a,b)){ if(b.ent==0){fprintf(stderr,"division por cero\n");exit(1);} return ent(a.ent/b.ent);} return dec(as_num(a)/as_num(b)); }
    \\static Val alma_modulo(Val a, Val b){ if(b.ent==0){fprintf(stderr,"modulo por cero\n");exit(1);} return ent(a.ent % b.ent); }
    \\static Val alma_neg(Val a){ return a.tag==T_DEC?dec(-a.dec):ent(-a.ent); }
    \\static Val alma_no(Val a){ return logv(!as_bool(a)); }
    \\static Val alma_menor(Val a, Val b){ return logv(ambos_ent(a,b)?a.ent<b.ent:as_num(a)<as_num(b)); }
    \\static Val alma_mayor(Val a, Val b){ return logv(ambos_ent(a,b)?a.ent>b.ent:as_num(a)>as_num(b)); }
    \\static Val alma_menor_ig(Val a, Val b){ return logv(ambos_ent(a,b)?a.ent<=b.ent:as_num(a)<=as_num(b)); }
    \\static Val alma_mayor_ig(Val a, Val b){ return logv(ambos_ent(a,b)?a.ent>=b.ent:as_num(a)>=as_num(b)); }
    \\static bool val_ig(Val a, Val b){
    \\  if(ambos_ent(a,b)) return a.ent==b.ent;
    \\  if((a.tag==T_ENT||a.tag==T_DEC)&&(b.tag==T_ENT||b.tag==T_DEC)) return as_num(a)==as_num(b);
    \\  if(a.tag!=b.tag) return false;
    \\  if(a.tag==T_TXT) return strcmp(a.txt,b.txt)==0;
    \\  if(a.tag==T_LOG) return a.logv==b.logv;
    \\  return true;
    \\}
    \\static Val alma_igual(Val a, Val b){ return logv(val_ig(a,b)); }
    \\static Val alma_distinto(Val a, Val b){ return logv(!val_ig(a,b)); }
    \\static Val alma_texto(Val v){ return txt(a_cstr(v)); }
    \\static Val alma_imprimir(int n, ...){
    \\  va_list ap; va_start(ap,n);
    \\  for(int i=0;i<n;i++){ if(i>0) fputc(' ',stdout); Val v=va_arg(ap,Val); fputs(a_cstr(v),stdout); }
    \\  va_end(ap); fputc('\n',stdout); return nulo();
    \\}
    \\
;

const builtins_no_soportados = [_][]const u8{ "rango", "longitud", "agregar", "claves", "tiene", "error" };

const Gen = struct {
    gpa: std.mem.Allocator,
    out: Buffer = .empty,
    diag: ?[]const u8 = null,
    params: []const ast.Param = &.{},

    fn e(self: *Gen, s: []const u8) Error!void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn noSoportado(self: *Gen, comptime fmt: []const u8, args: anytype) Error {
        self.diag = std.fmt.allocPrint(self.gpa, fmt, args) catch "construcción no soportada";
        return Error.NoSoportado;
    }

    fn emitNombre(self: *Gen, prefijo: []const u8, nombre: []const u8) Error!void {
        try self.e(prefijo);
        for (nombre) |c| {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                try self.out.append(self.gpa, c);
            } else {
                const hx = try std.fmt.allocPrint(self.gpa, "_{x:0>2}", .{c});
                defer self.gpa.free(hx);
                try self.e(hx);
            }
        }
    }

    fn emitNumero(self: *Gen, lex: []const u8) Error!void {
        for (lex) |c| if (c != '_') try self.out.append(self.gpa, c);
    }

    fn emitCadena(self: *Gen, lex: []const u8) Error!void {
        const inner = if (lex.len >= 2) lex[1 .. lex.len - 1] else lex;
        try self.out.append(self.gpa, '"');
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            var c = inner[i];
            if (c == '\\' and i + 1 < inner.len) {
                i += 1;
                c = switch (inner[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => inner[i],
                };
            }
            switch (c) {
                '"' => try self.e("\\\""),
                '\\' => try self.e("\\\\"),
                '\n' => try self.e("\\n"),
                '\t' => try self.e("\\t"),
                '\r' => try self.e("\\r"),
                else => try self.out.append(self.gpa, c),
            }
        }
        try self.out.append(self.gpa, '"');
    }

    // — Funciones —

    fn genFirma(self: *Gen, f: *const Stmt.Funcion) Error!void {
        try self.e("Val ");
        try self.emitNombre("af_", f.nombre);
        try self.e("(");
        if (f.params.len == 0) {
            try self.e("void");
        } else {
            for (f.params, 0..) |_, i| {
                if (i > 0) try self.e(", ");
                try self.e("Val");
            }
        }
        try self.e(")");
    }

    fn genFuncion(self: *Gen, f: *const Stmt.Funcion) Error!void {
        // Firma CON nombres de parámetros (definición).
        try self.e("Val ");
        try self.emitNombre("af_", f.nombre);
        try self.e("(");
        if (f.params.len == 0) {
            try self.e("void");
        } else {
            for (f.params, 0..) |p, i| {
                if (i > 0) try self.e(", ");
                try self.e("Val ");
                try self.emitNombre("av_", p.nombre);
            }
        }
        try self.e(") {\n");
        self.params = f.params;

        // Declarar variables locales (no parámetros).
        var locales: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer locales.deinit(self.gpa);
        try self.recolectarLocales(f.cuerpo, &locales);
        for (locales.keys()) |nombre| {
            if (self.esParametro(nombre)) continue;
            try self.e("  Val ");
            try self.emitNombre("av_", nombre);
            try self.e(" = nulo();\n");
        }

        try self.genBloque(f.cuerpo, 1);
        try self.e("  return nulo();\n}\n\n");
        self.params = &.{};
    }

    fn esParametro(self: *Gen, nombre: []const u8) bool {
        for (self.params) |p| if (std.mem.eql(u8, p.nombre, nombre)) return true;
        return false;
    }

    fn recolectarLocales(self: *Gen, cuerpo: []const Stmt, set: *std.StringArrayHashMapUnmanaged(void)) Error!void {
        for (cuerpo) |*s| {
            switch (s.dato) {
                .declaracion => |d| try set.put(self.gpa, d.nombre, {}),
                .asignacion => |asig| if (asig.objetivo.* == .identificador) try set.put(self.gpa, asig.objetivo.identificador, {}),
                .si => |si| {
                    for (si.ramas) |r| try self.recolectarLocales(r.cuerpo, set);
                    if (si.sino) |c| try self.recolectarLocales(c, set);
                },
                .mientras => |m| try self.recolectarLocales(m.cuerpo, set),
                else => {},
            }
        }
    }

    // — Sentencias —

    fn sangria(self: *Gen, n: usize) Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.e("  ");
    }

    fn genBloque(self: *Gen, cuerpo: []const Stmt, nivel: usize) Error!void {
        for (cuerpo) |*s| try self.genStmt(s, nivel);
    }

    fn genStmt(self: *Gen, s: *const Stmt, nivel: usize) Error!void {
        switch (s.dato) {
            .declaracion => |d| {
                try self.sangria(nivel);
                try self.emitNombre("av_", d.nombre);
                try self.e(" = ");
                try self.genExpr(d.valor);
                try self.e(";\n");
            },
            .asignacion => |asig| {
                if (asig.objetivo.* != .identificador) return self.noSoportado("solo se puede asignar a variables simples al compilar", .{});
                try self.sangria(nivel);
                try self.emitNombre("av_", asig.objetivo.identificador);
                try self.e(" = ");
                try self.genExpr(asig.valor);
                try self.e(";\n");
            },
            .expresion => |ex| {
                try self.sangria(nivel);
                try self.genExpr(ex);
                try self.e(";\n");
            },
            .retornar => |maybe| {
                try self.sangria(nivel);
                try self.e("return ");
                if (maybe) |ex| try self.genExpr(ex) else try self.e("nulo()");
                try self.e(";\n");
            },
            .romper => {
                try self.sangria(nivel);
                try self.e("break;\n");
            },
            .continuar => {
                try self.sangria(nivel);
                try self.e("continue;\n");
            },
            .si => |si| {
                for (si.ramas, 0..) |r, i| {
                    try self.sangria(nivel);
                    try self.e(if (i == 0) "if (as_bool(" else "else if (as_bool(");
                    try self.genExpr(r.condicion);
                    try self.e(")) {\n");
                    try self.genBloque(r.cuerpo, nivel + 1);
                    try self.sangria(nivel);
                    try self.e("}\n");
                }
                if (si.sino) |c| {
                    try self.sangria(nivel);
                    try self.e("else {\n");
                    try self.genBloque(c, nivel + 1);
                    try self.sangria(nivel);
                    try self.e("}\n");
                }
            },
            .mientras => |m| {
                try self.sangria(nivel);
                try self.e("while (as_bool(");
                try self.genExpr(m.condicion);
                try self.e(")) {\n");
                try self.genBloque(m.cuerpo, nivel + 1);
                try self.sangria(nivel);
                try self.e("}\n");
            },
            .funcion => return self.noSoportado("las funciones anidadas aún no se compilan", .{}),
            .para => return self.noSoportado("'para' aún no se compila (usá 'mientras' o 'alma ejecutar')", .{}),
            .estructura, .modelo => return self.noSoportado("'estructura'/'modelo' aún no se compilan (usá 'alma ejecutar')", .{}),
            .importar => return self.noSoportado("los módulos aún no se compilan (usá 'alma ejecutar')", .{}),
            .intentar, .lanzar => return self.noSoportado("el manejo de errores aún no se compila (usá 'alma ejecutar')", .{}),
            .hilo => return self.noSoportado("'hilo' aún no se compila (usá 'alma ejecutar')", .{}),
        }
    }

    // — Expresiones —

    fn genExpr(self: *Gen, ex: *const Expr) Error!void {
        switch (ex.*) {
            .literal_entero => |s| {
                try self.e("ent(");
                try self.emitNumero(s);
                try self.e(")");
            },
            .literal_decimal => |s| {
                try self.e("dec(");
                try self.emitNumero(s);
                try self.e(")");
            },
            .literal_texto => |s| {
                try self.e("txt(");
                try self.emitCadena(s);
                try self.e(")");
            },
            .literal_bool => |b| try self.e(if (b) "logv(true)" else "logv(false)"),
            .literal_nulo => try self.e("nulo()"),
            .identificador => |n| try self.emitNombre("av_", n),
            .unaria => |u| try self.genUnaria(u),
            .binaria => |b| try self.genBinaria(b),
            .llamada => |l| try self.genLlamada(l),
            .acceso => return self.noSoportado("el acceso a miembros aún no se compila", .{}),
            .lista => return self.noSoportado("las listas aún no se compilan (usá 'alma ejecutar')", .{}),
            .diccionario => return self.noSoportado("los diccionarios aún no se compilan (usá 'alma ejecutar')", .{}),
            .indice => return self.noSoportado("la indexación aún no se compila", .{}),
        }
    }

    fn genUnaria(self: *Gen, u: Expr.Unaria) Error!void {
        switch (u.op) {
            .menos => {
                try self.e("alma_neg(");
                try self.genExpr(u.operando);
                try self.e(")");
            },
            .no_logico => {
                try self.e("alma_no(");
                try self.genExpr(u.operando);
                try self.e(")");
            },
            .kw_esperar => try self.genExpr(u.operando), // esperar sobre un valor = identidad
            else => return self.noSoportado("operador unario no soportado al compilar", .{}),
        }
    }

    fn genBinaria(self: *Gen, b: Expr.Binaria) Error!void {
        // Lógicos: inline para preservar el cortocircuito de C.
        if (b.op == .y_logico or b.op == .o_logico) {
            try self.e("logv(as_bool(");
            try self.genExpr(b.izq);
            try self.e(if (b.op == .y_logico) ") && as_bool(" else ") || as_bool(");
            try self.genExpr(b.der);
            try self.e("))");
            return;
        }
        const fn_name = switch (b.op) {
            .mas => "alma_mas",
            .menos => "alma_menos",
            .por => "alma_por",
            .entre => "alma_entre",
            .modulo => "alma_modulo",
            .menor => "alma_menor",
            .mayor => "alma_mayor",
            .menor_igual => "alma_menor_ig",
            .mayor_igual => "alma_mayor_ig",
            .igual => "alma_igual",
            .distinto => "alma_distinto",
            else => return self.noSoportado("operador binario no soportado al compilar", .{}),
        };
        try self.e(fn_name);
        try self.e("(");
        try self.genExpr(b.izq);
        try self.e(", ");
        try self.genExpr(b.der);
        try self.e(")");
    }

    fn genLlamada(self: *Gen, l: Expr.Llamada) Error!void {
        if (l.callee.* != .identificador) return self.noSoportado("solo se pueden compilar llamadas a funciones con nombre", .{});
        const nombre = l.callee.identificador;

        if (std.mem.eql(u8, nombre, "imprimir")) {
            const cab = try std.fmt.allocPrint(self.gpa, "alma_imprimir({d}", .{l.args.len});
            defer self.gpa.free(cab);
            try self.e(cab);
            for (l.args) |arg| {
                try self.e(", ");
                try self.genExpr(arg);
            }
            try self.e(")");
            return;
        }
        if (std.mem.eql(u8, nombre, "texto")) {
            if (l.args.len != 1) return self.noSoportado("texto() espera 1 argumento", .{});
            try self.e("alma_texto(");
            try self.genExpr(l.args[0]);
            try self.e(")");
            return;
        }
        for (builtins_no_soportados) |b| {
            if (std.mem.eql(u8, nombre, b)) return self.noSoportado("'{s}' aún no se compila (usá 'alma ejecutar')", .{nombre});
        }

        // Llamada a función de usuario.
        try self.emitNombre("af_", nombre);
        try self.e("(");
        for (l.args, 0..) |arg, i| {
            if (i > 0) try self.e(", ");
            try self.genExpr(arg);
        }
        try self.e(")");
    }
};

fn generarPrograma(self: *Gen, programa: []const Stmt) Error!void {
    try self.e(PRELUDIO);

    var hay_principal = false;
    for (programa) |*s| {
        switch (s.dato) {
            .funcion => |*f| {
                try self.genFirma(f);
                try self.e(";\n");
                if (std.mem.eql(u8, f.nombre, "principal")) hay_principal = true;
            },
            .importar => {}, // se ignora al compilar; usar stdlib dará error más abajo
            else => {
                self.diag = "al compilar, todo el código debe estar dentro de funciones (con una función principal())";
                return Error.NoSoportado;
            },
        }
    }
    try self.e("\n");
    for (programa) |*s| {
        switch (s.dato) {
            .funcion => |*f| try self.genFuncion(f),
            else => {},
        }
    }

    if (!hay_principal) {
        self.diag = "falta la función principal() para compilar";
        return Error.NoSoportado;
    }
    try self.e("int main(void){ af_principal(); return 0; }\n");
}

/// Genera el código C del programa. Si algo no se soporta, `fuente_c` es null y `diag`
/// explica por qué. Solo `OutOfMemory` se propaga como error de Zig.
pub fn generar(gpa: std.mem.Allocator, programa: []const Stmt) error{OutOfMemory}!Resultado {
    var g = Gen{ .gpa = gpa };
    generarPrograma(&g, programa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSoportado => {
            g.out.deinit(gpa);
            return .{ .diag = g.diag orelse "construcción no soportada" };
        },
    };
    return .{ .fuente_c = try g.out.toOwnedSlice(gpa) };
}

// — Pruebas —

test "genera C para un programa simple" {
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

    try std.testing.expect(std.mem.indexOf(u8, c, "Val af_doble(Val)") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "af_principal()") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "int main(void)") != null);
}
