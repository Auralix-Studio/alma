//! Backend propio Windows x64. Emite instrucciones, importaciones y PE32+.
//! No invoca compilador, ensamblador ni enlazador externos.
//!
//! Disposición del ejecutable: `.text` (código), `.rdata` (importaciones, textos
//! literales deduplicados, bloque de reubicación, UNWIND_INFO y .pdata) y `.data`
//! (contador de llamadas y búfer de salida). Todo el código usa direccionamiento
//! relativo a RIP, por lo que la imagen es reubicable sin entradas de reubicación
//! y se marca con DYNAMIC_BASE/HIGH_ENTROPY_VA (ASLR).
const std = @import("std");
const ir = @import("ir.zig");
const limites = @import("limites.zig");
const Error = error{ OutOfMemory, NoSoportado };
const Lista = std.ArrayListUnmanaged(u8);
/// Destino de una referencia relativa a RIP.
const Destino = union(enum) { codigo: usize, datos: usize, escritura: usize, importacion: usize };
const Parche = struct { pos: usize, destino: Destino };
/// Rango de código con marco estándar (push rbp; mov rbp, rsp; [sondeos]; sub rsp, n).
const Marco = struct { inicio: usize, fin_prologo: usize, fin: usize, tamano: usize };
pub const Resultado = struct { ejecutable: ?[]u8 = null, diag: ?[]const u8 = null };

// Disposición de `.data` (escribible, inicializada a cero por el cargador).
const dato_profundidad = 0; // u64: llamadas activas
const dato_salida_len = 8; // u64: bytes pendientes en el búfer de salida
const dato_salida = 16; // búfer de stdout
const capacidad_salida = 4096;
const tamano_escritura = dato_salida + capacidad_salida;

/// El prólogo sondea cada página del marco (guard page de Windows) y la suma de
/// sondeos y prólogo debe caber en SizeOfProlog (un byte) de UNWIND_INFO.
const marco_maximo = 32 * 4096;

comptime {
    // `cmp rax, imm8` del límite de llamadas.
    std.debug.assert(limites.llamadas < 128);
}

