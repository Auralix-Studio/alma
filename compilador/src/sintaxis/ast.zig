//! ast.zig — Árbol de Sintaxis Abstracta (AST) del lenguaje Alma.
//! Contrato: docs/especificacion/02-gramatica.md
//!
//! Los nodos hijos se guardan como punteros/slices asignados en la arena del parser.
//! `escribirPrograma` serializa el AST a una S-expresión legible (para tests y debug).

const std = @import("std");
const tk = @import("../lexico/token.zig");
const TipoToken = tk.TipoToken;

/// Posición en el código fuente (base 1). Se adjunta a cada sentencia para
/// producir diagnósticos con línea/columna.
pub const Pos = struct { linea: usize = 0, columna: usize = 0, archivo: ?[]const u8 = null };

/// Adjunta el archivo del parser a todos los bloques, incluidos métodos.
pub fn asignarArchivo(stmts: []Stmt, archivo: []const u8) void {
    for (stmts) |*s| {
        s.pos.archivo = archivo;
        switch (s.dato) {
            .funcion => |f| asignarArchivo(f.cuerpo, archivo),
            .modelo => |m| for (m.metodos) |metodo| {
                asignarArchivo(metodo.cuerpo, archivo);
            },
            .si => |sif| {
                for (sif.ramas) |r| asignarArchivo(r.cuerpo, archivo);
                if (sif.sino) |c| asignarArchivo(c, archivo);
            },
            .mientras => |m| asignarArchivo(m.cuerpo, archivo),
            .para => |p| asignarArchivo(p.cuerpo, archivo),
            .intentar => |t| {
                asignarArchivo(t.cuerpo, archivo);
                asignarArchivo(t.captura, archivo);
            },
            else => {},
        }
    }
}

// — Expresiones —

pub const Expr = union(enum) {
    literal_entero: []const u8,
    literal_decimal: []const u8,
    literal_texto: []const u8,
    literal_bool: bool,
    literal_nulo,
    identificador: []const u8,
    unaria: Unaria,
    binaria: Binaria,
    llamada: Llamada,
    acceso: Acceso,
    lista: []*Expr,
    indice: Indice,
    diccionario: []ParClaveValor,

    pub const Unaria = struct { op: TipoToken, operando: *Expr };
    pub const Binaria = struct { op: TipoToken, izq: *Expr, der: *Expr };
    pub const Llamada = struct { callee: *Expr, args: []*Expr };
    pub const Acceso = struct { objeto: *Expr, campo: []const u8 };
    pub const Indice = struct { objeto: *Expr, indice: *Expr };
    pub const ParClaveValor = struct { clave: *Expr, valor: *Expr };
};

// — Sentencias —

pub const Param = struct { nombre: []const u8, tipo: ?[]const u8 };
pub const Campo = struct { nombre: []const u8, tipo: []const u8 };
pub const RamaSi = struct { condicion: *Expr, cuerpo: []Stmt };

pub const Stmt = struct {
    pos: Pos = .{},
    dato: Dato,

    pub const Dato = union(enum) {
        declaracion: Declaracion,
        asignacion: Asignacion,
        expresion: *Expr,
        retornar: ?*Expr,
        romper,
        continuar,
        si: Si,
        mientras: Mientras,
        para: Para,
        funcion: Funcion,
        estructura: Estructura,
        modelo: Modelo,
        importar: Importar,
        intentar: Intentar,
        lanzar: *Expr,
        hilo: *Expr,
    };

    pub const Declaracion = struct { nombre: []const u8, tipo: ?[]const u8, fijo: bool, valor: *Expr, exportar: bool = false };
    pub const Intentar = struct { cuerpo: []Stmt, variable: []const u8, captura: []Stmt };
    pub const Asignacion = struct { objetivo: *Expr, valor: *Expr };
    pub const Si = struct { ramas: []RamaSi, sino: ?[]Stmt };
    pub const Mientras = struct { condicion: *Expr, cuerpo: []Stmt };
    pub const Para = struct { variable: []const u8, iterable: *Expr, cuerpo: []Stmt };
    pub const Funcion = struct {
        nombre: []const u8,
        params: []Param,
        retorno: ?[]const u8,
        cuerpo: []Stmt,
        exportar: bool = false,
        asincrona: bool = false,
    };
    pub const Estructura = struct { nombre: []const u8, campos: []Campo, exportar: bool = false };
    pub const Modelo = struct { nombre: []const u8, campos: []Campo, metodos: []Funcion, exportar: bool = false };
    pub const Importar = struct { que: []const u8, desde: ?[]const u8 };
};