fn poner(comptime T: type, bytes: []u8, offset: usize, valor: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], valor, .little);
}
fn alineado(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

/// Registros IR mencionados por una instrucción (sin contar argumentos de llamada).
fn registrosFijos(ins: ir.Instr, buf: *[3]ir.Reg) []const ir.Reg {
    switch (ins.dato) {
        .literal => |l| buf[0] = l.dst,
        .copiar => |c| {
            buf[0] = c.dst;
            buf[1] = c.src;
            return buf[0..2];
        },
        .liberar => |r| buf[0] = r,
        .binaria => |b| {
            buf[0] = b.dst;
            buf[1] = b.izq;
            buf[2] = b.der;
            return buf[0..3];
        },
        .unaria => |u| {
            buf[0] = u.dst;
            buf[1] = u.src;
            return buf[0..2];
        },
        .llamar => |l| buf[0] = l.dst,
        .condicional => |c| buf[0] = c.src,
        .retornar => |r| buf[0] = r,
        .etiqueta, .saltar => return buf[0..0],
    }
    return buf[0..1];
}

const Emisor = struct {
    a: std.mem.Allocator,
    codigo: Lista = .empty,
    datos: Lista = .empty,
    etiquetas: std.ArrayListUnmanaged(usize) = .empty,
    parches: std.ArrayListUnmanaged(Parche) = .empty,
    marcos: std.ArrayListUnmanaged(Marco) = .empty,
    /// Textos ya emitidos en `.rdata` (contenido → posición): sin duplicados.
    textos: std.StringHashMapUnmanaged(usize) = .empty,
    /// Ranura de stack de cada registro IR de la función en curso.
    ranuras: []usize = &.{},
    funciones: []usize = &.{},
    escribir: usize = 0,
    escribir_salida: usize = 0,
    escribir_error: usize = 0,
    vaciar: usize = 0,
    imprimir: usize = 0,
    error_tipo: usize = 0,
    error_cero: usize = 0,
    error_overflow: usize = 0,
    error_variable: usize = 0,
    error_pila: usize = 0,
    salir_error: usize = 0,
    diag: ?[]const u8 = null,

    fn fallo(self: *Emisor, mensaje: []const u8) Error {
        self.diag = mensaje;
        return error.NoSoportado;
    }
    fn bytes(self: *Emisor, s: []const u8) Error!void {
        try self.codigo.appendSlice(self.a, s);
    }
    fn emitir_u32(self: *Emisor, n: u32) Error!void {
        var b: [4]u8 = undefined;
        poner(u32, &b, 0, n);
        try self.bytes(&b);
    }
    fn emitir_i32(self: *Emisor, n: i32) Error!void {
        try self.emitir_u32(@bitCast(n));
    }
    fn emitir_u64(self: *Emisor, n: u64) Error!void {
        var b: [8]u8 = undefined;
        poner(u64, &b, 0, n);
        try self.bytes(&b);
    }
    fn label(self: *Emisor) Error!usize {
        const n = self.etiquetas.items.len;
        try self.etiquetas.append(self.a, 0);
        return n;
    }
    fn marcar(self: *Emisor, n: usize) void {
        self.etiquetas.items[n] = self.codigo.items.len;
    }
    /// Emite `op` seguido de un disp32 relativo a RIP que termina la instrucción.
    fn referencia(self: *Emisor, op: []const u8, destino: Destino) Error!void {
        try self.bytes(op);
        try self.parches.append(self.a, .{ .pos = self.codigo.items.len, .destino = destino });
        try self.emitir_u32(0);
    }
    fn salto(self: *Emisor, cc: ?u8, destino: usize) Error!void {
        if (cc) |c| try self.referencia(&.{ 0x0f, c }, .{ .codigo = destino }) else try self.referencia(&.{0xe9}, .{ .codigo = destino });
    }
    fn call(self: *Emisor, destino: usize) Error!void {
        try self.referencia(&.{0xe8}, .{ .codigo = destino });
    }
    /// `call destino` si se cumple `cc` (segundo byte de la forma larga 0F 8x).
    /// Las rutinas de error se llaman (no se saltan) para que el unwinder vea un
    /// marco válido: tienen prólogo propio y entrada en .pdata.
    fn llamadaSi(self: *Emisor, cc: u8, destino: usize) Error!void {
        try self.bytes(&[_]u8{ 0x70 + ((cc - 0x80) ^ 1), 5 }); // jcc inverso corto sobre el call
        try self.call(destino);
    }
    fn api(self: *Emisor, id: usize) Error!void {
        try self.referencia(&.{ 0xff, 0x15 }, .{ .importacion = id });
    }
    fn texto(self: *Emisor, s: []const u8) Error!usize {
        if (self.textos.get(s)) |pos| return pos;
        while (self.datos.items.len % 8 != 0) try self.datos.append(self.a, 0);
        const pos = self.datos.items.len;
        var n: [8]u8 = undefined;
        poner(u64, &n, 0, @intCast(s.len));
        try self.datos.appendSlice(self.a, &n);
        try self.datos.appendSlice(self.a, s);
        try self.textos.put(self.a, try self.a.dupe(u8, s), pos);
        return pos;
    }
    fn textoRaw(self: *Emisor, s: []const u8) Error!void {
        try self.textoDestino(s, self.escribir);
    }
    fn textoDestino(self: *Emisor, s: []const u8, destino: usize) Error!void {
        const pos = try self.texto(s);
        try self.referencia(&.{ 0x48, 0x8d, 0x0d }, .{ .datos = pos + 8 }); // lea rcx
        try self.bytes(&.{0xba});
        try self.emitir_u32(@intCast(s.len)); // mov edx
        try self.call(destino);
    }
    /// push rbp; mov rbp, rsp; sondeos de página; sub rsp, n. Devuelve el marco
    /// sin cerrar (se completa con `cerrarMarco`).
    fn prologo(self: *Emisor, n: usize) Error!Marco {
        if (n > marco_maximo or n % 16 != 0) return self.fallo("marco de función no admitido por el backend propio");
        const inicio = self.codigo.items.len;
        try self.bytes(&.{ 0x55, 0x48, 0x89, 0xe5 });
        var pagina: usize = 4096;
        while (pagina <= n) : (pagina += 4096) {
            try self.bytes(&.{ 0x85, 0x84, 0x24 }); // test [rsp - pagina], eax
            try self.emitir_i32(-@as(i32, @intCast(pagina)));
        }
        try self.bytes(&.{ 0x48, 0x81, 0xec });
        try self.emitir_u32(@intCast(n));
        return .{ .inicio = inicio, .fin_prologo = self.codigo.items.len, .fin = 0, .tamano = n };
    }
    fn epilogo(self: *Emisor, n: usize) Error!void {
        try self.bytes(&.{ 0x48, 0x81, 0xc4 });
        try self.emitir_u32(@intCast(n));
        try self.bytes(&.{ 0x5d, 0xc3 });
    }
    fn cerrarMarco(self: *Emisor, m: Marco) Error!void {
        var completo = m;
        completo.fin = self.codigo.items.len;
        try self.marcos.append(self.a, completo);
    }
    fn desplazamientoRanura(ranura: usize) i32 {
        return -@as(i32, @intCast((ranura + 1) * 16));
    }
    fn off(self: *const Emisor, r: ir.Reg) i32 {
        return desplazamientoRanura(self.ranuras[r]);
    }
    fn cargar(self: *Emisor, r: ir.Reg) Error!void {
        try self.bytes(&.{ 0x48, 0x8b, 0x85 });
        try self.emitir_i32(self.off(r)); // rax dato
        try self.bytes(&.{ 0x48, 0x8b, 0x95 });
        try self.emitir_i32(self.off(r) + 8); // rdx etiqueta
    }
    fn guardarEn(self: *Emisor, desplazamiento: i32) Error!void {
        try self.bytes(&.{ 0x48, 0x89, 0x85 });
        try self.emitir_i32(desplazamiento);
        try self.bytes(&.{ 0x48, 0x89, 0x95 });
        try self.emitir_i32(desplazamiento + 8);
    }
    fn guardar(self: *Emisor, r: ir.Reg) Error!void {
        try self.guardarEn(self.off(r));
    }
    fn tipo(self: *Emisor, r: ir.Reg, t: u8) Error!void {
        try self.bytes(&.{ 0x48, 0x83, 0xbd });
        try self.emitir_i32(self.off(r) + 8);
        try self.bytes(&.{t});
        try self.llamadaSi(0x85, self.error_tipo);
    }
    fn tag(self: *Emisor, t: u32) Error!void {
        try self.bytes(&.{0xba});
        try self.emitir_u32(t);
    }

    // Inferencia conservadora de tipos posibles, interprocedimental y monótona.
    // Los textos son inmutables/literales: no hay asignaciones dinámicas en este backend.
    fn validar(self: *Emisor, p: *const ir.Programa) Error!void {
        const tipos = try self.a.alloc([]u8, p.funciones.len);
        const retornos = try self.a.alloc(u8, p.funciones.len);
        @memset(retornos, 0);
        for (p.funciones, 0..) |f, i| {
            tipos[i] = try self.a.alloc(u8, f.registros);
            @memset(tipos[i], 0);
        }
        var cambio = true;
        while (cambio) {
            cambio = false;
            for (p.funciones, 0..) |f, fi| for (f.instrucciones) |ins| {
                var destino: ?usize = null;
                var t: u8 = 0;
                switch (ins.dato) {
                    .literal => |l| {
                        destino = l.dst;
                        t = switch (l.valor) {
                            .entero => 1,
                            .logico => 2,
                            .texto => 4,
                            .nulo => 8,
                            .decimal => return self.fallo("el backend propio todavía no admite decimales"),
                        };
                    },
                    .copiar => |c| {
                        destino = c.dst;
                        t = tipos[fi][c.src];
                    },
                    .binaria => |b| {
                        destino = b.dst;
                        t = switch (b.op) {
                            .sumar, .restar, .multiplicar, .dividir, .resto => 1,
                            else => 2,
                        };
                    },
                    .unaria => |u| {
                        destino = u.dst;
                        t = switch (u.op) {
                            .negar => 1,
                            .no, .logico => 2,
                            .identidad => tipos[fi][u.src],
                        };
                    },
                    .llamar => |l| {
                        destino = l.dst;
                        switch (l.destino) {
                            .imprimir => t = 8,
                            .texto => return self.fallo("texto() requiere el backend C por ahora; el backend propio admite textos literales"),
                            .funcion => |id| {
                                t = retornos[id];
                                for (l.args, 0..) |arg, i| {
                                    const previo = tipos[id][i];
                                    tipos[id][i] |= tipos[fi][arg];
                                    cambio = cambio or previo != tipos[id][i];
                                }
                            },
                        }
                    },
                    .retornar => |r| {
                        const previo = retornos[fi];
                        retornos[fi] |= tipos[fi][r];
                        cambio = cambio or previo != retornos[fi];
                    },
                    else => {},
                }
                if (destino) |d| {
                    const previo = tipos[fi][d];
                    tipos[fi][d] |= t;
                    cambio = cambio or previo != tipos[fi][d];
                }
            };
        }
        for (p.funciones, 0..) |f, fi| for (f.instrucciones) |ins| {
            if (ins.dato == .binaria) {
                const b = ins.dato.binaria;
                if (b.op == .sumar and (tipos[fi][b.izq] & tipos[fi][b.der] & 4) != 0)
                    return self.fallo("la concatenación de textos todavía requiere el backend C");
            }
        };
    }

    /// Asigna una ranura de 16 bytes a cada registro IR. Las variables tienen
    /// ranura propia; los temporales comparten ranuras cuando sus intervalos
    /// [primera mención, última mención] no se solapan. Los temporales nunca viven
    /// entre iteraciones (se definen y se consumen dentro de una sentencia), así
    /// que el intervalo lineal es conservador también dentro de bucles.
    /// Devuelve la cantidad de ranuras.
    fn asignarRanuras(self: *Emisor, f: ir.Funcion) Error!usize {
        const n = f.registros;
        const primero = try self.a.alloc(usize, n);
        const ultimo = try self.a.alloc(usize, n);
        @memset(primero, std.math.maxInt(usize));
        @memset(ultimo, 0);
        for (f.instrucciones, 0..) |ins, i| {
            var buf: [3]ir.Reg = undefined;
            for (registrosFijos(ins, &buf)) |r| {
                primero[r] = @min(primero[r], i);
                ultimo[r] = @max(ultimo[r], i);
            }
            if (ins.dato == .llamar) for (ins.dato.llamar.args) |r| {
                primero[r] = @min(primero[r], i);
                ultimo[r] = @max(ultimo[r], i);
            };
        }
        self.ranuras = try self.a.alloc(usize, n);
        var siguiente: usize = 0;
        for (0..n) |r| if (f.variables[r]) {
            self.ranuras[r] = siguiente;
            siguiente += 1;
        };
        // Temporales nunca mencionados (no ocurre hoy) reciben una ranura propia.
        for (0..n) |r| if (!f.variables[r] and primero[r] == std.math.maxInt(usize)) {
            self.ranuras[r] = siguiente;
            siguiente += 1;
        };
        var libres: std.ArrayListUnmanaged(usize) = .empty;
        // Temporales activos ordenados por aparición: se recorren por instrucción.
        var inicio_en: std.ArrayListUnmanaged(std.ArrayListUnmanaged(ir.Reg)) = .empty;
        var fin_en: std.ArrayListUnmanaged(std.ArrayListUnmanaged(ir.Reg)) = .empty;
        try inicio_en.appendNTimes(self.a, .empty, f.instrucciones.len);
        try fin_en.appendNTimes(self.a, .empty, f.instrucciones.len);
        for (0..n) |r| if (!f.variables[r] and primero[r] != std.math.maxInt(usize)) {
            try inicio_en.items[primero[r]].append(self.a, r);
            try fin_en.items[ultimo[r]].append(self.a, r);
        };
        for (0..f.instrucciones.len) |i| {
            // Primero se asignan los que empiezan aquí y luego se liberan los que
            // terminan aquí: un temporal nunca reutiliza la ranura de otro que se
            // lee en la misma instrucción.
            for (inicio_en.items[i].items) |r| {
                if (libres.pop()) |ranura| {
                    self.ranuras[r] = ranura;
                } else {
                    self.ranuras[r] = siguiente;
                    siguiente += 1;
                }
            }
            for (fin_en.items[i].items) |r| try libres.append(self.a, self.ranuras[r]);
        }
        return siguiente;
    }

    fn funcion(self: *Emisor, id: usize, f: ir.Funcion) Error!void {
        var maxargs: usize = 0;
        var maxlabel: usize = 0;
        for (f.instrucciones) |ins| switch (ins.dato) {
            .llamar => |l| {
                maxargs = @max(maxargs, l.args.len);
            },
            .etiqueta => |l| {
                maxlabel = @max(maxlabel, l + 1);
            },
            else => {},
        };
        const nranuras = try self.asignarRanuras(f);
        const frame = (nranuras + maxargs) * 16 + 32;
        if (frame > marco_maximo) return self.fallo("función demasiado grande para el backend propio (marco mayor de 128 KiB)");
        const labels = try self.a.alloc(usize, maxlabel);
        for (labels) |*l| l.* = try self.label();
        self.marcar(self.funciones[id]);
        const m = try self.prologo(frame);
        // Ranuras inicialmente indefinidas (tag=4).
        try self.bytes(&.{ 0x31, 0xc0 });
        try self.tag(4);
        for (0..nranuras) |ranura| try self.guardarEn(desplazamientoRanura(ranura));
        for (0..f.parametros) |r| {
            try self.bytes(&.{ 0x48, 0x8b, 0x81 });
            try self.emitir_u32(@intCast(r * 16));
            try self.bytes(&.{ 0x48, 0x8b, 0x91 });
            try self.emitir_u32(@intCast(r * 16 + 8));
            try self.guardar(r);
        }
        // Límite de llamadas activas, igual que el intérprete y el runtime C.
        try self.referencia(&.{ 0x48, 0x8b, 0x05 }, .{ .escritura = dato_profundidad }); // mov rax, [prof]
        try self.bytes(&.{ 0x48, 0xff, 0xc0 }); // inc rax
        try self.referencia(&.{ 0x48, 0x89, 0x05 }, .{ .escritura = dato_profundidad }); // mov [prof], rax
        try self.bytes(&[_]u8{ 0x48, 0x83, 0xf8, limites.llamadas }); // cmp rax, límite
        try self.llamadaSi(0x87, self.error_pila); // ja
        const base: i32 = -@as(i32, @intCast((nranuras + maxargs) * 16));
        for (f.instrucciones) |ins| switch (ins.dato) {
            .literal => |l| {
                switch (l.valor) {
                    .entero => |n| {
                        try self.bytes(&.{ 0x48, 0xb8 });
                        try self.emitir_u64(@bitCast(n));
                        try self.tag(1);
                    },
                    .logico => |b| {
                        try self.bytes(&.{0xb8});
                        try self.emitir_u32(@intFromBool(b));
                        try self.tag(2);
                    },
                    .nulo => {
                        try self.bytes(&.{ 0x31, 0xc0 });
                        try self.tag(0);
                    },
                    .texto => |s| {
                        const pos = try self.texto(s);
                        try self.referencia(&.{ 0x48, 0x8d, 0x05 }, .{ .datos = pos });
                        try self.tag(3);
                    },
                    .decimal => return self.fallo("el backend propio todavía no admite decimales"),
                }
                try self.guardar(l.dst);
            },
            .copiar => |c| {
                try self.cargar(c.src);
                try self.bytes(&.{ 0x83, 0xfa, 0x04 });
                try self.llamadaSi(0x84, self.error_variable);
                try self.guardar(c.dst);
            },
            .liberar => |r| {
                try self.bytes(&.{ 0x31, 0xc0 });
                try self.tag(0);
                try self.guardar(r);
            },
            .binaria => |b| try self.binaria(b.dst, b.izq, b.der, b.op),
            .unaria => |u| {
                if (u.op == .negar) try self.tipo(u.src, 1);
                if (u.op == .no or u.op == .logico) try self.tipo(u.src, 2);
                try self.cargar(u.src);
                switch (u.op) {
                    .negar => {
                        try self.bytes(&.{ 0x48, 0xf7, 0xd8 });
                        try self.llamadaSi(0x80, self.error_overflow);
                    },
                    .no => try self.bytes(&.{ 0x48, 0x83, 0xf0, 0x01 }),
                    .logico, .identidad => {},
                }
                try self.guardar(u.dst);
            },
            .llamar => |l| {
                switch (l.destino) {
                    .imprimir => {
                        for (l.args, 0..) |r, i| {
                            if (i != 0) try self.textoRaw(" ");
                            try self.cargar(r);
                            try self.bytes(&.{ 0x48, 0x89, 0xc1 });
                            try self.call(self.imprimir);
                        }
                        try self.textoRaw("\n");
                        try self.bytes(&.{ 0x31, 0xc0 });
                        try self.tag(0);
                    },
                    .funcion => |fid| {
                        for (l.args, 0..) |r, i| {
                            try self.cargar(r);
                            try self.guardarEn(base + @as(i32, @intCast(i * 16)));
                        }
                        try self.bytes(&.{ 0x48, 0x8d, 0x8d });
                        try self.emitir_i32(base);
                        try self.call(self.funciones[fid]);
                    },
                    .texto => return self.fallo("texto() requiere el backend C por ahora; el backend propio admite textos literales"),
                }
                try self.guardar(l.dst);
            },
            .etiqueta => |l| self.marcar(labels[l]),
            .saltar => |l| try self.salto(null, labels[l]),
            .condicional => |c| {
                try self.tipo(c.src, 2);
                try self.cargar(c.src);
                try self.bytes(&.{ 0x48, 0x85, 0xc0 });
                try self.salto(if (c.cuando) 0x85 else 0x84, labels[c.etiqueta]);
            },
            .retornar => |r| {
                try self.cargar(r);
                try self.referencia(&.{ 0x48, 0xff, 0x0d }, .{ .escritura = dato_profundidad }); // dec [prof]
                try self.epilogo(frame);
            },
        };
        try self.cerrarMarco(m);
    }

    fn binaria(self: *Emisor, dst: ir.Reg, izq: ir.Reg, der: ir.Reg, op: ir.Binaria) Error!void {
        if (op == .igual or op == .distinto) {
            const diferente = try self.label();
            const iguales = try self.label();
            const fin = try self.label();
            try self.cargar(izq);
            try self.bytes(&.{ 0x48, 0x3b, 0x95 });
            try self.emitir_i32(self.off(der) + 8);
            try self.salto(0x85, diferente);
            try self.bytes(&.{ 0x83, 0xfa, 0x03 });
            const simple = try self.label();
            try self.salto(0x85, simple);
            // Igualdad de texto por longitud y bytes, no por dirección.
            try self.bytes(&.{ 0x4c, 0x8b, 0x85 });
            try self.emitir_i32(self.off(der)); // r8 texto derecho
            try self.bytes(&.{ 0x48, 0x8b, 0x10, 0x49, 0x3b, 0x10 });
            try self.salto(0x85, diferente);
            try self.bytes(&.{ 0x31, 0xc9 });
            const bucle = try self.label();
            self.marcar(bucle);
            try self.bytes(&.{ 0x48, 0x39, 0xd1 });
            try self.salto(0x84, iguales);
            try self.bytes(&.{ 0x44, 0x8a, 0x4c, 0x08, 0x08, 0x45, 0x3a, 0x4c, 0x08, 0x08 });
            try self.salto(0x85, diferente);
            try self.bytes(&.{ 0x48, 0xff, 0xc1 });
            try self.salto(null, bucle);
            self.marcar(simple);
            try self.bytes(&.{ 0x48, 0x3b, 0x85 });
            try self.emitir_i32(self.off(der));
            try self.salto(0x85, diferente);
            self.marcar(iguales);
            try self.bytes(&.{0xb8});
            try self.emitir_u32(if (op == .igual) 1 else 0);
            try self.salto(null, fin);
            self.marcar(diferente);
            try self.bytes(&.{0xb8});
            try self.emitir_u32(if (op == .igual) 0 else 1);
            self.marcar(fin);
            try self.tag(2);
            try self.guardar(dst);
            return;
        }
        try self.tipo(izq, 1);
        try self.tipo(der, 1);
        try self.cargar(izq);
        try self.bytes(&.{ 0x48, 0x8b, 0x8d });
        try self.emitir_i32(self.off(der)); // rcx derecho
        switch (op) {
            .sumar => {
                try self.bytes(&.{ 0x48, 0x01, 0xc8 });
                try self.llamadaSi(0x80, self.error_overflow);
            },
            .restar => {
                try self.bytes(&.{ 0x48, 0x29, 0xc8 });
                try self.llamadaSi(0x80, self.error_overflow);
            },
            .multiplicar => {
                try self.bytes(&.{ 0x48, 0x0f, 0xaf, 0xc1 });
                try self.llamadaSi(0x80, self.error_overflow);
            },
            .dividir, .resto => {
                try self.bytes(&.{ 0x48, 0x85, 0xc9 });
                try self.llamadaSi(0x84, self.error_cero);
                const normal = try self.label();
                const fin = try self.label();
                try self.bytes(&.{ 0x48, 0x83, 0xf9, 0xff });
                try self.salto(0x85, normal);
                try self.bytes(&.{ 0x48, 0xba });
                try self.emitir_u64(0x8000000000000000);
                try self.bytes(&.{ 0x48, 0x39, 0xd0 });
                try self.salto(0x85, normal);
                if (op == .dividir) try self.call(self.error_overflow) else {
                    try self.bytes(&.{ 0x31, 0xc0 });
                    try self.salto(null, fin);
                }
                self.marcar(normal);
                try self.bytes(&.{ 0x48, 0x99, 0x48, 0xf7, 0xf9 });
                if (op == .resto) try self.bytes(&.{ 0x48, 0x89, 0xd0 });
                self.marcar(fin);
            },
            .menor, .mayor, .menor_igual, .mayor_igual => {
                const cc: u8 = switch (op) {
                    .menor => 0x9c,
                    .mayor => 0x9f,
                    .menor_igual => 0x9e,
                    else => 0x9d, // mayor_igual
                };
                try self.bytes(&.{ 0x48, 0x39, 0xc8, 0x0f, cc, 0xc0, 0x0f, 0xb6, 0xc0 });
            },
            .igual, .distinto => return self.fallo("operador binario mal encaminado en el backend propio"),
        }
        try self.tag(switch (op) {
            .menor, .mayor, .menor_igual, .mayor_igual => 2,
            else => 1,
        });
        try self.guardar(dst);
    }

    /// WriteFile directo sobre un handle estándar (rcx = datos, rdx = longitud).
    fn rutinaEscribir(self: *Emisor, destino: usize, handle: i32) Error!void {
        self.marcar(destino);
        const m = try self.prologo(64);
        // Preservar puntero y longitud alrededor de GetStdHandle.
        try self.bytes(&.{ 0x48, 0x89, 0x4d, 0xf8, 0x48, 0x89, 0x55, 0xf0, 0xb9 });
        try self.emitir_u32(@bitCast(handle));
        try self.api(0);
        try self.bytes(&.{ 0x48, 0x89, 0xc1, 0x48, 0x8b, 0x55, 0xf8, 0x4c, 0x8b, 0x45, 0xf0, 0x4c, 0x8d, 0x4d, 0xe8 });
        try self.bytes(&.{ 0x48, 0xc7, 0x44, 0x24, 0x20, 0, 0, 0, 0 });
        try self.api(1);
        try self.bytes(&.{ 0x85, 0xc0 });
        try self.llamadaSi(0x84, self.salir_error);
        try self.bytes(&.{ 0x8b, 0x45, 0xe8, 0x48, 0x3b, 0x45, 0xf0 });
        try self.llamadaSi(0x85, self.salir_error);
        try self.epilogo(64);
        try self.cerrarMarco(m);
    }

    /// Escritura en el búfer de stdout (rcx = datos, rdx = longitud). Vacía el
    /// búfer cuando no cabe; un fragmento mayor que el búfer se escribe directo.
    fn rutinaBufer(self: *Emisor) Error!void {
        self.marcar(self.escribir);
        const m = try self.prologo(64);
        const copiar = try self.label();
        const bucle = try self.label();
        const fin = try self.label();
        try self.bytes(&.{ 0x48, 0x89, 0x4d, 0xf8, 0x48, 0x89, 0x55, 0xf0 }); // guardar rcx, rdx
        try self.referencia(&.{ 0x48, 0x8b, 0x05 }, .{ .escritura = dato_salida_len }); // mov rax, [len]
        try self.bytes(&.{ 0x48, 0x01, 0xd0, 0x48, 0x3d }); // add rax, rdx; cmp rax, cap
        try self.emitir_u32(capacidad_salida);
        try self.salto(0x86, copiar); // jbe
        try self.call(self.vaciar);
        try self.bytes(&.{ 0x48, 0x8b, 0x55, 0xf0, 0x48, 0x81, 0xfa }); // mov rdx, [rbp-16]; cmp rdx, cap
        try self.emitir_u32(capacidad_salida);
        try self.salto(0x86, copiar);
        try self.bytes(&.{ 0x48, 0x8b, 0x4d, 0xf8 }); // mov rcx, [rbp-8]
        try self.call(self.escribir_salida);
        try self.salto(null, fin);
        self.marcar(copiar);
        try self.referencia(&.{ 0x48, 0x8b, 0x05 }, .{ .escritura = dato_salida_len }); // mov rax, [len]
        try self.referencia(&.{ 0x4c, 0x8d, 0x0d }, .{ .escritura = dato_salida }); // lea r9, [búfer]
        try self.bytes(&.{ 0x49, 0x01, 0xc1 }); // add r9, rax
        try self.bytes(&.{ 0x48, 0x8b, 0x4d, 0xf8, 0x48, 0x8b, 0x55, 0xf0 }); // rcx, rdx
        try self.bytes(&.{ 0x48, 0x01, 0xd0 }); // add rax, rdx
        try self.referencia(&.{ 0x48, 0x89, 0x05 }, .{ .escritura = dato_salida_len }); // mov [len], rax
        try self.bytes(&.{ 0x45, 0x31, 0xd2 }); // xor r10d, r10d
        self.marcar(bucle);
        try self.bytes(&.{ 0x49, 0x39, 0xd2 }); // cmp r10, rdx
        try self.salto(0x84, fin);
        try self.bytes(&.{ 0x46, 0x8a, 0x1c, 0x11 }); // mov r11b, [rcx + r10]
        try self.bytes(&.{ 0x47, 0x88, 0x1c, 0x11 }); // mov [r9 + r10], r11b
        try self.bytes(&.{ 0x49, 0xff, 0xc2 }); // inc r10
        try self.salto(null, bucle);
        self.marcar(fin);
        try self.epilogo(64);
        try self.cerrarMarco(m);
    }

    /// Escribe y descarta lo pendiente en el búfer de stdout.
    fn rutinaVaciar(self: *Emisor) Error!void {
        self.marcar(self.vaciar);
        const m = try self.prologo(32);
        const fin = try self.label();
        try self.referencia(&.{ 0x48, 0x8b, 0x15 }, .{ .escritura = dato_salida_len }); // mov rdx, [len]
        try self.bytes(&.{ 0x48, 0x85, 0xd2 }); // test rdx, rdx
        try self.salto(0x84, fin);
        try self.bytes(&.{ 0x31, 0xc0 });
        try self.referencia(&.{ 0x48, 0x89, 0x05 }, .{ .escritura = dato_salida_len }); // [len] = 0
        try self.referencia(&.{ 0x48, 0x8d, 0x0d }, .{ .escritura = dato_salida }); // lea rcx, [búfer]
        try self.call(self.escribir_salida);
        self.marcar(fin);
        try self.epilogo(32);
        try self.cerrarMarco(m);
    }

    fn runtime(self: *Emisor) Error!void {
        try self.rutinaEscribir(self.escribir_salida, -11);
        try self.rutinaEscribir(self.escribir_error, -12);
        try self.rutinaBufer();
        try self.rutinaVaciar();

        self.marcar(self.imprimir);
        const m_print = try self.prologo(96);
        const entero = try self.label();
        const caso_texto = try self.label();
        const logico = try self.label();
        const fin = try self.label();
        try self.bytes(&.{ 0x83, 0xfa, 0x01 });
        try self.salto(0x84, entero);
        try self.bytes(&.{ 0x83, 0xfa, 0x03 });
        try self.salto(0x84, caso_texto);
        try self.bytes(&.{ 0x83, 0xfa, 0x02 });
        try self.salto(0x84, logico);
        try self.bytes(&.{ 0x85, 0xd2 });
        try self.llamadaSi(0x85, self.error_variable);
        try self.textoRaw("nulo");
        try self.salto(null, fin);
        self.marcar(caso_texto);
        try self.bytes(&.{ 0x48, 0x8b, 0x11, 0x48, 0x83, 0xc1, 0x08 });
        try self.call(self.escribir);
        try self.salto(null, fin);
        self.marcar(logico);
        const falso = try self.label();
        try self.bytes(&.{ 0x48, 0x85, 0xc9 });
        try self.salto(0x84, falso);
        try self.textoRaw("verdadero");
        try self.salto(null, fin);
        self.marcar(falso);
        try self.textoRaw("falso");
        try self.salto(null, fin);
        self.marcar(entero);
        try self.bytes(&.{ 0x48, 0x89, 0xc8, 0x4c, 0x8d, 0x55, 0x00, 0x45, 0x31, 0xdb }); // rax=n r10=fin r11=signo
        const positivo = try self.label();
        const digito = try self.label();
        const listo = try self.label();
        try self.bytes(&.{ 0x48, 0x85, 0xc0 });
        try self.salto(0x89, positivo);
        try self.bytes(&.{ 0x48, 0xf7, 0xd8, 0x41, 0xbb, 1, 0, 0, 0 });
        self.marcar(positivo);
        self.marcar(digito);
        try self.bytes(&.{ 0x31, 0xd2, 0xb9, 10, 0, 0, 0, 0x48, 0xf7, 0xf1, 0x80, 0xc2, 0x30, 0x49, 0xff, 0xca, 0x41, 0x88, 0x12, 0x48, 0x85, 0xc0 });
        try self.salto(0x85, digito);
        try self.bytes(&.{ 0x45, 0x85, 0xdb });
        try self.salto(0x84, listo);
        try self.bytes(&.{ 0x49, 0xff, 0xca, 0x41, 0xc6, 0x02, 0x2d });
        self.marcar(listo);
        try self.bytes(&.{ 0x48, 0x89, 0xea, 0x4c, 0x29, 0xd2, 0x4c, 0x89, 0xd1 });
        try self.call(self.escribir);
        self.marcar(fin);
        try self.epilogo(96);
        try self.cerrarMarco(m_print);

        // Cada error: vacía stdout, escribe el diagnóstico en stderr y termina con 1.
        const errores = [_]struct { l: usize, texto: []const u8 }{
            .{ .l = self.error_tipo, .texto = "tipo incompatible en operación\n" },
            .{ .l = self.error_cero, .texto = "división o módulo por cero\n" },
            .{ .l = self.error_overflow, .texto = "desbordamiento de entero\n" },
            .{ .l = self.error_variable, .texto = "variable no definida\n" },
            .{ .l = self.error_pila, .texto = "desbordamiento de pila\n" },
        };
        for (errores) |err| {
            self.marcar(err.l);
            const m = try self.prologo(32);
            try self.call(self.vaciar);
            try self.textoDestino(err.texto, self.escribir_error);
            try self.call(self.salir_error);
            try self.bytes(&.{ 0x0f, 0x0b });
            try self.cerrarMarco(m);
        }
        // Salida con código 1 sin escribir nada más (también si falla la escritura).
        self.marcar(self.salir_error);
        const m_salir = try self.prologo(32);
        try self.bytes(&.{ 0xb9, 1, 0, 0, 0 });
        try self.api(2);
        try self.bytes(&.{ 0x0f, 0x0b });
        try self.cerrarMarco(m_salir);
    }

    fn generar(self: *Emisor, p: *const ir.Programa) Error![]u8 {
        try self.validar(p);
        self.funciones = try self.a.alloc(usize, p.funciones.len);
        for (self.funciones) |*f| f.* = try self.label();
        self.escribir = try self.label();
        self.escribir_salida = try self.label();
        self.escribir_error = try self.label();
        self.vaciar = try self.label();
        self.imprimir = try self.label();
        self.error_tipo = try self.label();
        self.error_cero = try self.label();
        self.error_overflow = try self.label();
        self.error_variable = try self.label();
        self.error_pila = try self.label();
        self.salir_error = try self.label();
        // Reserva para descriptor, ILT, IAT y nombres de importaciones.
        try self.datos.appendNTimes(self.a, 0, 256);
        const entrada = try self.prologo(32);
        try self.call(self.funciones[p.entrada]);
        try self.call(self.vaciar);
        try self.bytes(&.{ 0x31, 0xc9 });
        try self.api(2);
        try self.bytes(&.{ 0x0f, 0x0b });
        try self.cerrarMarco(entrada);
        for (p.funciones, 0..) |f, id| try self.funcion(id, f);
        try self.runtime();
        return self.pe();
    }

    fn pe(self: *Emisor) Error![]u8 {
        const text_rva: u32 = 0x1000;
        const data_rva: u32 = @intCast(alineado(0x1000 + self.codigo.items.len, 0x1000));
        // kernel32.dll: GetStdHandle, WriteFile, ExitProcess.
        const ilt = 40;
        const iat = 72;
        const dll = 104;
        @memcpy(self.datos.items[dll..][0..13], "KERNEL32.dll\x00");
        var namepos: usize = 120;
        for ([_][]const u8{ "GetStdHandle", "WriteFile", "ExitProcess" }, 0..) |nombre, i| {
            poner(u64, self.datos.items, ilt + i * 8, data_rva + namepos);
            poner(u64, self.datos.items, iat + i * 8, data_rva + namepos);
            @memcpy(self.datos.items[namepos + 2 ..][0..nombre.len], nombre);
            namepos = alineado(namepos + 2 + nombre.len + 1, 2);
        }
        poner(u32, self.datos.items, 0, data_rva + ilt);
        poner(u32, self.datos.items, 12, data_rva + dll);
        poner(u32, self.datos.items, 16, data_rva + iat);
        // Bloque de reubicación con dos entradas de relleno (IMAGE_REL_BASED_ABSOLUTE):
        // el código solo usa direcciones relativas a RIP, pero el cargador exige un
        // directorio de reubicaciones para elegir una base aleatoria.
        while (self.datos.items.len % 4 != 0) try self.datos.append(self.a, 0);
        const reloc = self.datos.items.len;
        var bloque: [12]u8 = .{0} ** 12;
        poner(u32, &bloque, 0, text_rva);
        poner(u32, &bloque, 4, 12);
        try self.datos.appendSlice(self.a, &bloque);
        // UNWIND_INFO: sub rsp (ALLOC_LARGE) + push rbp; sin registro de marco.
        const unwind_start = self.datos.items.len;
        for (self.marcos.items) |m| {
            const prologo_len = m.fin_prologo - m.inicio;
            var info = [_]u8{ 1, @intCast(prologo_len), 3, 0, @intCast(prologo_len), 1, 0, 0, 1, 0x50, 0, 0 };
            poner(u16, &info, 6, @intCast(m.tamano / 8));
            try self.datos.appendSlice(self.a, &info);
        }
        const pdata = self.datos.items.len;
        for (self.marcos.items, 0..) |m, i| {
            var fila: [12]u8 = undefined;
            poner(u32, &fila, 0, text_rva + @as(u32, @intCast(m.inicio)));
            poner(u32, &fila, 4, text_rva + @as(u32, @intCast(m.fin)));
            poner(u32, &fila, 8, data_rva + @as(u32, @intCast(unwind_start + i * 12)));
            try self.datos.appendSlice(self.a, &fila);
        }
        const wdata_rva: u32 = @intCast(alineado(data_rva + self.datos.items.len, 0x1000));
        for (self.parches.items) |patch| {
            const destino: i64 = @intCast(switch (patch.destino) {
                .codigo => |l| text_rva + self.etiquetas.items[l],
                .datos => |d| data_rva + d,
                .escritura => |d| wdata_rva + d,
                .importacion => |i| data_rva + iat + i * 8,
            });
            const delta = destino - @as(i64, @intCast(text_rva + patch.pos + 4));
            if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) return self.fallo("ejecutable demasiado grande");
            poner(i32, self.codigo.items, patch.pos, @intCast(delta));
        }
        const text_raw = alineado(self.codigo.items.len, 512);
        const data_raw = alineado(self.datos.items.len, 512);
        const wdata_raw = alineado(tamano_escritura, 512);
        const out = try self.a.alloc(u8, 512 + text_raw + data_raw + wdata_raw);
        @memset(out, 0);
        out[0] = 'M';
        out[1] = 'Z';
        poner(u32, out, 0x3c, 128);
        @memcpy(out[128..132], "PE\x00\x00");
        const coff = 132;
        poner(u16, out, coff, 0x8664);
        poner(u16, out, coff + 2, 3);
        poner(u16, out, coff + 16, 240);
        poner(u16, out, coff + 18, 0x22); // EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE (sin RELOCS_STRIPPED)
        const opt = 152;
        poner(u16, out, opt, 0x20b);
        poner(u32, out, opt + 4, @intCast(text_raw));
        poner(u32, out, opt + 8, @intCast(data_raw + wdata_raw));
        poner(u32, out, opt + 16, text_rva);
        poner(u32, out, opt + 20, text_rva);
        poner(u64, out, opt + 24, 0x140000000);
        poner(u32, out, opt + 32, 4096);
        poner(u32, out, opt + 36, 512);
        poner(u16, out, opt + 40, 6);
        poner(u16, out, opt + 48, 6);
        poner(u32, out, opt + 56, @intCast(alineado(wdata_rva + tamano_escritura, 4096)));
        poner(u32, out, opt + 60, 512);
        poner(u16, out, opt + 68, 3);
        poner(u16, out, opt + 70, 0x160); // NX_COMPAT | DYNAMIC_BASE | HIGH_ENTROPY_VA
        poner(u64, out, opt + 72, 1024 * 1024);
        poner(u64, out, opt + 80, 4096);
        poner(u64, out, opt + 88, 1024 * 1024);
        poner(u64, out, opt + 96, 4096);
        poner(u32, out, opt + 108, 16);
        poner(u32, out, opt + 120, data_rva);
        poner(u32, out, opt + 124, 40);
        poner(u32, out, opt + 136, data_rva + @as(u32, @intCast(pdata)));
        poner(u32, out, opt + 140, @intCast(self.marcos.items.len * 12));
        poner(u32, out, opt + 152, data_rva + @as(u32, @intCast(reloc)));
        poner(u32, out, opt + 156, 12);
        poner(u32, out, opt + 208, data_rva + iat);
        poner(u32, out, opt + 212, 32);
        const sec = 392;
        @memcpy(out[sec..][0..5], ".text");
        poner(u32, out, sec + 8, @intCast(self.codigo.items.len));
        poner(u32, out, sec + 12, text_rva);
        poner(u32, out, sec + 16, @intCast(text_raw));
        poner(u32, out, sec + 20, 512);
        poner(u32, out, sec + 36, 0x60000020);
        @memcpy(out[sec + 40 ..][0..6], ".rdata");
        poner(u32, out, sec + 48, @intCast(self.datos.items.len));
        poner(u32, out, sec + 52, data_rva);
        poner(u32, out, sec + 56, @intCast(data_raw));
        poner(u32, out, sec + 60, @intCast(512 + text_raw));
        poner(u32, out, sec + 76, 0x40000040);
        @memcpy(out[sec + 80 ..][0..5], ".data");
        poner(u32, out, sec + 88, tamano_escritura);
        poner(u32, out, sec + 92, wdata_rva);
        poner(u32, out, sec + 96, @intCast(wdata_raw));
        poner(u32, out, sec + 100, @intCast(512 + text_raw + data_raw));
        poner(u32, out, sec + 116, 0xc0000040); // INITIALIZED_DATA | READ | WRITE
        @memcpy(out[512..][0..self.codigo.items.len], self.codigo.items);
        @memcpy(out[512 + text_raw ..][0..self.datos.items.len], self.datos.items);
        return out;
    }
};

pub fn generar(gpa: std.mem.Allocator, programa: *const ir.Programa) error{OutOfMemory}!Resultado {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var e = Emisor{ .a = arena.allocator() };
    const binario = e.generar(programa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSoportado => return .{ .diag = try gpa.dupe(u8, e.diag orelse "programa no soportado por el backend propio") },
    };
    return .{ .ejecutable = try gpa.dupe(u8, binario) };
}

fn programaPrueba(a: std.mem.Allocator, src: []const u8) !ir.Programa {
    const lexer = @import("lexico/lexer.zig");
    const parser = @import("sintaxis/parser.zig");
    const tokens = try lexer.tokenizar(a, src);
    defer a.free(tokens);
    var p = parser.Parser.init(a, tokens);
    defer p.deinit();
    return ir.construir(a, try p.parsePrograma());
}

fn generarPrueba(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var p = try programaPrueba(a, src);
    defer p.deinit();
    try std.testing.expect(p.diag == null);
    const r = try generar(a, &p);
    if (r.diag) |d| {
        defer a.free(d);
        std.debug.print("diag: {s}\n", .{d});
        return error.NoSoportado;
    }
    return r.ejecutable.?;
}

test "PE32+ tiene secciones alineadas e importaciones solo del sistema" {
    const a = std.testing.allocator;
    var p = try programaPrueba(a, "funcion principal()\n    imprimir(42)\nfin\n");
    defer p.deinit();
    const r = try generar(a, &p);
    const exe = r.ejecutable.?;
    defer a.free(exe);
    try std.testing.expectEqualStrings("MZ", exe[0..2]);
    try std.testing.expectEqualStrings("PE\x00\x00", exe[128..132]);
    try std.testing.expectEqual(@as(u16, 0x8664), std.mem.readInt(u16, exe[132..134], .little));
    try std.testing.expectEqual(@as(u16, 0x20b), std.mem.readInt(u16, exe[152..154], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, exe[134..136], .little));
    const data_file = std.mem.readInt(u32, exe[452..456], .little);
    try std.testing.expect(data_file % 512 == 0);
    try std.testing.expectEqualStrings("KERNEL32.dll\x00", exe[data_file + 104 ..][0..13]);
    for (exe[data_file + 20 ..][0..20]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // Directorio de excepciones presente; las funciones incluyen UNWIND_INFO.
    try std.testing.expect(std.mem.readInt(u32, exe[288..292], .little) != 0);
    const otro = try generar(a, &p);
    defer a.free(otro.ejecutable.?);
    try std.testing.expectEqualSlices(u8, exe, otro.ejecutable.?);
}

test "PE32+ admite ASLR: reubicable, sin RELOCS_STRIPPED y con directorio de reubicaciones" {
    const a = std.testing.allocator;
    const exe = try generarPrueba(a, "funcion principal()\n    imprimir(1)\nfin\n");
    defer a.free(exe);
    const caracteristicas = std.mem.readInt(u16, exe[150..152], .little);
    try std.testing.expect(caracteristicas & 0x0001 == 0);
    const dll = std.mem.readInt(u16, exe[152 + 70 ..][0..2], .little);
    try std.testing.expect(dll & 0x0040 != 0); // DYNAMIC_BASE
    try std.testing.expect(dll & 0x0020 != 0); // HIGH_ENTROPY_VA
    try std.testing.expect(dll & 0x0100 != 0); // NX_COMPAT
    try std.testing.expect(std.mem.readInt(u32, exe[152 + 152 ..][0..4], .little) != 0);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, exe[152 + 156 ..][0..4], .little));
}