// — Serialización a S-expresión —

const Buffer = std.ArrayListUnmanaged(u8);
const Error = std.mem.Allocator.Error; // error explícito: rompe el bucle de inferencia mutua

/// Serializa el programa a una S-expresión. El llamador libera el slice devuelto.
pub fn escribirPrograma(alloc: std.mem.Allocator, programa: []const Stmt) Error![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "(programa");
    for (programa) |s| {
        try out.append(alloc, ' ');
        try escStmt(alloc, &out, s);
    }
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn escBloque(alloc: std.mem.Allocator, out: *Buffer, cuerpo: []const Stmt) Error!void {
    try out.appendSlice(alloc, "(bloque");
    for (cuerpo) |s| {
        try out.append(alloc, ' ');
        try escStmt(alloc, out, s);
    }
    try out.append(alloc, ')');
}

fn escStmt(alloc: std.mem.Allocator, out: *Buffer, s: Stmt) Error!void {
    switch (s.dato) {
        .declaracion => |d| {
            try out.appendSlice(alloc, if (d.fijo) "(fijo " else "(declarar ");
            try out.appendSlice(alloc, d.nombre);
            if (d.tipo) |t| {
                try out.appendSlice(alloc, " :");
                try out.appendSlice(alloc, t);
            }
            try out.append(alloc, ' ');
            try escExpr(alloc, out, d.valor);
            try out.append(alloc, ')');
        },
        .asignacion => |a| {
            try out.appendSlice(alloc, "(asignar ");
            try escExpr(alloc, out, a.objetivo);
            try out.append(alloc, ' ');
            try escExpr(alloc, out, a.valor);
            try out.append(alloc, ')');
        },
        .expresion => |e| {
            try out.appendSlice(alloc, "(expr ");
            try escExpr(alloc, out, e);
            try out.append(alloc, ')');
        },
        .retornar => |maybe| {
            try out.appendSlice(alloc, "(retornar");
            if (maybe) |e| {
                try out.append(alloc, ' ');
                try escExpr(alloc, out, e);
            }
            try out.append(alloc, ')');
        },
        .romper => try out.appendSlice(alloc, "(romper)"),
        .continuar => try out.appendSlice(alloc, "(continuar)"),
        .si => |si| {
            try out.appendSlice(alloc, "(si");
            for (si.ramas) |r| {
                try out.appendSlice(alloc, " (rama ");
                try escExpr(alloc, out, r.condicion);
                try out.append(alloc, ' ');
                try escBloque(alloc, out, r.cuerpo);
                try out.append(alloc, ')');
            }
            if (si.sino) |cuerpo| {
                try out.appendSlice(alloc, " (sino ");
                try escBloque(alloc, out, cuerpo);
                try out.append(alloc, ')');
            }
            try out.append(alloc, ')');
        },
        .mientras => |m| {
            try out.appendSlice(alloc, "(mientras ");
            try escExpr(alloc, out, m.condicion);
            try out.append(alloc, ' ');
            try escBloque(alloc, out, m.cuerpo);
            try out.append(alloc, ')');
        },
        .para => |p| {
            try out.appendSlice(alloc, "(para ");
            try out.appendSlice(alloc, p.variable);
            try out.appendSlice(alloc, " en ");
            try escExpr(alloc, out, p.iterable);
            try out.append(alloc, ' ');
            try escBloque(alloc, out, p.cuerpo);
            try out.append(alloc, ')');
        },
        .funcion => |f| try escFuncion(alloc, out, f),
        .estructura => |e| {
            try out.appendSlice(alloc, "(estructura ");
            try out.appendSlice(alloc, e.nombre);
            for (e.campos) |c| try escCampo(alloc, out, c);
            try out.append(alloc, ')');
        },
        .modelo => |m| {
            try out.appendSlice(alloc, "(modelo ");
            try out.appendSlice(alloc, m.nombre);
            for (m.campos) |c| try escCampo(alloc, out, c);
            for (m.metodos) |f| {
                try out.append(alloc, ' ');
                try escFuncion(alloc, out, f);
            }
            try out.append(alloc, ')');
        },
        .importar => |imp| {
            try out.appendSlice(alloc, "(importar ");
            try out.appendSlice(alloc, imp.que);
            if (imp.desde) |d| {
                try out.appendSlice(alloc, " desde ");
                try out.appendSlice(alloc, d);
            }
            try out.append(alloc, ')');
        },
        .intentar => |t| {
            try out.appendSlice(alloc, "(intentar ");
            try escBloque(alloc, out, t.cuerpo);
            try out.appendSlice(alloc, " (capturar ");
            try out.appendSlice(alloc, t.variable);
            try out.append(alloc, ' ');
            try escBloque(alloc, out, t.captura);
            try out.appendSlice(alloc, "))");
        },
        .lanzar => |e| {
            try out.appendSlice(alloc, "(lanzar ");
            try escExpr(alloc, out, e);
            try out.append(alloc, ')');
        },
        .hilo => |e| {
            try out.appendSlice(alloc, "(hilo ");
            try escExpr(alloc, out, e);
            try out.append(alloc, ')');
        },
    }
}