test "pdata cubre funciones, rutinas de runtime y rutinas de error" {
    const a = std.testing.allocator;
    const exe = try generarPrueba(a, "funcion principal()\n    imprimir(1)\nfin\n");
    defer a.free(exe);
    const tamano = std.mem.readInt(u32, exe[152 + 140 ..][0..4], .little);
    // entrada + principal + 2 escrituras directas + búfer + vaciar + imprimir +
    // 5 rutinas de error + salir_error.
    try std.testing.expectEqual(@as(u32, 13 * 12), tamano);
}

test "backend propio reutiliza ranuras de temporales" {
    const a = std.testing.allocator;
    var fuente: std.ArrayListUnmanaged(u8) = .empty;
    defer fuente.deinit(a);
    try fuente.appendSlice(a, "funcion principal()\n    a = 0\n");
    // 400 sentencias con 3 temporales cada una: sin reutilización el marco
    // superaría los 19 KB; con ella basta un puñado de ranuras.
    for (0..400) |_| try fuente.appendSlice(a, "    a = a + 1\n");
    try fuente.appendSlice(a, "    imprimir(a)\nfin\n");
    var p = try programaPrueba(a, fuente.items);
    defer p.deinit();
    try std.testing.expect(p.diag == null);
    try std.testing.expect(p.funciones[0].registros > 1000);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var e = Emisor{ .a = arena.allocator() };
    const ranuras = try e.asignarRanuras(p.funciones[0]);
    try std.testing.expect(ranuras <= 4);
    const r = try generar(a, &p);
    defer a.free(r.ejecutable.?);
}