fn escCampo(alloc: std.mem.Allocator, out: *Buffer, c: Campo) Error!void {
    try out.appendSlice(alloc, " (campo ");
    try out.appendSlice(alloc, c.nombre);
    try out.appendSlice(alloc, " :");
    try out.appendSlice(alloc, c.tipo);
    try out.append(alloc, ')');
}

fn escFuncion(alloc: std.mem.Allocator, out: *Buffer, f: Stmt.Funcion) Error!void {
    try out.appendSlice(alloc, "(funcion ");
    if (f.exportar) try out.appendSlice(alloc, "exportar ");
    if (f.asincrona) try out.appendSlice(alloc, "asincrona ");
    try out.appendSlice(alloc, f.nombre);
    try out.appendSlice(alloc, " (params");
    for (f.params) |p| {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, p.nombre);
        if (p.tipo) |t| {
            try out.appendSlice(alloc, ":");
            try out.appendSlice(alloc, t);
        }
    }
    try out.append(alloc, ')');
    if (f.retorno) |r| {
        try out.appendSlice(alloc, " ->");
        try out.appendSlice(alloc, r);
    }
    try out.append(alloc, ' ');
    try escBloque(alloc, out, f.cuerpo);
    try out.append(alloc, ')');
}

fn escExpr(alloc: std.mem.Allocator, out: *Buffer, e: *const Expr) Error!void {
    switch (e.*) {
        .literal_entero => |s| try out.appendSlice(alloc, s),
        .literal_decimal => |s| try out.appendSlice(alloc, s),
        .literal_texto => |s| try out.appendSlice(alloc, s),
        .literal_bool => |b| try out.appendSlice(alloc, if (b) "verdadero" else "falso"),
        .literal_nulo => try out.appendSlice(alloc, "nulo"),
        .identificador => |s| try out.appendSlice(alloc, s),
        .unaria => |u| {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, @tagName(u.op));
            try out.append(alloc, ' ');
            try escExpr(alloc, out, u.operando);
            try out.append(alloc, ')');
        },
        .binaria => |b| {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, @tagName(b.op));
            try out.append(alloc, ' ');
            try escExpr(alloc, out, b.izq);
            try out.append(alloc, ' ');
            try escExpr(alloc, out, b.der);
            try out.append(alloc, ')');
        },
        .llamada => |l| {
            try out.appendSlice(alloc, "(llamar ");
            try escExpr(alloc, out, l.callee);
            for (l.args) |arg| {
                try out.append(alloc, ' ');
                try escExpr(alloc, out, arg);
            }
            try out.append(alloc, ')');
        },
        .acceso => |ac| {
            try out.appendSlice(alloc, "(acceso ");
            try escExpr(alloc, out, ac.objeto);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, ac.campo);
            try out.append(alloc, ')');
        },
        .lista => |elems| {
            try out.appendSlice(alloc, "(lista");
            for (elems) |el| {
                try out.append(alloc, ' ');
                try escExpr(alloc, out, el);
            }
            try out.append(alloc, ')');
        },
        .indice => |ix| {
            try out.appendSlice(alloc, "(indice ");
            try escExpr(alloc, out, ix.objeto);
            try out.append(alloc, ' ');
            try escExpr(alloc, out, ix.indice);
            try out.append(alloc, ')');
        },
        .diccionario => |pares| {
            try out.appendSlice(alloc, "(dicc");
            for (pares) |par| {
                try out.appendSlice(alloc, " (par ");
                try escExpr(alloc, out, par.clave);
                try out.append(alloc, ' ');
                try escExpr(alloc, out, par.valor);
                try out.append(alloc, ')');
            }
            try out.append(alloc, ')');
        },
    }
}