test "backend propio deduplica literales de texto" {
    const a = std.testing.allocator;
    const exe = try generarPrueba(a,
        \\funcion principal()
        \\    imprimir("literal-repetido")
        \\    imprimir("literal-repetido")
        \\    imprimir("literal-repetido", "literal-repetido")
        \\fin
    );
    defer a.free(exe);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, exe, "literal-repetido"));
}

test "backend propio rechaza concatenacion que llega por parametros" {
    const a = std.testing.allocator;
    var p = try programaPrueba(a,
        \\funcion unir(a, b)
        \\    retornar a + b
        \\fin
        \\funcion principal()
        \\    imprimir(unir("a", "b"))
        \\fin
    );
    defer p.deinit();
    const r = try generar(a, &p);
    defer a.free(r.diag.?);
    try std.testing.expect(r.ejecutable == null);
    try std.testing.expect(std.mem.indexOf(u8, r.diag.?, "concatenación") != null);
}

fn comprobarFalloAsignacion(a: std.mem.Allocator) !void {
    var p = try programaPrueba(a, "funcion principal()\n    imprimir(42)\nfin\n");
    defer p.deinit();
    const r = try generar(a, &p);
    defer a.free(r.ejecutable.?);
}

test "backend propio libera recursos ante fallos de asignacion" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, comprobarFalloAsignacion, .{});
}
