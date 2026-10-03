//! interprete.zig — Intérprete tree-walking del lenguaje Alma.
//!
//! Recorre el AST (ast.zig) y ejecuta el programa. Base de `alma ejecutar`.
//! La salida de `imprimir` se acumula en un buffer (`salida`) para poder testearla.
//!
//! Cubre el lenguaje v0.1 completo: escalares, textos, listas, diccionarios,
//! `estructura`/`modelo` con métodos, errores (`intentar`/`lanzar`), módulos y la
//! librería estándar. `asincrona`/`esperar`/`hilo` se ejecutan de forma síncrona.
//!
//! Memoria: los valores dinámicos viven en un heap con marcado y barrido no móvil
//! (docs/PROPUESTA-MEMORIA.md, opción b). Solo se recolecta en `puntoSeguro`
//! (inicio de sentencia y cabeza de bucle); todo objeto creado o leído durante la
//! sentencia en curso queda registrado en `raices_temporales` hasta que termina.
//! La arena solo guarda metadatos inmutables del programa (`TipoDef`).

const std = @import("std");
const lexer = @import("../lexico/lexer.zig");
const parser = @import("../sintaxis/parser.zig");
const ast = @import("../sintaxis/ast.zig");
const tk = @import("../lexico/token.zig");
const limites = @import("../limites.zig");
const modulos = @import("../modulos.zig");
const MemoriaGc = @import("memoria_gc.zig").Memoria;
const numeros = @import("../numeros.zig");

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Buffer = std.ArrayListUnmanaged(u8);

const ErrorEjec = error{ ErrorEjecucion, OutOfMemory };

const NativaFn = fn (interp: *Interprete, args: []const Valor) ErrorEjec!Valor;

/// Lista de runtime (tipo por referencia).
const Lista = std.ArrayListUnmanaged(Valor);

/// Diccionario de runtime (claves texto; preserva el orden de inserción).
const Diccionario = std.StringArrayHashMapUnmanaged(Valor);

const sin_metodos = [_]Stmt.Funcion{};

/// Definición de un tipo (`estructura` o `modelo`).
const TipoDef = struct {
    nombre: []const u8,
    /// `estructura` → false (valor); `modelo` → true (referencia).
    es_referencia: bool,
    campos: []const ast.Campo,
    metodos: []const Stmt.Funcion,
};

/// Instancia en runtime de un tipo. Su semántica (copia vs comparte) la decide
/// `copiarValor` según `tipo.es_referencia`.
const Instancia = struct {
    tipo: *const TipoDef,
    campos: std.StringHashMapUnmanaged(Valor) = .{},
};

/// Método resuelto sobre una instancia concreta (self ligado).
const MetodoLigado = struct {
    instancia: *Instancia,
    funcion: *const Stmt.Funcion,
};

/// Valor de error (lo que atrapa `capturar`). Expone el campo `.mensaje`.
const ErrorAlma = struct {
    mensaje: []const u8,
};

/// Resultado de una función `asincrona`. En el intérprete v0.1 se resuelve de forma
/// síncrona; `esperar` extrae su valor. La concurrencia real llega con el runtime nativo.
const Promesa = struct {
    valor: Valor,
};

/// Módulo de la librería estándar (`importar matematicas` → `matematicas.raiz(...)`).
const Modulo = struct {
    nombre: []const u8,
    miembros: std.StringHashMapUnmanaged(Valor) = .{},
};

// — Valores de runtime —

pub const Valor = union(enum) {
    nulo,
    entero: i64,
    decimal: f64,
    texto: []const u8,
    logico: bool,
    funcion: *const Stmt.Funcion,
    nativa: *const NativaFn,
    lista: *Lista,
    diccionario: *Diccionario,
    tipo: *const TipoDef,
    instancia: *Instancia,
    metodo: *MetodoLigado,
    falla: *ErrorAlma,
    promesa: *Promesa,
    modulo: *Modulo,
};

fn comoDecimal(v: Valor) ?f64 {
    return switch (v) {
        .entero => |n| @as(f64, @floatFromInt(n)),
        .decimal => |d| d,
        else => null,
    };
}

/// Orden exacto entre dos números (docs/PROPUESTA-NUMEROS.md). null si alguno es
/// NaN o si algún operando no es numérico.
fn ordenNumerico(a: Valor, b: Valor) ?std.math.Order {
    return switch (a) {
        .entero => |x| switch (b) {
            .entero => |y| std.math.order(x, y),
            .decimal => |y| numeros.compararEnteroDecimal(x, y),
            else => null,
        },
        .decimal => |x| switch (b) {
            .entero => |y| if (numeros.compararEnteroDecimal(y, x)) |o| o.invert() else null,
            .decimal => |y| if (std.math.isNan(x) or std.math.isNan(y)) null else std.math.order(x, y),
            else => null,
        },
        else => null,
    };
}

fn sonIguales(a: Valor, b: Valor) bool {
    if (comoDecimal(a) != null and comoDecimal(b) != null) {
        const orden = ordenNumerico(a, b) orelse return false;
        return orden == .eq;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .texto => std.mem.eql(u8, a.texto, b.texto),
        .logico => a.logico == b.logico,
        .nulo => true,
        else => false,
    };
}

// — Señal de control de flujo —

const Flujo = union(enum) {
    normal,
    retornar: Valor,
    romper,
    continuar,
};

// — Entorno (scope) —

const Entorno = struct {
    padre: ?*Entorno,
    mapa: std.StringHashMapUnmanaged(Valor) = .{},
    /// Si no es null, los campos de esta instancia son visibles como variables
    /// (self implícito dentro de los métodos).
    self_inst: ?*Instancia = null,

    fn definir(self: *Entorno, alloc: std.mem.Allocator, nombre: []const u8, valor: Valor) !void {
        try self.mapa.put(alloc, nombre, valor);
    }

    fn obtener(self: *Entorno, nombre: []const u8) ?Valor {
        var actual: ?*Entorno = self;
        while (actual) |e| {
            if (e.mapa.get(nombre)) |v| return v;
            if (e.self_inst) |inst| {
                if (inst.campos.get(nombre)) |v| return v;
            }
            actual = e.padre;
        }
        return null;
    }

    fn asignar(self: *Entorno, nombre: []const u8, valor: Valor) bool {
        var actual: ?*Entorno = self;
        while (actual) |e| {
            if (e.mapa.getPtr(nombre)) |ptr| {
                ptr.* = valor;
                return true;
            }
            if (e.self_inst) |inst| {
                if (inst.campos.getPtr(nombre)) |ptr| {
                    ptr.* = valor;
                    return true;
                }
            }
            actual = e.padre;
        }
        return false;
    }
};

// — Intérprete —

pub const Interprete = struct {
    pub const DestinoSalida = struct {
        contexto: *anyopaque,
        escribir: *const fn (*anyopaque, []const u8) anyerror!void,
    };

    pub const GcObjeto = struct {
        pub const Datos = union(enum) {
            texto: []const u8,
            lista: *Lista,
            diccionario: *Diccionario,
            instancia: *Instancia,
            metodo: *MetodoLigado,
            falla: *ErrorAlma,
            promesa: *Promesa,
            modulo: *Modulo,
            entorno: *Entorno,
        };
        marcado: bool,
        datos: Datos,
    };

    allocator: std.mem.Allocator,
    memoria_gc: *MemoriaGc,
    /// Estructuras internas del GC (índice de objetos, raíces, pila de marcado). Se
    /// reservan fuera del conteo: crecen con la basura y no deben inflar el umbral.
    meta: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    global: *Entorno,
    entornos_funciones: std.AutoHashMapUnmanaged(*const Stmt.Funcion, *Entorno) = .empty,
    gc_objetos: std.AutoHashMapUnmanaged(usize, GcObjeto) = .empty,
    bytes_reservados: usize = 0,
    gc_umbral: usize = 1024 * 1024,
    gc_pendiente: bool = false,
    gc_base: usize = 0,
    gc_recolecciones: usize = 0,
    raices_temporales: std.ArrayListUnmanaged(usize) = .empty,
    raices_modulos: std.ArrayListUnmanaged(*Entorno) = .empty,
    pila_marcado: std.ArrayListUnmanaged(usize) = .empty,
    salida: Buffer = .empty,
    /// null captura la salida para pruebas; un destino la recibe al imprimir.
    destino_salida: ?DestinoSalida = null,
    diag: ?[]const u8 = null,
    /// Posición de la sentencia en ejecución (para reportar errores con línea/columna).
    stmt_pos: ast.Pos = .{},
    /// Posición asociada al último error.
    diag_pos: ast.Pos = .{},
    /// Valor de error en vuelo (fijado por `lanzar`; lo consume `capturar`).
    error_valor: ?Valor = null,
    profundidad_llamadas: usize = 0,
    /// E/S para el módulo `sistema` (archivos). La fija el CLI; null = sin E/S.
    io: ?std.Io = null,
    /// Generador pseudoaleatorio (para `matematicas.aleatorio`), sembrado perezosamente.
    prng: ?std.Random.DefaultPrng = null,
    /// Topes de lectura configurables (CLI: --limite-lectura, --limite-red).
    limite_archivo: usize = limites.archivo_datos,
    limite_red: usize = limites.red_respuesta,

    pub fn init(child: std.mem.Allocator) !Interprete {
        const memoria = try child.create(MemoriaGc);
        memoria.* = .{ .padre = child };
        var self = Interprete{ .allocator = memoria.allocator(), .memoria_gc = memoria, .meta = child, .arena = std.heap.ArenaAllocator.init(child), .global = undefined };
        errdefer self.deinit();
        self.global = try self.nuevoEntorno(null);
        try self.global.definir(self.allocator, "imprimir", .{ .nativa = &nativaImprimir });
        try self.global.definir(self.allocator, "rango", .{ .nativa = &nativaRango });
        try self.global.definir(self.allocator, "longitud", .{ .nativa = &nativaLongitud });
        try self.global.definir(self.allocator, "agregar", .{ .nativa = &nativaAgregar });
        try self.global.definir(self.allocator, "texto", .{ .nativa = &nativaTexto });
        try self.global.definir(self.allocator, "claves", .{ .nativa = &nativaClaves });
        try self.global.definir(self.allocator, "tiene", .{ .nativa = &nativaTiene });
        try self.global.definir(self.allocator, "error", .{ .nativa = &nativaError });
        self.raices_temporales.clearRetainingCapacity();
        return self;
    }

    pub fn deinit(self: *Interprete) void {
        var it = self.gc_objetos.iterator();
        while (it.next()) |entry| {
            self.liberarObjeto(entry.value_ptr.datos);
        }
        self.gc_objetos.deinit(self.meta);
        self.entornos_funciones.deinit(self.allocator);
        self.salida.deinit(self.allocator);
        self.raices_temporales.deinit(self.meta);
        self.raices_modulos.deinit(self.allocator);
        self.pila_marcado.deinit(self.meta);
        self.arena.deinit();
        self.memoria_gc.padre.destroy(self.memoria_gc);
    }

    pub fn textoSalida(self: *Interprete) []const u8 {
        return self.salida.items;
    }


    fn registrarGc(self: *Interprete, datos: GcObjeto.Datos) !void {
        // Consume la reserva también si falla el registro. Nunca recolecta aquí:
        // aún puede haber objetos parcialmente construidos y temporales Zig.
        errdefer self.liberarObjeto(datos);
        if (datos == .texto and datos.texto.len == 0) return;
        const ptr = switch (datos) {
            .texto => |s| @intFromPtr(s.ptr),
            .lista => |l| @intFromPtr(l),
            .diccionario => |d| @intFromPtr(d),
            .instancia => |i| @intFromPtr(i),
            .metodo => |m| @intFromPtr(m),
            .falla => |f| @intFromPtr(f),
            .promesa => |p| @intFromPtr(p),
            .modulo => |m| @intFromPtr(m),
            .entorno => |e| @intFromPtr(e),
        };
        try self.raices_temporales.ensureUnusedCapacity(self.meta, 1);
        try self.gc_objetos.put(self.meta, ptr, .{ .marcado = false, .datos = datos });
        self.raices_temporales.appendAssumeCapacity(ptr);
        self.bytes_reservados = self.memoria_gc.bytes;
        self.gc_pendiente = self.gc_pendiente or self.bytes_reservados -| self.gc_base >= self.limiteGc();
    }

    /// Bytes nuevos tolerados antes de recolectar: el umbral mínimo o el heap vivo
    /// tras la última recolección (crecimiento geométrico, coste amortizado lineal).
    fn limiteGc(self: *const Interprete) usize {
        return @max(self.gc_umbral, self.gc_base);
    }

    /// Único lugar donde se recolecta: inicio de sentencia y cabeza de bucle. Ahí
    /// todo valor vivo en el stack de Zig está en `raices_temporales` o en un entorno.
    fn puntoSeguro(self: *Interprete) ErrorEjec!void {
        self.bytes_reservados = self.memoria_gc.bytes;
        if (self.gc_pendiente or self.bytes_reservados -| self.gc_base >= self.limiteGc()) try self.recolectar();
    }

    fn recolectar(self: *Interprete) ErrorEjec!void {
        // Reservar ANTES de modificar marcas. Un fallo conserva el heap íntegro.
        try self.pila_marcado.ensureTotalCapacity(self.meta, self.gc_objetos.count());
        self.pila_marcado.clearRetainingCapacity();
        self.marcarRaices();
        while (self.pila_marcado.pop()) |ptr| {
            const datos = self.gc_objetos.get(ptr).?.datos;
            switch (datos) {
                .lista => |l| for (l.items) |v| self.marcarValor(v),
                .diccionario => |d| {
                    for (d.keys(), d.values()) |k, v| {
                        self.marcarValor(.{ .texto = k });
                        self.marcarValor(v);
                    }
                },
                .instancia => |i| self.marcarMapa(i.campos),
                .metodo => |m| self.marcarPtr(@intFromPtr(m.instancia)),
                .falla => |f| self.marcarValor(.{ .texto = f.mensaje }),
                .modulo => |m| self.marcarMapa(m.miembros),
                .entorno => |e| {
                    if (e.padre) |p| self.marcarPtr(@intFromPtr(p));
                    if (e.self_inst) |i| self.marcarPtr(@intFromPtr(i));
                    self.marcarMapa(e.mapa);
                },
                .promesa => |p| self.marcarValor(p.valor),
                .texto => {},
            }
        }
        self.barrer();
        self.bytes_reservados = self.memoria_gc.bytes;
        self.gc_base = self.bytes_reservados;
        self.gc_pendiente = false;
        self.gc_recolecciones += 1;
    }

    fn marcarRaices(self: *Interprete) void {
        self.marcarPtr(@intFromPtr(self.global));
        var it = self.entornos_funciones.iterator();
        while (it.next()) |entry| self.marcarPtr(@intFromPtr(entry.value_ptr.*));
        for (self.raices_modulos.items) |env| self.marcarPtr(@intFromPtr(env));
        for (self.raices_temporales.items) |ptr| self.marcarPtr(ptr);
        if (self.error_valor) |ev| self.marcarValor(ev);
        if (self.diag) |d| self.marcarValor(.{ .texto = d });
    }

    fn punteroValor(v: Valor) ?usize {
        return switch (v) {
            .texto => |s| if (s.len == 0) null else @intFromPtr(s.ptr),
            .lista => |p| @intFromPtr(p),
            .diccionario => |p| @intFromPtr(p),
            .instancia => |p| @intFromPtr(p),
            .metodo => |p| @intFromPtr(p),
            .falla => |p| @intFromPtr(p),
            .promesa => |p| @intFromPtr(p),
            .modulo => |p| @intFromPtr(p),
            else => null,
        };
    }

    fn proteger(self: *Interprete, valor: Valor) ErrorEjec!void {
        if (punteroValor(valor)) |ptr| try self.raices_temporales.append(self.meta, ptr);
    }

    fn marcarValor(self: *Interprete, v: Valor) void {
        if (punteroValor(v)) |ptr| self.marcarPtr(ptr);
    }

    fn marcarPtr(self: *Interprete, ptr: usize) void {
        if (self.gc_objetos.getPtr(ptr)) |obj| {
            if (obj.marcado) return;
            obj.marcado = true;
            self.pila_marcado.appendAssumeCapacity(ptr);
        }
    }

    fn marcarMapa(self: *Interprete, mapa: std.StringHashMapUnmanaged(Valor)) void {
        var it = mapa.iterator();
        while (it.next()) |entry| {
            self.marcarValor(.{ .texto = entry.key_ptr.* });
            self.marcarValor(entry.value_ptr.*);
        }
    }

    /// No reserva memoria: no puede fallar a mitad del barrido.
    fn barrer(self: *Interprete) void {
        var liberados: usize = 0;
        var it = self.gc_objetos.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.marcado) {
                self.liberarObjeto(entry.value_ptr.datos);
                self.gc_objetos.removeByPtr(entry.key_ptr);
                liberados += 1;
            } else {
                entry.value_ptr.marcado = false;
            }
        }
        // Las bajas dejan lápidas; sin rehash las búsquedas se degradan en
        // programas que crean y descartan objetos durante mucho tiempo.
        if (liberados > 0 and self.gc_objetos.capacity() > 0)
            self.gc_objetos.rehash(std.hash_map.AutoContext(usize){});
    }

    fn liberarObjeto(self: *Interprete, datos: GcObjeto.Datos) void {
        switch (datos) {
            .texto => |s| self.allocator.free(s),
            .lista => |l| {
                l.deinit(self.allocator);
                self.allocator.destroy(l);
            },
            .diccionario => |d| {
                d.deinit(self.allocator);
                self.allocator.destroy(d);
            },
            .instancia => |i| {
                i.campos.deinit(self.allocator);
                self.allocator.destroy(i);
            },
            .metodo => |m| self.allocator.destroy(m),
            .falla => |f| self.allocator.destroy(f),
            .promesa => |p| self.allocator.destroy(p),
            .modulo => |m| {
                m.miembros.deinit(self.allocator);
                self.allocator.destroy(m);
            },
            .entorno => |e| {
                e.mapa.deinit(self.allocator);
                self.allocator.destroy(e);
            },
        }
    }

    fn a(self: *Interprete) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn nuevoEntorno(self: *Interprete, padre: ?*Entorno) !*Entorno {
        const e = try self.allocator.create(Entorno);
        e.* = .{ .padre = padre };
        try self.registrarGc(.{ .entorno = e });
        return e;
    }

    fn nuevoEntornoConSelf(self: *Interprete, padre: ?*Entorno, inst: *Instancia) !*Entorno {
        const e = try self.nuevoEntorno(padre);
        e.self_inst = inst;
        return e;
    }

    fn fallar(self: *Interprete, comptime fmt: []const u8, args: anytype) ErrorEjec {
        self.diag = blk: {
            const mensaje = std.fmt.allocPrint(self.allocator, fmt, args) catch break :blk "error de ejecución (sin memoria)";
            self.registrarGc(.{ .texto = mensaje }) catch break :blk "error de ejecución (sin memoria)";
            break :blk mensaje;
        };
        self.diag_pos = self.stmt_pos;
        self.error_valor = null; // error interno: se representa por su mensaje
        return error.ErrorEjecucion;
    }

    fn crearFalla(self: *Interprete, mensaje: []const u8) !*ErrorAlma {
        const e = try self.allocator.create(ErrorAlma);
        e.* = .{ .mensaje = mensaje };
        try self.registrarGc(.{ .falla = e });
        return e;
    }

    // — Librería estándar (módulos con namespace) —

    fn procesarImportar(self: *Interprete, imp: Stmt.Importar) ErrorEjec!void {
        if (imp.desde != null) return; // los módulos de usuario los enlaza el empaquetador
        if (try self.cargarModuloEstandar(imp.que)) |modv| {
            try self.global.definir(self.allocator, imp.que, modv);
        }
    }

    fn cargarModuloEstandar(self: *Interprete, nombre: []const u8) ErrorEjec!?Valor {
        if (std.mem.eql(u8, nombre, "matematicas")) return .{ .modulo = try self.moduloMatematicas() };
        if (std.mem.eql(u8, nombre, "cadena")) return .{ .modulo = try self.moduloCadena() };
        if (std.mem.eql(u8, nombre, "sistema")) return .{ .modulo = try self.moduloSistema() };
        if (std.mem.eql(u8, nombre, "json")) return .{ .modulo = try self.moduloJson() };
        if (std.mem.eql(u8, nombre, "red")) return .{ .modulo = try self.moduloRed() };
        return null;
    }

    fn nuevoModulo(self: *Interprete, nombre: []const u8) ErrorEjec!*Modulo {
        const m = try self.allocator.create(Modulo);
        m.* = .{ .nombre = nombre };
        try self.registrarGc(.{ .modulo = m });
        return m;
    }

    fn miembro(self: *Interprete, m: *Modulo, nombre: []const u8, v: Valor) ErrorEjec!void {
        try m.miembros.put(self.allocator, nombre, v);
    }

    fn moduloMatematicas(self: *Interprete) ErrorEjec!*Modulo {
        const m = try self.nuevoModulo("matematicas");
        try self.miembro(m, "PI", .{ .decimal = std.math.pi });
        try self.miembro(m, "E", .{ .decimal = std.math.e });
        try self.miembro(m, "raiz", .{ .nativa = &matRaiz });
        try self.miembro(m, "potencia", .{ .nativa = &matPotencia });
        try self.miembro(m, "absoluto", .{ .nativa = &matAbsoluto });
        try self.miembro(m, "piso", .{ .nativa = &matPiso });
        try self.miembro(m, "techo", .{ .nativa = &matTecho });
        try self.miembro(m, "redondear", .{ .nativa = &matRedondear });
        try self.miembro(m, "minimo", .{ .nativa = &matMinimo });
        try self.miembro(m, "maximo", .{ .nativa = &matMaximo });
        try self.miembro(m, "aleatorio", .{ .nativa = &matAleatorio });
        return m;
    }

    fn moduloCadena(self: *Interprete) ErrorEjec!*Modulo {
        const m = try self.nuevoModulo("cadena");
        try self.miembro(m, "dividir", .{ .nativa = &cadDividir });
        try self.miembro(m, "unir", .{ .nativa = &cadUnir });
        try self.miembro(m, "reemplazar", .{ .nativa = &cadReemplazar });
        try self.miembro(m, "mayusculas", .{ .nativa = &cadMayusculas });
        try self.miembro(m, "minusculas", .{ .nativa = &cadMinusculas });
        try self.miembro(m, "contiene", .{ .nativa = &cadContiene });
        try self.miembro(m, "recortar", .{ .nativa = &cadRecortar });
        try self.miembro(m, "empieza_con", .{ .nativa = &cadEmpiezaCon });
        try self.miembro(m, "termina_con", .{ .nativa = &cadTerminaCon });
        return m;
    }

    fn moduloSistema(self: *Interprete) ErrorEjec!*Modulo {
        const m = try self.nuevoModulo("sistema");
        try self.miembro(m, "leer_archivo", .{ .nativa = &sisLeerArchivo });
        try self.miembro(m, "escribir_archivo", .{ .nativa = &sisEscribirArchivo });
        try self.miembro(m, "existe", .{ .nativa = &sisExiste });
        try self.miembro(m, "salir", .{ .nativa = &sisSalir });
        return m;
    }

    fn moduloJson(self: *Interprete) ErrorEjec!*Modulo {
        const m = try self.nuevoModulo("json");
        try self.miembro(m, "analizar", .{ .nativa = &jsonAnalizar });
        try self.miembro(m, "serializar", .{ .nativa = &jsonSerializar });
        return m;
    }

    fn moduloRed(self: *Interprete) ErrorEjec!*Modulo {
        const m = try self.nuevoModulo("red");
        try self.miembro(m, "obtener", .{ .nativa = &redObtener });
        try self.miembro(m, "publicar", .{ .nativa = &redPublicar });
        try self.miembro(m, "codificar_url", .{ .nativa = &redCodificarUrl });
        return m;
    }

    // — Ejecución —

    pub fn ejecutarModulos(self: *Interprete, programa: *const modulos.Programa) ErrorEjec!void {
        const marca = self.raices_temporales.items.len;
        defer self.raices_temporales.items.len = marca;
        const nativas = self.global;
        var entornos: std.AutoHashMapUnmanaged(*const modulos.Unidad, *Entorno) = .empty;
        defer entornos.deinit(self.allocator);
        for (programa.unidades) |unidad| {
            const env = try self.nuevoEntorno(nativas);
            try self.raices_modulos.append(self.allocator, env);
            try entornos.put(self.allocator, unidad, env);
            self.global = env;
            // Declaraciones y enlaces preceden a cualquier inicializador.
            for (unidad.stmts) |*s| switch (s.dato) {
                .funcion => |*f| {
                    try env.definir(self.allocator, f.nombre, .{ .funcion = f });
                    try self.entornos_funciones.put(self.allocator, f, env);
                },
                .estructura => |e| try self.registrarTipo(e.nombre, false, e.campos, &sin_metodos),
                .modelo => |m| try self.registrarTipo(m.nombre, true, m.campos, m.metodos),
                .importar => |imp| if (imp.desde == null) {
                    self.stmt_pos = s.pos;
                    try self.procesarImportar(imp);
                },
                else => {},
            };
            for (unidad.enlaces) |enlace| {
                const origen = entornos.get(enlace.unidad).?;
                const val = origen.obtener(enlace.nombre) orelse
                    return self.fallar("'{s}' no está definido en el módulo de origen", .{enlace.nombre});
                try env.definir(self.allocator, enlace.nombre, val);
            }
            for (unidad.stmts) |*s| switch (s.dato) {
                .funcion, .estructura, .modelo, .importar => {},
                else => _ = try self.ejecStmt(s, env),
            };
        }
        self.global = entornos.get(programa.entrada).?;
        // Solo una definición propia de principal es punto de entrada.
        for (programa.entrada.stmts) |*s| if (s.dato == .funcion and std.mem.eql(u8, s.dato.funcion.nombre, "principal")) {
            _ = try self.llamarFuncion(&s.dato.funcion, &.{});
            break;
        };
    }

    pub fn ejecutar(self: *Interprete, programa: []Stmt) ErrorEjec!void {
        const marca = self.raices_temporales.items.len;
        defer self.raices_temporales.items.len = marca;
        for (programa) |*s| {
            switch (s.dato) {
                .funcion => |*f| try self.global.definir(self.allocator, f.nombre, .{ .funcion = f }),
                .estructura => |e| try self.registrarTipo(e.nombre, false, e.campos, &sin_metodos),
                .modelo => |m| try self.registrarTipo(m.nombre, true, m.campos, m.metodos),
                .importar => |imp| try self.procesarImportar(imp),
                else => _ = try self.ejecStmt(s, self.global),
            }
        }
        if (self.global.obtener("principal")) |v| {
            switch (v) {
                .funcion => |f| _ = try self.llamarFuncion(f, &.{}),
                else => {},
            }
        }
    }

    fn ejecBloque(self: *Interprete, cuerpo: []Stmt, env: *Entorno) ErrorEjec!Flujo {
        for (cuerpo) |*s| {
            const f = try self.ejecStmt(s, env);
            switch (f) {
                .normal => {},
                else => return f,
            }
        }
        return .normal;
    }

    fn ejecStmt(self: *Interprete, s: *Stmt, env: *Entorno) ErrorEjec!Flujo {
        const marca = self.raices_temporales.items.len;
        defer self.raices_temporales.items.len = marca;
        try self.raices_temporales.append(self.meta, @intFromPtr(env));
        try self.puntoSeguro();
        self.stmt_pos = s.pos;
        switch (s.dato) {
            .declaracion => |d| {
                const v = try self.copiarValor(try self.evalExpr(d.valor, env));
                try env.definir(self.allocator, d.nombre, v);
                return .normal;
            },
            .asignacion => |asig| {
                const v = try self.copiarValor(try self.evalExpr(asig.valor, env));
                switch (asig.objetivo.*) {
                    .identificador => |nombre| {
                        if (!env.asignar(nombre, v)) try env.definir(self.allocator, nombre, v);
                    },
                    .indice => |ix| {
                        const obj = try self.evalExpr(ix.objeto, env);
                        const idx = try self.evalExpr(ix.indice, env);
                        switch (obj) {
                            .lista => |lst| {
                                const i = try self.indiceValido(lst, idx);
                                lst.items[i] = v;
                            },
                            .diccionario => |d| {
                                const clave = try self.comoTexto(idx, "clave de diccionario");
                                try d.put(self.allocator, clave, v);
                            },
                            else => return self.fallar("solo se puede asignar a índices de listas o diccionarios", .{}),
                        }
                    },
                    .acceso => |ac| {
                        const obj = try self.evalExpr(ac.objeto, env);
                        const inst = switch (obj) {
                            .instancia => |ins| ins,
                            else => return self.fallar("solo las instancias tienen campos asignables", .{}),
                        };
                        if (inst.campos.getPtr(ac.campo)) |ptr| {
                            ptr.* = v;
                        } else {
                            return self.fallar("el tipo '{s}' no tiene el campo '{s}'", .{ inst.tipo.nombre, ac.campo });
                        }
                    },
                    else => return self.fallar("objetivo de asignación no soportado", .{}),
                }
                return .normal;
            },
            .expresion => |e| {
                _ = try self.evalExpr(e, env);
                return .normal;
            },
            .retornar => |maybe| {
                const v = if (maybe) |e| try self.evalExpr(e, env) else Valor.nulo;
                return Flujo{ .retornar = v };
            },
            .romper => return .romper,
            .continuar => return .continuar,
            .si => |si| return self.ejecSi(si, env),
            .mientras => |m| return self.ejecMientras(m, env),
            .para => |p| return self.ejecPara(p, env),
            .funcion => |*f| {
                try env.definir(self.allocator, f.nombre, .{ .funcion = f });
                return .normal;
            },
            .estructura => |e| {
                try self.registrarTipo(e.nombre, false, e.campos, &sin_metodos);
                return .normal;
            },
            .modelo => |m| {
                try self.registrarTipo(m.nombre, true, m.campos, m.metodos);
                return .normal;
            },
            .importar => |imp| {
                try self.procesarImportar(imp);
                return .normal;
            },
            .intentar => |t| return self.ejecIntentar(t, env),
            .lanzar => |e| return self.ejecLanzar(e, env),
            // `hilo` lanza una tarea. En v0.1 se ejecuta de forma síncrona (sin
            // paralelismo real, que llegará con el runtime nativo).
            .hilo => |e| {
                _ = try self.evalExpr(e, env);
                return .normal;
            },
        }
    }

    fn ejecIntentar(self: *Interprete, t: Stmt.Intentar, env: *Entorno) ErrorEjec!Flujo {
        if (self.ejecBloque(t.cuerpo, env)) |flujo| {
            return flujo; // sin error: fluye normal (incluye retornar/romper/continuar)
        } else |err| {
            if (err == error.OutOfMemory) return err;
            // error de ejecución: se atrapa y se liga a la variable de `capturar`.
            const val = try self.tomarErrorComoValor();
            self.error_valor = null;
            self.diag = null;
            try env.definir(self.allocator, t.variable, val);
            return self.ejecBloque(t.captura, env);
        }
    }

    fn ejecLanzar(self: *Interprete, e: *const Expr, env: *Entorno) ErrorEjec!Flujo {
        const v = try self.evalExpr(e, env);
        const falla: Valor = switch (v) {
            .falla => v,
            .texto => |t| .{ .falla = try self.crearFalla(t) },
            else => blk: {
                var buf: Buffer = .empty;
                defer buf.deinit(self.allocator);
                try self.formatearValor(&buf, v);
                break :blk .{ .falla = try self.crearFalla(try self.copiarTexto(buf.items)) };
            },
        };
        self.error_valor = falla;
        self.diag = falla.falla.mensaje;
        return error.ErrorEjecucion;
    }

    fn tomarErrorComoValor(self: *Interprete) ErrorEjec!Valor {
        if (self.error_valor) |v| return v;
        return Valor{ .falla = try self.crearFalla(self.diag orelse "error de ejecución") };
    }

    fn registrarTipo(self: *Interprete, nombre: []const u8, es_referencia: bool, campos: []const ast.Campo, metodos: []const Stmt.Funcion) !void {
        const t = try self.a().create(TipoDef);
        t.* = .{ .nombre = nombre, .es_referencia = es_referencia, .campos = campos, .metodos = metodos };
        try self.global.definir(self.allocator, nombre, .{ .tipo = t });
        for (metodos) |*metodo| try self.entornos_funciones.put(self.allocator, metodo, self.global);
    }

    /// Copia según la semántica del tipo: `estructura` se clona en profundidad (valor);
    /// `modelo` y `lista` se comparten (referencia); los primitivos se copian por valor.
    fn copiarValor(self: *Interprete, v: Valor) ErrorEjec!Valor {
        switch (v) {
            .instancia => |inst| {
                if (inst.tipo.es_referencia) return v; // modelo: comparte la referencia
                const nueva = try self.allocator.create(Instancia);
                nueva.* = .{ .tipo = inst.tipo };
                try self.registrarGc(.{ .instancia = nueva });
                for (inst.tipo.campos) |c| {
                    const actual = inst.campos.get(c.nombre) orelse Valor.nulo;
                    try nueva.campos.put(self.allocator, c.nombre, try self.copiarValor(actual));
                }
                return .{ .instancia = nueva };
            },
            else => return v,
        }
    }

    fn construir(self: *Interprete, t: *const TipoDef, args: []const Valor) ErrorEjec!Valor {
        if (args.len != t.campos.len) {
            return self.fallar("'{s}' espera {d} campo(s), recibió {d}", .{ t.nombre, t.campos.len, args.len });
        }
        const inst = try self.allocator.create(Instancia);
        inst.* = .{ .tipo = t };
        try self.registrarGc(.{ .instancia = inst });
        for (t.campos, 0..) |c, i| {
            try inst.campos.put(self.allocator, c.nombre, try self.copiarValor(args[i]));
        }
        return .{ .instancia = inst };
    }

    fn ejecSi(self: *Interprete, si: Stmt.Si, env: *Entorno) ErrorEjec!Flujo {
        for (si.ramas) |r| {
            const c = try self.evalExpr(r.condicion, env);
            if (try self.esVerdadero(c)) return self.ejecBloque(r.cuerpo, env);
        }
        if (si.sino) |cuerpo| return self.ejecBloque(cuerpo, env);
        return .normal;
    }

    fn ejecMientras(self: *Interprete, m: Stmt.Mientras, env: *Entorno) ErrorEjec!Flujo {
        while (true) {
            const marca = self.raices_temporales.items.len;
            defer self.raices_temporales.items.len = marca;
            try self.puntoSeguro();
            const c = try self.evalExpr(m.condicion, env);
            if (!try self.esVerdadero(c)) break;
            const f = try self.ejecBloque(m.cuerpo, env);
            switch (f) {
                .normal, .continuar => {},
                .romper => break,
                .retornar => return f,
            }
        }
        return .normal;
    }

    fn ejecPara(self: *Interprete, p: Stmt.Para, env: *Entorno) ErrorEjec!Flujo {
        const iterable = try self.evalExpr(p.iterable, env);
        // Se itera una instantánea: el cuerpo puede agregar elementos (lo que
        // reubicaría `l.items`) o reemplazarlos. Cada elemento queda como raíz
        // temporal de la sentencia para que el GC no lo libere a mitad del bucle.
        const items: []Valor = switch (iterable) {
            .lista => |l| try self.allocator.dupe(Valor, l.items),
            // `para` sobre diccionario itera sus claves (texto).
            .diccionario => |d| blk: {
                const claves = d.keys();
                const buf = try self.allocator.alloc(Valor, claves.len);
                for (claves, 0..) |k, j| buf[j] = .{ .texto = k };
                break :blk buf;
            },
            else => return self.fallar("'para' requiere una lista o diccionario (usa rango(n) para números)", .{}),
        };
        defer self.allocator.free(items);
        try self.raices_temporales.ensureUnusedCapacity(self.meta, items.len);
        for (items) |v| if (punteroValor(v)) |ptr| self.raices_temporales.appendAssumeCapacity(ptr);
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const marca = self.raices_temporales.items.len;
            defer self.raices_temporales.items.len = marca;
            try self.puntoSeguro();
            try env.definir(self.allocator, p.variable, try self.copiarValor(items[i]));
            const f = try self.ejecBloque(p.cuerpo, env);
            switch (f) {
                .normal, .continuar => {},
                .romper => break,
                .retornar => return f,
            }
        }
        return .normal;
    }

    fn comoLista(self: *Interprete, v: Valor, contexto: []const u8) ErrorEjec!*Lista {
        return switch (v) {
            .lista => |l| l,
            else => self.fallar("se esperaba una lista para {s}", .{contexto}),
        };
    }

    fn comoTexto(self: *Interprete, v: Valor, contexto: []const u8) ErrorEjec![]const u8 {
        return switch (v) {
            .texto => |t| t,
            else => self.fallar("se esperaba texto para {s}", .{contexto}),
        };
    }

    fn indiceValido(self: *Interprete, lst: *Lista, idx: Valor) ErrorEjec!usize {
        const i = switch (idx) {
            .entero => |n| n,
            else => return self.fallar("el índice debe ser un entero", .{}),
        };
        if (i < 0 or i >= @as(i64, @intCast(lst.items.len))) {
            return self.fallar("índice fuera de rango: {d} (longitud {d})", .{ i, lst.items.len });
        }
        return @intCast(i);
    }

    fn llamarFuncion(self: *Interprete, f: *const Stmt.Funcion, args: []const Valor) ErrorEjec!Valor {
        try self.entrarLlamada();
        defer self.profundidad_llamadas -= 1;
        if (args.len != f.params.len) {
            return self.fallar("'{s}' espera {d} argumento(s), recibió {d}", .{ f.nombre, f.params.len, args.len });
        }
        const anterior = self.global;
        self.global = self.entornos_funciones.get(f) orelse self.global;
        defer self.global = anterior;
        const local = try self.nuevoEntorno(self.global);
        for (f.params, args) |p, arg| try local.definir(self.allocator, p.nombre, try self.copiarValor(arg));
        const flujo = try self.ejecBloque(f.cuerpo, local);
        const resultado: Valor = switch (flujo) {
            .retornar => |v| v,
            else => .nulo,
        };
        // Una función `asincrona` devuelve una Promesa (resuelta de forma síncrona en v0.1).
        if (f.asincrona) {
            const p = try self.allocator.create(Promesa);
            p.* = .{ .valor = resultado };
            try self.registrarGc(.{ .promesa = p });
            return .{ .promesa = p };
        }
        return resultado;
    }

    fn llamarMetodo(self: *Interprete, inst: *Instancia, f: *const Stmt.Funcion, args: []const Valor) ErrorEjec!Valor {
        try self.entrarLlamada();
        defer self.profundidad_llamadas -= 1;
        if (args.len != f.params.len) {
            return self.fallar("'{s}' espera {d} argumento(s), recibió {d}", .{ f.nombre, f.params.len, args.len });
        }
        const anterior = self.global;
        self.global = self.entornos_funciones.get(f) orelse self.global;
        defer self.global = anterior;
        const local = try self.nuevoEntornoConSelf(self.global, inst);
        try local.definir(self.allocator, "yo", .{ .instancia = inst });
        for (f.params, args) |p, arg| try local.definir(self.allocator, p.nombre, try self.copiarValor(arg));
        const flujo = try self.ejecBloque(f.cuerpo, local);
        return switch (flujo) {
            .retornar => |v| v,
            else => .nulo,
        };
    }

    fn entrarLlamada(self: *Interprete) ErrorEjec!void {
        if (self.profundidad_llamadas >= limites.llamadas) return self.fallar("desbordamiento de pila", .{});
        self.profundidad_llamadas += 1;
    }

    fn esVerdadero(self: *Interprete, v: Valor) ErrorEjec!bool {
        return switch (v) {
            .logico => |b| b,
            else => self.fallar("la condición debe ser un valor lógico (verdadero/falso)", .{}),
        };
    }

    // — Evaluación de expresiones —

    fn evalExpr(self: *Interprete, e: *const Expr, env: *Entorno) ErrorEjec!Valor {
        const valor = try self.evalExprInterna(e, env);
        try self.proteger(valor);
        return valor;
    }

    fn evalExprInterna(self: *Interprete, e: *const Expr, env: *Entorno) ErrorEjec!Valor {
        switch (e.*) {
            .literal_entero => |s| {
                const n = std.fmt.parseInt(i64, s, 10) catch return self.fallar("desbordamiento de entero", .{});
                return .{ .entero = n };
            },
            .literal_decimal => |s| {
                const d = std.fmt.parseFloat(f64, s) catch return self.fallar("decimal inválido: {s}", .{s});
                return .{ .decimal = d };
            },
            .literal_texto => |s| return .{ .texto = try self.decodificarTexto(s) },
            .literal_bool => |b| return .{ .logico = b },
            .literal_nulo => return .nulo,
            .identificador => |nombre| {
                if (env.obtener(nombre)) |v| return v;
                return self.fallar("variable no definida: {s}", .{nombre});
            },
            .unaria => |u| return self.evalUnaria(u, env),
            .binaria => |b| return self.evalBinaria(b, env),
            .llamada => |l| return self.evalLlamada(l, env),
            .acceso => |ac| {
                const obj = try self.evalExpr(ac.objeto, env);
                switch (obj) {
                    .falla => |f| {
                        if (std.mem.eql(u8, ac.campo, "mensaje")) return .{ .texto = f.mensaje };
                        return self.fallar("un error solo expone el campo 'mensaje'", .{});
                    },
                    .instancia => |inst| {
                        if (inst.campos.get(ac.campo)) |val| return val;
                        for (inst.tipo.metodos) |*m| {
                            if (std.mem.eql(u8, m.nombre, ac.campo)) {
                                const bm = try self.allocator.create(MetodoLigado);
                                bm.* = .{ .instancia = inst, .funcion = m };
                                try self.registrarGc(.{ .metodo = bm });
                                return .{ .metodo = bm };
                            }
                        }
                        return self.fallar("el tipo '{s}' no tiene el campo ni método '{s}'", .{ inst.tipo.nombre, ac.campo });
                    },
                    .modulo => |m| {
                        if (m.miembros.get(ac.campo)) |val| return val;
                        return self.fallar("el módulo '{s}' no tiene '{s}'", .{ m.nombre, ac.campo });
                    },
                    else => return self.fallar("solo las instancias, errores y módulos tienen miembros (acceso a '.{s}')", .{ac.campo}),
                }
            },
            .lista => |elems| {
                const lst = try self.nuevaLista();
                for (elems) |el| try lst.append(self.allocator, try self.copiarValor(try self.evalExpr(el, env)));
                return .{ .lista = lst };
            },
            .diccionario => |pares| {
                const d = try self.nuevoDiccionario();
                for (pares) |par| {
                    const clave = try self.comoTexto(try self.evalExpr(par.clave, env), "clave de diccionario");
                    const valor = try self.copiarValor(try self.evalExpr(par.valor, env));
                    try d.put(self.allocator, clave, valor);
                }
                return .{ .diccionario = d };
            },
            .indice => |ix| {
                const obj = try self.evalExpr(ix.objeto, env);
                const idx = try self.evalExpr(ix.indice, env);
                switch (obj) {
                    .lista => |lst| {
                        const i = try self.indiceValido(lst, idx);
                        return lst.items[i];
                    },
                    .diccionario => |d| {
                        const clave = try self.comoTexto(idx, "clave de diccionario");
                        if (d.get(clave)) |v| return v;
                        return self.fallar("clave no encontrada: {s}", .{clave});
                    },
                    else => return self.fallar("solo se pueden indexar listas o diccionarios", .{}),
                }
            },
        }
    }

    fn evalUnaria(self: *Interprete, u: Expr.Unaria, env: *Entorno) ErrorEjec!Valor {
        const v = try self.evalExpr(u.operando, env);
        switch (u.op) {
            .menos => return switch (v) {
                .entero => |n| if (n == std.math.minInt(i64)) self.fallar("desbordamiento de entero", .{}) else .{ .entero = -n },
                .decimal => |d| .{ .decimal = -d },
                else => self.fallar("la negación aritmética requiere un número", .{}),
            },
            .no_logico => return switch (v) {
                .logico => |b| .{ .logico = !b },
                else => self.fallar("'!' requiere un valor lógico", .{}),
            },
            // `esperar` resuelve una promesa; sobre cualquier otro valor es pass-through.
            .kw_esperar => return switch (v) {
                .promesa => |p| p.valor,
                else => v,
            },
            else => return self.fallar("operador unario desconocido", .{}),
        }
    }

    fn evalBinaria(self: *Interprete, b: Expr.Binaria, env: *Entorno) ErrorEjec!Valor {
        // Cortocircuito lógico.
        if (b.op == .y_logico or b.op == .o_logico) {
            const izq = try self.evalExpr(b.izq, env);
            const li = try self.esVerdadero(izq);
            if (b.op == .y_logico and !li) return .{ .logico = false };
            if (b.op == .o_logico and li) return .{ .logico = true };
            const der = try self.evalExpr(b.der, env);
            return .{ .logico = try self.esVerdadero(der) };
        }

        const izq = try self.evalExpr(b.izq, env);
        const der = try self.evalExpr(b.der, env);
        return self.aplicarBinario(b.op, izq, der);
    }

    fn aplicarBinario(self: *Interprete, op: tk.TipoToken, izq: Valor, der: Valor) ErrorEjec!Valor {
        const T = std.meta.activeTag;

        // Concatenación de texto con '+'.
        if (op == .mas and T(izq) == .texto and T(der) == .texto) {
            var out: Buffer = .empty;
            defer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, izq.texto);
            try out.appendSlice(self.allocator, der.texto);
            return .{ .texto = try self.copiarTexto(out.items) };
        }

        // Igualdad general.
        if (op == .igual or op == .distinto) {
            const eq = sonIguales(izq, der);
            return .{ .logico = if (op == .igual) eq else !eq };
        }

        const li = comoDecimal(izq);
        const ld = comoDecimal(der);
        if (li == null or ld == null) return self.fallar("la operación '{s}' requiere números", .{@tagName(op)});

        // Comparaciones por valor matemático exacto (sin pasar enteros por f64).
        // NaN no es ordenable: toda comparación de orden con NaN es falsa.
        switch (op) {
            .menor, .mayor, .menor_igual, .mayor_igual => {
                const orden = ordenNumerico(izq, der) orelse return .{ .logico = false };
                return .{ .logico = switch (op) {
                    .menor => orden == .lt,
                    .mayor => orden == .gt,
                    .menor_igual => orden != .gt,
                    else => orden != .lt,
                } };
            },
            else => {},
        }

        // Aritmética: entero puro si ambos son enteros; si no, decimal.
        if (T(izq) == .entero and T(der) == .entero) {
            const x = izq.entero;
            const y = der.entero;
            return switch (op) {
                .mas => self.enteroComprobado(@addWithOverflow(x, y)),
                .menos => self.enteroComprobado(@subWithOverflow(x, y)),
                .por => self.enteroComprobado(@mulWithOverflow(x, y)),
                .entre => if (y == 0) self.fallar("división por cero", .{}) else if (x == std.math.minInt(i64) and y == -1) self.fallar("desbordamiento de entero", .{}) else .{ .entero = @divTrunc(x, y) },
                .modulo => if (y == 0) self.fallar("módulo por cero", .{}) else if (x == std.math.minInt(i64) and y == -1) .{ .entero = 0 } else .{ .entero = @rem(x, y) },
                else => self.fallar("operador binario no soportado: {s}", .{@tagName(op)}),
            };
        } else {
            const x = li.?;
            const y = ld.?;
            return switch (op) {
                .mas => .{ .decimal = x + y },
                .menos => .{ .decimal = x - y },
                .por => .{ .decimal = x * y },
                .entre => if (y == 0) self.fallar("división por cero", .{}) else .{ .decimal = x / y },
                .modulo => self.fallar("'%' requiere enteros", .{}),
                else => self.fallar("operador binario no soportado: {s}", .{@tagName(op)}),
            };
        }
    }

    fn enteroComprobado(self: *Interprete, resultado: struct { i64, u1 }) ErrorEjec!Valor {
        if (resultado[1] != 0) return self.fallar("desbordamiento de entero", .{});
        return .{ .entero = resultado[0] };
    }

    fn evalLlamada(self: *Interprete, l: Expr.Llamada, env: *Entorno) ErrorEjec!Valor {
        const callee = try self.evalExpr(l.callee, env);
        const argv = try self.allocator.alloc(Valor, l.args.len);
        defer self.allocator.free(argv);
        for (l.args, 0..) |arg, i| argv[i] = try self.evalExpr(arg, env);
        switch (callee) {
            .nativa => |f| return f(self, argv),
            .funcion => |f| return self.llamarFuncion(f, argv),
            .tipo => |t| return self.construir(t, argv),
            .metodo => |m| return self.llamarMetodo(m.instancia, m.funcion, argv),
            else => return self.fallar("el valor no es invocable", .{}),
        }
    }

    fn decodificarTexto(self: *Interprete, lex: []const u8) ErrorEjec![]const u8 {
        const texto = try numeros.decodificarTexto(self.allocator, lex);
        try self.registrarGc(.{ .texto = texto });
        return texto;
    }

    fn copiarTexto(self: *Interprete, s: []const u8) ErrorEjec![]const u8 {
        const copia = try self.allocator.dupe(u8, s);
        try self.registrarGc(.{ .texto = copia });
        return copia;
    }

    fn nuevaLista(self: *Interprete) ErrorEjec!*Lista {
        const lst = try self.allocator.create(Lista);
        lst.* = .empty;
        try self.registrarGc(.{ .lista = lst });
        return lst;
    }

    fn nuevoDiccionario(self: *Interprete) ErrorEjec!*Diccionario {
        const d = try self.allocator.create(Diccionario);
        d.* = .empty;
        try self.registrarGc(.{ .diccionario = d });
        return d;
    }

    fn formatearValor(self: *Interprete, out: *Buffer, v: Valor) ErrorEjec!void {
        return self.formatearAnidado(out, v, 0);
    }

    /// El nivel acota la recursión: una lista que se contiene a sí misma (o un
    /// anidamiento extremo) produce un error de Alma en vez de agotar el stack.
    fn formatearAnidado(self: *Interprete, out: *Buffer, v: Valor, nivel: usize) ErrorEjec!void {
        if (nivel > limites.anidamiento) return self.fallar("estructura demasiado anidada para mostrarse (¿contiene un ciclo?)", .{});
        switch (v) {
            .nulo => try out.appendSlice(self.allocator, "nulo"),
            .entero => |n| {
                var temporal: [32]u8 = undefined;
                const bytes = std.fmt.bufPrint(&temporal, "{d}", .{n}) catch return self.fallar("no se pudo formatear el entero", .{});
                try out.appendSlice(self.allocator, bytes);
            },
            .decimal => |d| {
                var temporal: [numeros.max_decimal]u8 = undefined;
                try out.appendSlice(self.allocator, numeros.formatearDecimal(&temporal, d));
            },
            .texto => |s| try out.appendSlice(self.allocator, s),
            .logico => |b| try out.appendSlice(self.allocator, if (b) "verdadero" else "falso"),
            .funcion => try out.appendSlice(self.allocator, "<funcion>"),
            .nativa => try out.appendSlice(self.allocator, "<nativa>"),
            .lista => |lst| {
                try out.append(self.allocator, '[');
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(self.allocator, ", ");
                    try self.formatearAnidado(out, item, nivel + 1);
                }
                try out.append(self.allocator, ']');
            },
            .diccionario => |d| {
                try out.append(self.allocator, '{');
                const ks = d.keys();
                for (ks, 0..) |k, i| {
                    if (i > 0) try out.appendSlice(self.allocator, ", ");
                    try out.append(self.allocator, '"');
                    try out.appendSlice(self.allocator, k);
                    try out.appendSlice(self.allocator, "\": ");
                    try self.formatearAnidado(out, d.get(k).?, nivel + 1);
                }
                try out.append(self.allocator, '}');
            },
            .instancia => |inst| {
                try out.appendSlice(self.allocator, inst.tipo.nombre);
                try out.append(self.allocator, '(');
                for (inst.tipo.campos, 0..) |c, i| {
                    if (i > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, c.nombre);
                    try out.append(self.allocator, '=');
                    try self.formatearAnidado(out, inst.campos.get(c.nombre) orelse Valor.nulo, nivel + 1);
                }
                try out.append(self.allocator, ')');
            },
            .tipo => |t| {
                try out.appendSlice(self.allocator, "<tipo ");
                try out.appendSlice(self.allocator, t.nombre);
                try out.append(self.allocator, '>');
            },
            .metodo => |m| {
                try out.appendSlice(self.allocator, "<metodo ");
                try out.appendSlice(self.allocator, m.funcion.nombre);
                try out.append(self.allocator, '>');
            },
            .falla => |f| {
                try out.appendSlice(self.allocator, "<error: ");
                try out.appendSlice(self.allocator, f.mensaje);
                try out.append(self.allocator, '>');
            },
            .promesa => try out.appendSlice(self.allocator, "<promesa>"),
            .modulo => |m| {
                try out.appendSlice(self.allocator, "<modulo ");
                try out.appendSlice(self.allocator, m.nombre);
                try out.append(self.allocator, '>');
            },
        }
    }
};

// — Funciones nativas (librería estándar embrionaria) —

fn nativaImprimir(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    // Una línea que falla a mitad del formateo no deja fragmentos en la salida.
    const inicio = interp.salida.items.len;
    errdefer interp.salida.items.len = inicio;
    for (args, 0..) |arg, i| {
        if (i > 0) try interp.salida.append(interp.allocator, ' ');
        try interp.formatearValor(&interp.salida, arg);
    }
    try interp.salida.append(interp.allocator, '\n');
    if (interp.destino_salida) |destino| {
        defer interp.salida.clearRetainingCapacity();
        destino.escribir(destino.contexto, interp.salida.items) catch
            return interp.fallar("no se pudo escribir la salida", .{});
    }
    return .nulo;
}

/// rango(n) → [0, 1, …, n-1];  rango(a, b) → [a, …, b-1].
fn nativaRango(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    var inicio: i64 = 0;
    var fin: i64 = 0;
    if (args.len == 1) {
        fin = try enteroArg(interp, args[0]);
    } else if (args.len == 2) {
        inicio = try enteroArg(interp, args[0]);
        fin = try enteroArg(interp, args[1]);
    } else {
        return interp.fallar("rango espera 1 o 2 argumentos", .{});
    }
    const lst = try interp.nuevaLista();
    var k = inicio;
    while (k < fin) : (k += 1) try lst.append(interp.allocator, .{ .entero = k });
    return .{ .lista = lst };
}

/// longitud(lista) o longitud(texto) → entero.
fn nativaLongitud(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("longitud espera 1 argumento", .{});
    return switch (args[0]) {
        .lista => |l| .{ .entero = @intCast(l.items.len) },
        .texto => |t| .{ .entero = @intCast(t.len) },
        .diccionario => |d| .{ .entero = @intCast(d.count()) },
        else => interp.fallar("longitud espera una lista, texto o diccionario", .{}),
    };
}

/// claves(diccionario) → lista de las claves (texto), en orden de inserción.
fn nativaClaves(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("claves espera 1 argumento", .{});
    const d = switch (args[0]) {
        .diccionario => |dd| dd,
        else => return interp.fallar("claves espera un diccionario", .{}),
    };
    const lst = try interp.nuevaLista();
    for (d.keys()) |k| try lst.append(interp.allocator, .{ .texto = k });
    return .{ .lista = lst };
}

/// tiene(diccionario, clave) → verdadero si la clave existe.
fn nativaTiene(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("tiene espera (diccionario, clave)", .{});
    const d = switch (args[0]) {
        .diccionario => |dd| dd,
        else => return interp.fallar("tiene espera un diccionario", .{}),
    };
    const clave = try interp.comoTexto(args[1], "clave");
    return .{ .logico = d.get(clave) != null };
}

/// agregar(lista, valor) → añade al final (muta la lista); devuelve nulo.
fn nativaAgregar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("agregar espera (lista, valor)", .{});
    const lst = try interp.comoLista(args[0], "agregar");
    try lst.append(interp.allocator, try interp.copiarValor(args[1]));
    return .nulo;
}

fn enteroArg(interp: *Interprete, v: Valor) ErrorEjec!i64 {
    return switch (v) {
        .entero => |n| n,
        else => interp.fallar("se esperaba un entero", .{}),
    };
}

/// texto(valor) → representación textual del valor.
fn nativaTexto(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("texto espera 1 argumento", .{});
    var buf: Buffer = .empty;
    defer buf.deinit(interp.allocator);
    try interp.formatearValor(&buf, args[0]);
    return .{ .texto = try interp.copiarTexto(buf.items) };
}

/// error(mensaje) → construye un valor de error (para `lanzar`).
fn nativaError(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("error espera 1 argumento (el mensaje)", .{});
    const msg = try interp.comoTexto(args[0], "mensaje de error");
    return .{ .falla = try interp.crearFalla(msg) };
}

// — Librería estándar: matematicas —

fn decArg(interp: *Interprete, v: Valor, ctx: []const u8) ErrorEjec!f64 {
    return comoDecimal(v) orelse interp.fallar("{s} espera un número", .{ctx});
}

/// Conversión comprobada: NaN, infinitos y valores fuera de i64 son errores de Alma
/// (un @intFromFloat fuera de rango aborta el proceso o es comportamiento indefinido).
fn decimalAEntero(interp: *Interprete, d: f64, ctx: []const u8) ErrorEjec!i64 {
    const limite: f64 = 9223372036854775808.0; // 2^63
    if (!std.math.isFinite(d) or d >= limite or d < -limite) return interp.fallar("{s}: el resultado no cabe en un entero", .{ctx});
    return @intFromFloat(d);
}

fn matRaiz(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("raiz espera 1 argumento", .{});
    return .{ .decimal = @sqrt(try decArg(interp, args[0], "raiz")) };
}
fn matPotencia(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("potencia espera 2 argumentos", .{});
    return .{ .decimal = std.math.pow(f64, try decArg(interp, args[0], "potencia"), try decArg(interp, args[1], "potencia")) };
}
fn matAbsoluto(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("absoluto espera 1 argumento", .{});
    return switch (args[0]) {
        .entero => |n| if (n == std.math.minInt(i64)) interp.fallar("desbordamiento de entero", .{}) else .{ .entero = if (n < 0) -n else n },
        .decimal => |d| .{ .decimal = @abs(d) },
        else => interp.fallar("absoluto espera un número", .{}),
    };
}
fn matPiso(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("piso espera 1 argumento", .{});
    return .{ .entero = try decimalAEntero(interp, @floor(try decArg(interp, args[0], "piso")), "piso") };
}
fn matTecho(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("techo espera 1 argumento", .{});
    return .{ .entero = try decimalAEntero(interp, @ceil(try decArg(interp, args[0], "techo")), "techo") };
}
fn matRedondear(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("redondear espera 1 argumento", .{});
    return .{ .entero = try decimalAEntero(interp, @round(try decArg(interp, args[0], "redondear")), "redondear") };
}
fn matMinimo(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("minimo espera 2 argumentos", .{});
    return if (try decArg(interp, args[0], "minimo") <= try decArg(interp, args[1], "minimo")) args[0] else args[1];
}
fn matMaximo(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("maximo espera 2 argumentos", .{});
    return if (try decArg(interp, args[0], "maximo") >= try decArg(interp, args[1], "maximo")) args[0] else args[1];
}
fn matAleatorio(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    _ = args;
    if (interp.prng == null) {
        var semilla_local: u8 = 0;
        interp.prng = std.Random.DefaultPrng.init(@intFromPtr(&semilla_local));
    }
    const p = &interp.prng.?;
    return .{ .decimal = p.random().float(f64) };
}

// — Librería estándar: cadena (texto) —

fn cadDividir(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("dividir espera (texto, separador)", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const sep = try interp.comoTexto(args[1], "separador");
    const lst = try interp.nuevaLista();
    if (sep.len == 0) {
        try lst.append(interp.allocator, .{ .texto = s });
        return .{ .lista = lst };
    }
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |parte| try lst.append(interp.allocator, .{ .texto = try interp.copiarTexto(parte) });
    return .{ .lista = lst };
}
fn cadUnir(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("unir espera (lista, separador)", .{});
    const lst = try interp.comoLista(args[0], "unir");
    const sep = try interp.comoTexto(args[1], "separador");
    var out: Buffer = .empty;
    defer out.deinit(interp.allocator);
    for (lst.items, 0..) |item, k| {
        if (k > 0) try out.appendSlice(interp.allocator, sep);
        try out.appendSlice(interp.allocator, try interp.comoTexto(item, "elemento"));
    }
    return .{ .texto = try interp.copiarTexto(out.items) };
}
fn cadReemplazar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 3) return interp.fallar("reemplazar espera (texto, viejo, nuevo)", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const viejo = try interp.comoTexto(args[1], "viejo");
    const nuevo = try interp.comoTexto(args[2], "nuevo");
    if (viejo.len == 0) return .{ .texto = s };
    const reemplazado = try std.mem.replaceOwned(u8, interp.allocator, s, viejo, nuevo);
    try interp.registrarGc(.{ .texto = reemplazado });
    return .{ .texto = reemplazado };
}
fn cadMayusculas(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("mayusculas espera 1 argumento", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const buf = try interp.allocator.alloc(u8, s.len);
    _ = std.ascii.upperString(buf, s);
    try interp.registrarGc(.{ .texto = buf });
    return .{ .texto = buf };
}
fn cadMinusculas(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("minusculas espera 1 argumento", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const buf = try interp.allocator.alloc(u8, s.len);
    _ = std.ascii.lowerString(buf, s);
    try interp.registrarGc(.{ .texto = buf });
    return .{ .texto = buf };
}
fn cadContiene(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("contiene espera (texto, subcadena)", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const sub = try interp.comoTexto(args[1], "subcadena");
    return .{ .logico = std.mem.indexOf(u8, s, sub) != null };
}
fn cadRecortar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("recortar espera 1 argumento", .{});
    const s = try interp.comoTexto(args[0], "texto");
    return .{ .texto = try interp.copiarTexto(std.mem.trim(u8, s, " \t\r\n")) };
}
fn cadEmpiezaCon(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("empieza_con espera (texto, prefijo)", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const p = try interp.comoTexto(args[1], "prefijo");
    return .{ .logico = std.mem.startsWith(u8, s, p) };
}
fn cadTerminaCon(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("termina_con espera (texto, sufijo)", .{});
    const s = try interp.comoTexto(args[0], "texto");
    const p = try interp.comoTexto(args[1], "sufijo");
    return .{ .logico = std.mem.endsWith(u8, s, p) };
}

// — Librería estándar: sistema (E/S) —

fn ioDe(interp: *Interprete) ErrorEjec!std.Io {
    return interp.io orelse interp.fallar("E/S no disponible en este contexto", .{});
}
fn sisLeerArchivo(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("leer_archivo espera (ruta)", .{});
    const ruta = try interp.comoTexto(args[0], "ruta");
    const io = try ioDe(interp);
    const cwd: std.Io.Dir = .cwd();
    const datos = cwd.readFileAlloc(io, ruta, interp.allocator, .limited(interp.limite_archivo)) catch |err| return interp.fallar("no se pudo leer '{s}': {s}", .{ ruta, @errorName(err) });
    try interp.registrarGc(.{ .texto = datos });
    return .{ .texto = datos };
}
fn sisEscribirArchivo(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 2) return interp.fallar("escribir_archivo espera (ruta, contenido)", .{});
    const ruta = try interp.comoTexto(args[0], "ruta");
    const contenido = try interp.comoTexto(args[1], "contenido");
    const io = try ioDe(interp);
    const cwd: std.Io.Dir = .cwd();
    cwd.writeFile(io, .{ .sub_path = ruta, .data = contenido }) catch |err| return interp.fallar("no se pudo escribir '{s}': {s}", .{ ruta, @errorName(err) });
    return .nulo;
}
fn sisExiste(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("existe espera (ruta)", .{});
    const ruta = try interp.comoTexto(args[0], "ruta");
    const io = try ioDe(interp);
    const cwd: std.Io.Dir = .cwd();
    const f = cwd.openFile(io, ruta, .{}) catch return .{ .logico = false };
    f.close(io);
    return .{ .logico = true };
}
fn sisSalir(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len > 1) return interp.fallar("salir espera () o (codigo)", .{});
    const valor: i64 = if (args.len == 1) try enteroArg(interp, args[0]) else 0;
    if (valor < 0 or valor > 255) return interp.fallar("salir: el código debe estar entre 0 y 255, recibió {d}", .{valor});
    const codigo: u8 = @intCast(valor);
    if (interp.io) |io| std.Io.File.stdout().writeStreamingAll(io, interp.salida.items) catch {};
    std.process.exit(codigo);
}

// — Librería estándar: json —

const JsonParser = struct {
    interp: *Interprete,
    s: []const u8,
    pos: usize = 0,
    profundidad: usize = 0,

    fn entrar(self: *JsonParser) ErrorEjec!void {
        if (self.profundidad >= limites.json) return self.err("límite de anidamiento excedido");
        self.profundidad += 1;
    }

    fn err(self: *JsonParser, m: []const u8) ErrorEjec {
        return self.interp.fallar("JSON inválido: {s}", .{m});
    }
    fn ws(self: *JsonParser) void {
        while (self.pos < self.s.len) : (self.pos += 1) {
            switch (self.s[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }
    fn valor(self: *JsonParser) ErrorEjec!Valor {
        self.ws();
        if (self.pos >= self.s.len) return self.err("fin inesperado");
        return switch (self.s[self.pos]) {
            '{' => self.objeto(),
            '[' => self.arreglo(),
            '"' => .{ .texto = try self.cadena() },
            't' => self.lit("true", .{ .logico = true }),
            'f' => self.lit("false", .{ .logico = false }),
            'n' => self.lit("null", .nulo),
            else => self.numero(),
        };
    }
    fn lit(self: *JsonParser, comptime txt: []const u8, v: Valor) ErrorEjec!Valor {
        if (self.pos + txt.len <= self.s.len and std.mem.eql(u8, self.s[self.pos .. self.pos + txt.len], txt)) {
            self.pos += txt.len;
            return v;
        }
        return self.err("literal inválido");
    }
    fn cadena(self: *JsonParser) ErrorEjec![]const u8 {
        self.pos += 1; // comilla de apertura
        var out: Buffer = .empty;
        defer out.deinit(self.interp.allocator);
        while (self.pos < self.s.len) {
            const c = self.s[self.pos];
            self.pos += 1;
            if (c == '"') {
                const _s = try out.toOwnedSlice(self.interp.allocator);
                try self.interp.registrarGc(.{ .texto = _s });
                return _s;
            }
            if (c == '\\' and self.pos < self.s.len) {
                const e = self.s[self.pos];
                self.pos += 1;
                const ch: u8 = switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    'b' => 0x08,
                    'f' => 0x0c,
                    '"', '\\', '/' => e,
                    'u' => {
                        try self.escapeUnicode(&out);
                        continue;
                    },
                    else => return self.err("escape inválido en cadena"),
                };
                try out.append(self.interp.allocator, ch);
            } else {
                try out.append(self.interp.allocator, c);
            }
        }
        return self.err("cadena sin cerrar");
    }
    fn hex4(self: *JsonParser) ErrorEjec!u16 {
        if (self.pos + 4 > self.s.len) return self.err("escape \\u incompleto");
        const digitos = self.s[self.pos..][0..4];
        for (digitos) |d| if (!std.ascii.isHex(d)) return self.err("escape \\u inválido");
        const v = std.fmt.parseInt(u16, digitos, 16) catch return self.err("escape \\u inválido");
        self.pos += 4;
        return v;
    }
    /// `\uXXXX` (tras la `u`), con pares sustitutos UTF-16, escrito como UTF-8.
    fn escapeUnicode(self: *JsonParser, out: *Buffer) ErrorEjec!void {
        const alto = try self.hex4();
        var punto: u21 = alto;
        if (alto >= 0xD800 and alto <= 0xDBFF) {
            if (self.pos + 2 > self.s.len or self.s[self.pos] != '\\' or self.s[self.pos + 1] != 'u')
                return self.err("par sustituto incompleto");
            self.pos += 2;
            const bajo = try self.hex4();
            if (bajo < 0xDC00 or bajo > 0xDFFF) return self.err("par sustituto inválido");
            punto = 0x10000 + ((@as(u21, alto) - 0xD800) << 10) + (bajo - 0xDC00);
        } else if (alto >= 0xDC00 and alto <= 0xDFFF) {
            return self.err("par sustituto inválido");
        }
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(punto, &bytes) catch return self.err("escape \\u inválido");
        try out.appendSlice(self.interp.allocator, bytes[0..n]);
    }
    fn numero(self: *JsonParser) ErrorEjec!Valor {
        const inicio = self.pos;
        var es_dec = false;
        if (self.pos < self.s.len and (self.s[self.pos] == '-' or self.s[self.pos] == '+')) self.pos += 1;
        while (self.pos < self.s.len) : (self.pos += 1) {
            const c = self.s[self.pos];
            if (c >= '0' and c <= '9') continue;
            if (c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                es_dec = true;
                continue;
            }
            break;
        }
        const lex = self.s[inicio..self.pos];
        if (lex.len == 0) return self.err("número inválido");
        if (!es_dec) {
            if (std.fmt.parseInt(i64, lex, 10)) |n| {
                // `-0` conserva su signo como decimal (docs/PROPUESTA-NUMEROS.md).
                if (n == 0 and lex[0] == '-') return .{ .decimal = -0.0 };
                return .{ .entero = n };
            } else |_| {}
        }
        const d = std.fmt.parseFloat(f64, lex) catch return self.err("número inválido");
        return .{ .decimal = d };
    }
    fn arreglo(self: *JsonParser) ErrorEjec!Valor {
        try self.entrar();
        defer self.profundidad -= 1;
        self.pos += 1; // '['
        const lst = try self.interp.nuevaLista();
        self.ws();
        if (self.pos < self.s.len and self.s[self.pos] == ']') {
            self.pos += 1;
            return .{ .lista = lst };
        }
        while (true) {
            try lst.append(self.interp.allocator, try self.valor());
            self.ws();
            if (self.pos >= self.s.len) return self.err("arreglo sin cerrar");
            const c = self.s[self.pos];
            self.pos += 1;
            if (c == ']') break;
            if (c != ',') return self.err("se esperaba ',' o ']'");
        }
        return .{ .lista = lst };
    }
    fn objeto(self: *JsonParser) ErrorEjec!Valor {
        try self.entrar();
        defer self.profundidad -= 1;
        self.pos += 1; // '{'
        const d = try self.interp.nuevoDiccionario();
        self.ws();
        if (self.pos < self.s.len and self.s[self.pos] == '}') {
            self.pos += 1;
            return .{ .diccionario = d };
        }
        while (true) {
            self.ws();
            if (self.pos >= self.s.len or self.s[self.pos] != '"') return self.err("se esperaba una clave");
            const clave = try self.cadena();
            self.ws();
            if (self.pos >= self.s.len or self.s[self.pos] != ':') return self.err("se esperaba ':'");
            self.pos += 1;
            try d.put(self.interp.allocator, clave, try self.valor());
            self.ws();
            if (self.pos >= self.s.len) return self.err("objeto sin cerrar");
            const c = self.s[self.pos];
            self.pos += 1;
            if (c == '}') break;
            if (c != ',') return self.err("se esperaba ',' o '}'");
        }
        return .{ .diccionario = d };
    }
};

fn jsonAnalizar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("analizar espera (texto)", .{});
    const s = try interp.comoTexto(args[0], "json");
    var p = JsonParser{ .interp = interp, .s = s };
    return p.valor();
}

fn jsonEscribirCadena(interp: *Interprete, out: *Buffer, s: []const u8) ErrorEjec!void {
    try out.append(interp.allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(interp.allocator, "\\\""),
            '\\' => try out.appendSlice(interp.allocator, "\\\\"),
            '\n' => try out.appendSlice(interp.allocator, "\\n"),
            '\t' => try out.appendSlice(interp.allocator, "\\t"),
            '\r' => try out.appendSlice(interp.allocator, "\\r"),
            // JSON no admite caracteres de control sin escapar (incluido NUL).
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try out.appendSlice(interp.allocator, &[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] });
            },
            else => try out.append(interp.allocator, c),
        }
    }
    try out.append(interp.allocator, '"');
}

fn jsonEscribir(interp: *Interprete, out: *Buffer, v: Valor, nivel: usize) ErrorEjec!void {
    if (nivel > limites.anidamiento) return interp.fallar("estructura demasiado anidada para serializar (¿contiene un ciclo?)", .{});
    switch (v) {
        .nulo => try out.appendSlice(interp.allocator, "null"),
        .entero => try interp.formatearValor(out, v),
        .decimal => |d| {
            if (!std.math.isFinite(d)) return interp.fallar("JSON no admite el decimal {s}", .{if (std.math.isNan(d)) "nan" else if (d < 0) "-inf" else "inf"});
            try interp.formatearValor(out, v);
        },
        .logico => |b| try out.appendSlice(interp.allocator, if (b) "true" else "false"),
        .texto => |s| try jsonEscribirCadena(interp, out, s),
        .lista => |lst| {
            try out.append(interp.allocator, '[');
            for (lst.items, 0..) |item, k| {
                if (k > 0) try out.append(interp.allocator, ',');
                try jsonEscribir(interp, out, item, nivel + 1);
            }
            try out.append(interp.allocator, ']');
        },
        .diccionario => |d| {
            try out.append(interp.allocator, '{');
            const ks = d.keys();
            for (ks, 0..) |k, idx| {
                if (idx > 0) try out.append(interp.allocator, ',');
                try jsonEscribirCadena(interp, out, k);
                try out.append(interp.allocator, ':');
                try jsonEscribir(interp, out, d.get(k).?, nivel + 1);
            }
            try out.append(interp.allocator, '}');
        },
        else => return interp.fallar("no se puede serializar este valor a JSON", .{}),
    }
}

fn jsonSerializar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("serializar espera 1 argumento", .{});
    var out: Buffer = .empty;
    defer out.deinit(interp.allocator);
    try jsonEscribir(interp, &out, args[0], 0);
    return .{ .texto = try interp.copiarTexto(out.items) };
}

// — Librería estándar: red (cliente HTTP/HTTPS) —

/// Realiza una petición HTTP y devuelve un diccionario {estado, ok, cuerpo}.
/// El cuerpo de la respuesta se acota a `interp.limite_red` bytes (StreamTooLong).
/// La librería std 0.16 no expone un timeout de petición en std.http.Client: ver
/// docs/PROPUESTA-RED-TLS.md; `limites.red_timeout_ms` queda reservado.
fn redPeticion(interp: *Interprete, url: []const u8, metodo: std.http.Method, payload: ?[]const u8, extra: []const std.http.Header) ErrorEjec!Valor {
    const io = try ioDe(interp);
    const gpa = interp.arena.child_allocator;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const respuesta = peticionAcotada(&client, gpa, url, metodo, payload, extra, interp.limite_red) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return interp.fallar("la respuesta de '{s}' supera el límite de {d} bytes", .{ url, interp.limite_red }),
        else => return interp.fallar("error de red al pedir '{s}': {s}", .{ url, @errorName(err) }),
    };
    defer gpa.free(respuesta.cuerpo);

    const codigo: i64 = @intFromEnum(respuesta.estado);
    const cuerpo = try interp.copiarTexto(respuesta.cuerpo);

    const d = try interp.nuevoDiccionario();
    try d.put(interp.allocator, "estado", .{ .entero = codigo });
    try d.put(interp.allocator, "ok", .{ .logico = codigo >= 200 and codigo < 300 });
    try d.put(interp.allocator, "cuerpo", .{ .texto = cuerpo });
    return .{ .diccionario = d };
}

/// Igual que std.http.Client.fetch, pero lee el cuerpo con un tope de bytes en
/// lugar de acumularlo sin límite.
fn peticionAcotada(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    url: []const u8,
    metodo: std.http.Method,
    payload: ?[]const u8,
    extra: []const std.http.Header,
    limite: usize,
) !struct { estado: std.http.Status, cuerpo: []u8 } {
    const uri = try std.Uri.parse(url);
    var req = try client.request(metodo, uri, .{
        .redirect_behavior = if (payload == null) @enumFromInt(3) else .unhandled,
        .extra_headers = extra,
        .keep_alive = false,
    });
    defer req.deinit();

    if (payload) |datos| {
        req.transfer_encoding = .{ .content_length = datos.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(datos);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(if (payload == null) &redirect_buffer else &.{});
    const estado = response.head.status;

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
    const cuerpo = reader.allocRemaining(gpa, .limited(limite)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return .{ .estado = estado, .cuerpo = cuerpo };
}

/// Convierte un diccionario Alma (nombre -> valor texto) en cabeceras HTTP.
/// Rechaza nombres vacíos o con ':' y cualquier CR/LF: evita inyección de
/// cabeceras y los assert de std.http.Client que abortarían el proceso.
fn cabecerasDe(interp: *Interprete, v: Valor) ErrorEjec![]const std.http.Header {
    const d = switch (v) {
        .diccionario => |dd| dd,
        else => return interp.fallar("las cabeceras deben ser un diccionario", .{}),
    };
    const hs = try interp.allocator.alloc(std.http.Header, d.count());
    errdefer interp.allocator.free(hs);
    for (d.keys(), 0..) |k, i| {
        const valor = try interp.comoTexto(d.get(k).?, "valor de cabecera");
        if (k.len == 0 or std.mem.indexOfAny(u8, k, ":\r\n") != null)
            return interp.fallar("nombre de cabecera inválido: '{s}'", .{k});
        if (std.mem.indexOfAny(u8, valor, "\r\n") != null)
            return interp.fallar("el valor de la cabecera '{s}' contiene un salto de línea", .{k});
        hs[i] = .{ .name = k, .value = valor };
    }
    return hs;
}

fn redObtener(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len < 1 or args.len > 2) return interp.fallar("obtener espera (url) o (url, cabeceras)", .{});
    const url = try interp.comoTexto(args[0], "url");
    const extra: []const std.http.Header = if (args.len == 2) try cabecerasDe(interp, args[1]) else &.{};
    defer if (args.len == 2) interp.allocator.free(extra);
    return redPeticion(interp, url, .GET, null, extra);
}

fn redPublicar(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len < 2 or args.len > 3) return interp.fallar("publicar espera (url, cuerpo) o (url, cuerpo, cabeceras)", .{});
    const url = try interp.comoTexto(args[0], "url");
    const cuerpo = try interp.comoTexto(args[1], "cuerpo");
    if (args.len == 3) {
        const extra = try cabecerasDe(interp, args[2]);
        defer interp.allocator.free(extra);
        return redPeticion(interp, url, .POST, cuerpo, extra);
    }
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    return redPeticion(interp, url, .POST, cuerpo, &headers);
}

fn redCodificarUrl(interp: *Interprete, args: []const Valor) ErrorEjec!Valor {
    if (args.len != 1) return interp.fallar("codificar_url espera (texto)", .{});
    const txt = try interp.comoTexto(args[0], "texto");
    var out: Buffer = .empty;
    defer out.deinit(interp.allocator);
    for (txt) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(interp.allocator, c),
            else => {
                const hex = "0123456789ABCDEF";
                try out.appendSlice(interp.allocator, &[_]u8{ '%', hex[c >> 4], hex[c & 0xf] });
            },
        }
    }
    return .{ .texto = try interp.copiarTexto(out.items) };
}

// — Pruebas —

test "JSON limita contenedores anidados y permite analizar despues del error" {
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    for (0..2) |_| {
        _ = try jsonAnalizar(&interp, &.{.{ .texto = "[" ** 64 ++ "0" ++ "]" ** 64 }});
        try std.testing.expectError(error.ErrorEjecucion, jsonAnalizar(&interp, &.{.{ .texto = "[" ** 65 ++ "0" ++ "]" ** 65 }}));
        try std.testing.expectEqualStrings("JSON inválido: límite de anidamiento excedido", interp.diag.?);
        const normal = try jsonAnalizar(&interp, &.{.{ .texto = "42" }});
        try std.testing.expectEqual(@as(i64, 42), normal.entero);
    }
}

test "JSON comparte profundidad entre objetos y arreglos" {
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    _ = try jsonAnalizar(&interp, &.{.{ .texto = "[{\"x\":" ** 32 ++ "0" ++ "}]" ** 32 }});
    try std.testing.expectError(error.ErrorEjecucion, jsonAnalizar(&interp, &.{.{ .texto = "[{\"x\":" ** 32 ++ "[]" ++ "}]" ** 32 }}));
    try std.testing.expectEqualStrings("JSON inválido: límite de anidamiento excedido", interp.diag.?);
}

test "limite de llamadas: frontera captura y recuperacion" {
    try esperarSalida(
        \\funcion bajar(n)
        \\    si n == 0
        \\        retornar 42
        \\    fin
        \\    retornar bajar(n - 1)
        \\fin
        \\funcion principal()
        \\    imprimir(bajar(62))
        \\    i = 0
        \\    mientras i < 2
        \\        intentar
        \\            bajar(63)
        \\        capturar (e)
        \\            imprimir(e.mensaje)
        \\        fin
        \\        imprimir(bajar(62))
        \\        i = i + 1
        \\    fin
        \\fin
    , "42\ndesbordamiento de pila\n42\ndesbordamiento de pila\n42\n");
}

test "limite de llamadas: recursion mutua" {
    try esperarSalida(
        \\funcion a(n)
        \\    si n == 0
        \\        retornar 1
        \\    fin
        \\    retornar b(n - 1)
        \\fin
        \\funcion b(n)
        \\    retornar a(n)
        \\fin
        \\intentar
        \\    a(33)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
    , "desbordamiento de pila\n");
}

test "limite de llamadas: metodos y funciones comparten contador" {
    try esperarSalida(
        \\modelo Contador
        \\    funcion bajar(n)
        \\        si n == 0
        \\            retornar 42
        \\        fin
        \\        retornar yo.bajar(n - 1)
        \\    fin
        \\fin
        \\funcion principal()
        \\    c = Contador()
        \\    imprimir(c.bajar(62))
        \\    intentar
        \\        c.bajar(63)
        \\    capturar (e)
        \\        imprimir(e.mensaje)
        \\    fin
        \\    imprimir(c.bajar(62))
        \\fin
    , "42\ndesbordamiento de pila\n42\n");
}

fn esperarSalida(fuente: []const u8, esperado: []const u8) !void {
    const toks = try lexer.tokenizar(std.testing.allocator, fuente);
    defer std.testing.allocator.free(toks);
    var p = parser.Parser.init(std.testing.allocator, toks);
    defer p.deinit();
    const programa = try p.parsePrograma();
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    interp.ejecutar(programa) catch |err| {
        if (interp.diag) |d| std.debug.print("diag: {s}\n", .{d});
        return err;
    };
    try std.testing.expectEqualStrings(esperado, interp.textoSalida());
}

test "imprimir texto" {
    try esperarSalida("imprimir(\"hola\")", "hola\n");
}

test "destino de salida recibe cada impresion sin acumular historial" {
    const Receptor = struct {
        llamadas: usize = 0,
        fn escribir(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqualStrings("42\n", bytes);
            self.llamadas += 1;
        }
    };
    var receptor = Receptor{};
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    interp.destino_salida = .{ .contexto = &receptor, .escribir = Receptor.escribir };
    _ = try nativaImprimir(&interp, &.{.{ .entero = 42 }});
    const capacidad_inicial = interp.arena.queryCapacity();
    for (0..100) |_| {
        _ = try nativaImprimir(&interp, &.{.{ .entero = 42 }});
        try std.testing.expectEqual(@as(usize, 0), interp.textoSalida().len);
    }
    try std.testing.expectEqual(@as(usize, 101), receptor.llamadas);
    try std.testing.expectEqual(capacidad_inicial, interp.arena.queryCapacity());
}

test "fallo del destino se propaga sin conservar salida para reintento" {
    const Receptor = struct {
        fn escribir(_: *anyopaque, _: []const u8) anyerror!void {
            return error.DestinoCerrado;
        }
    };
    var contexto: u8 = 0;
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    interp.destino_salida = .{ .contexto = &contexto, .escribir = Receptor.escribir };
    try std.testing.expectError(error.ErrorEjecucion, nativaImprimir(&interp, &.{.{ .entero = 42 }}));
    try std.testing.expectEqualStrings("no se pudo escribir la salida", interp.diag.?);
    try std.testing.expectEqual(@as(usize, 0), interp.textoSalida().len);
}

test "comparaciones enteras conservan precision por encima de 2^53" {
    const src =
        \\a = 9007199254740992
        \\b = 9007199254740993
        \\imprimir(a == b, a != b, a < b, b > a, b <= a, a >= b)
        \\imprimir(-b < -a, -b == -a)
    ;
    try esperarSalida(src, "falso verdadero verdadero verdadero falso falso\nverdadero falso\n");
}

test "comparaciones mixtas entero/decimal son exactas" {
    const src =
        \\a = 9007199254740993
        \\d = 9007199254740992.0
        \\imprimir(a == d, a != d, a > d, a >= d, a < d, a <= d)
        \\imprimir(d < a, d == 9007199254740992, 0 == -0.0, 1 < 1.5, -1 > -1.5)
        \\imprimir(9223372036854775807 < 9223372036854775808.0)
    ;
    try esperarSalida(src, "falso verdadero verdadero verdadero falso falso\nverdadero verdadero verdadero verdadero verdadero\nverdadero\n");
}

test "formato decimal canonico en imprimir y texto" {
    const src =
        \\imprimir(0.1 + 0.2, 10000000.0, 1.0 / 3.0, -0.0, 1e21, 1e-7, 2.5)
        \\imprimir(texto(0.000001) + "|" + texto(100000000000000000000.0))
    ;
    try esperarSalida(src, "0.30000000000000004 10000000 0.3333333333333333 -0 1e21 1e-7 2.5\n0.000001|100000000000000000000\n");
}

test "NaN no es igual ni ordenable" {
    const src =
        \\importar matematicas
        \\n = matematicas.raiz(-1.0)
        \\imprimir(n == n, n != n, n < 1, 1 > n, n >= 0.5, texto(n))
    ;
    try esperarSalida(src, "falso verdadero falso falso falso nan\n");
}

test "escape NUL se conserva como un byte" {
    try esperarSalida("t = \"a\\0b\"\nimprimir(longitud(t), t)", "3 a\x00b\n");
}

test "desbordamientos aritmeticos son errores de Alma" {
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    const max = Valor{ .entero = std.math.maxInt(i64) };
    const min = Valor{ .entero = std.math.minInt(i64) };
    try std.testing.expectError(error.ErrorEjecucion, interp.aplicarBinario(.mas, max, .{ .entero = 1 }));
    try std.testing.expectError(error.ErrorEjecucion, interp.aplicarBinario(.menos, min, .{ .entero = 1 }));
    try std.testing.expectError(error.ErrorEjecucion, interp.aplicarBinario(.por, max, .{ .entero = 2 }));
    try std.testing.expectError(error.ErrorEjecucion, interp.aplicarBinario(.entre, min, .{ .entero = -1 }));
    try std.testing.expectEqualStrings("desbordamiento de entero", interp.diag.?);
    const resto = try interp.aplicarBinario(.modulo, min, .{ .entero = -1 });
    try std.testing.expectEqual(@as(i64, 0), resto.entero);
}

test "negacion del entero minimo se puede capturar" {
    try esperarSalida(
        \\minimo = -9223372036854775807 - 1
        \\intentar
        \\    imprimir(-minimo)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
    , "desbordamiento de entero\n");
}

test "nativas: conversiones fuera de rango y ciclos son errores capturables" {
    try esperarSalida(
        \\importar matematicas
        \\importar sistema
        \\intentar
        \\    matematicas.piso(1e300)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
        \\intentar
        \\    matematicas.redondear(matematicas.raiz(-1.0))
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
        \\intentar
        \\    matematicas.absoluto(-9223372036854775807 - 1)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
        \\intentar
        \\    sistema.salir(256)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
        \\l = [1]
        \\agregar(l, l)
        \\intentar
        \\    imprimir("antes", l)
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
    , "piso: el resultado no cabe en un entero\n" ++
        "redondear: el resultado no cabe en un entero\n" ++
        "desbordamiento de entero\n" ++
        "salir: el código debe estar entre 0 y 255, recibió 256\n" ++
        "estructura demasiado anidada para mostrarse (¿contiene un ciclo?)\n");
}

test "aritmética con precedencia" {
    try esperarSalida("imprimir(2 + 3 * 4)", "14\n");
}

test "variables y concatenación" {
    const src =
        \\nombre = "Alma"
        \\imprimir("Hola " + nombre)
    ;
    try esperarSalida(src, "Hola Alma\n");
}

test "si / sino" {
    const src =
        \\x = 10
        \\si x > 5
        \\    imprimir("grande")
        \\sino
        \\    imprimir("chico")
        \\fin
    ;
    try esperarSalida(src, "grande\n");
}

test "bucle mientras" {
    const src =
        \\i = 0
        \\mientras i < 3
        \\    imprimir(i)
        \\    i = i + 1
        \\fin
    ;
    try esperarSalida(src, "0\n1\n2\n");
}

test "función recursiva y principal()" {
    const src =
        \\funcion fact(n: entero) -> entero
        \\    si n <= 1
        \\        retornar 1
        \\    sino
        \\        retornar n * fact(n - 1)
        \\    fin
        \\fin
        \\funcion principal()
        \\    imprimir(fact(5))
        \\fin
    ;
    try esperarSalida(src, "120\n");
}

test "lógicos con cortocircuito" {
    const src =
        \\imprimir(verdadero && falso)
        \\imprimir(verdadero || falso)
    ;
    try esperarSalida(src, "falso\nverdadero\n");
}

test "igualdad de texto" {
    try esperarSalida("imprimir(\"a\" == \"a\")", "verdadero\n");
}

test "listas: literal, impresión e indexación" {
    try esperarSalida("imprimir([1, 2, 3])", "[1, 2, 3]\n");
    try esperarSalida("imprimir([10, 20, 30][1])", "20\n");
}

test "para sobre lista literal" {
    const src =
        \\suma = 0
        \\para x en [1, 2, 3, 4]
        \\    suma = suma + x
        \\fin
        \\imprimir(suma)
    ;
    try esperarSalida(src, "10\n");
}

test "para sobre rango" {
    const src =
        \\para i en rango(3)
        \\    imprimir(i)
        \\fin
    ;
    try esperarSalida(src, "0\n1\n2\n");
}

test "longitud de lista y texto" {
    try esperarSalida("imprimir(longitud([1, 2, 3, 4]))", "4\n");
    try esperarSalida("imprimir(longitud(\"hola\"))", "4\n");
}

test "agregar y asignación por índice" {
    const src =
        \\lista = [1, 2]
        \\agregar(lista, 3)
        \\lista[0] = 99
        \\imprimir(lista)
    ;
    try esperarSalida(src, "[99, 2, 3]\n");
}

test "estructura: construcción, campos e impresión" {
    const src =
        \\estructura Punto
        \\    x: entero
        \\    y: entero
        \\fin
        \\p = Punto(3, 4)
        \\imprimir(p.x)
        \\imprimir(p)
    ;
    try esperarSalida(src, "3\nPunto(x=3, y=4)\n");
}

test "estructura tiene semántica de VALOR (se copia)" {
    const src =
        \\estructura Punto
        \\    x: entero
        \\    y: entero
        \\fin
        \\a = Punto(1, 2)
        \\b = a
        \\b.x = 99
        \\imprimir(a.x)
        \\imprimir(b.x)
    ;
    try esperarSalida(src, "1\n99\n");
}

test "modelo tiene semántica de REFERENCIA (se comparte)" {
    const src =
        \\modelo Caja
        \\    valor: entero
        \\fin
        \\a = Caja(1)
        \\b = a
        \\b.valor = 99
        \\imprimir(a.valor)
        \\imprimir(b.valor)
    ;
    try esperarSalida(src, "99\n99\n");
}

test "método con self implícito muta el campo" {
    const src =
        \\modelo Contador
        \\    total: entero
        \\    funcion incrementar()
        \\        total = total + 1
        \\    fin
        \\fin
        \\c = Contador(0)
        \\c.incrementar()
        \\c.incrementar()
        \\imprimir(c.total)
    ;
    try esperarSalida(src, "2\n");
}

test "método que retorna a partir de campos" {
    const src =
        \\modelo Caja
        \\    valor: entero
        \\    funcion doble() -> entero
        \\        retornar valor * 2
        \\    fin
        \\fin
        \\b = Caja(21)
        \\imprimir(b.doble())
    ;
    try esperarSalida(src, "42\n");
}

test "método con self explícito (yo)" {
    const src =
        \\modelo P
        \\    x: entero
        \\    funcion obtenerX() -> entero
        \\        retornar yo.x
        \\    fin
        \\fin
        \\p = P(7)
        \\imprimir(p.obtenerX())
    ;
    try esperarSalida(src, "7\n");
}

test "conversión texto() y concatenación" {
    try esperarSalida("imprimir(\"n=\" + texto(42))", "n=42\n");
}

test "diccionario: literal, acceso e impresión" {
    try esperarSalida("imprimir({\"a\": 1, \"b\": 2})", "{\"a\": 1, \"b\": 2}\n");
    try esperarSalida("imprimir({\"nombre\": \"Alma\"}[\"nombre\"])", "Alma\n");
}

test "diccionario: asignación de clave, longitud y tiene" {
    const src =
        \\d = {"x": 1}
        \\d["y"] = 2
        \\imprimir(longitud(d))
        \\imprimir(tiene(d, "y"))
        \\imprimir(tiene(d, "z"))
    ;
    try esperarSalida(src, "2\nverdadero\nfalso\n");
}

test "para sobre claves de diccionario" {
    const src =
        \\d = {"a": 10, "b": 20, "c": 30}
        \\suma = 0
        \\para k en d
        \\    suma = suma + d[k]
        \\fin
        \\imprimir(suma)
    ;
    try esperarSalida(src, "60\n");
}

test "intentar atrapa un error de ejecución (división por cero)" {
    const src =
        \\intentar
        \\    x = 10 / 0
        \\capturar (e)
        \\    imprimir("capturado: " + e.mensaje)
        \\fin
    ;
    try esperarSalida(src, "capturado: división por cero\n");
}

test "lanzar y capturar un error propio" {
    const src =
        \\intentar
        \\    lanzar error("algo falló")
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
    ;
    try esperarSalida(src, "algo falló\n");
}

test "intentar sin error no ejecuta el capturar" {
    const src =
        \\intentar
        \\    imprimir("ok")
        \\capturar (e)
        \\    imprimir("no deberia")
        \\fin
    ;
    try esperarSalida(src, "ok\n");
}

test "el error se propaga por las llamadas hasta el capturar" {
    const src =
        \\funcion peligrosa()
        \\    lanzar error("boom")
        \\fin
        \\funcion principal()
        \\    intentar
        \\        peligrosa()
        \\    capturar (e)
        \\        imprimir("atrapado: " + e.mensaje)
        \\    fin
        \\fin
    ;
    try esperarSalida(src, "atrapado: boom\n");
}

test "asincrona + esperar resuelve la promesa" {
    const src =
        \\asincrona funcion doble(n: entero) -> entero
        \\    retornar n * 2
        \\fin
        \\funcion principal()
        \\    r = esperar doble(21)
        \\    imprimir(r)
        \\fin
    ;
    try esperarSalida(src, "42\n");
}

test "esperar sobre un valor común es pass-through" {
    try esperarSalida("imprimir(esperar 5)", "5\n");
}

test "hilo ejecuta la tarea" {
    const src =
        \\funcion trabajar()
        \\    imprimir("trabajando")
        \\fin
        \\funcion principal()
        \\    hilo trabajar()
        \\    imprimir("listo")
        \\fin
    ;
    try esperarSalida(src, "trabajando\nlisto\n");
}

test "async con intentar/capturar (patrón de la spec)" {
    const src =
        \\asincrona funcion cargar(falla: logico) -> texto
        \\    si falla
        \\        lanzar error("falló la carga")
        \\    fin
        \\    retornar "datos"
        \\fin
        \\funcion principal()
        \\    intentar
        \\        r = esperar cargar(verdadero)
        \\        imprimir(r)
        \\    capturar (e)
        \\        imprimir("Error: " + e.mensaje)
        \\    fin
        \\fin
    ;
    try esperarSalida(src, "Error: falló la carga\n");
}

test "librería estándar: matematicas" {
    const src =
        \\importar matematicas
        \\funcion principal()
        \\    imprimir(matematicas.raiz(16.0))
        \\    imprimir(matematicas.potencia(2, 10))
        \\    imprimir(matematicas.absoluto(-5))
        \\    imprimir(matematicas.piso(3.7))
        \\    imprimir(matematicas.maximo(3, 8))
        \\fin
    ;
    try esperarSalida(src, "4\n1024\n5\n3\n8\n");
}

test "librería estándar: cadena" {
    const src =
        \\importar cadena
        \\funcion principal()
        \\    imprimir(cadena.mayusculas("hola"))
        \\    imprimir(cadena.reemplazar("a-b-c", "-", "+"))
        \\    imprimir(cadena.contiene("hola mundo", "mundo"))
        \\    partes = cadena.dividir("a,b,c", ",")
        \\    imprimir(longitud(partes))
        \\    imprimir(cadena.unir(partes, "-"))
        \\fin
    ;
    try esperarSalida(src, "HOLA\na+b+c\nverdadero\n3\na-b-c\n");
}

test "librería estándar: json" {
    const src =
        \\importar json
        \\funcion principal()
        \\    datos = json.analizar("{\"nombre\": \"Alma\", \"version\": 1}")
        \\    imprimir(datos["nombre"])
        \\    imprimir(datos["version"])
        \\    imprimir(json.serializar([1, 2, 3]))
        \\fin
    ;
    try esperarSalida(src, "Alma\n1\n[1,2,3]\n");
}

test "json: escapes unicode, control, -0 y no finitos" {
    const src =
        \\importar json
        \\importar matematicas
        \\d = json.analizar("[\"a\\u00e1\\ud83d\\ude00\\/\\b\", -0, 1e21]")
        \\imprimir(longitud(d[0]), d[1], d[2])
        \\imprimir(json.serializar(["x\0y\ty", 0.5, -0.0]))
        \\intentar
        \\    json.serializar([matematicas.raiz(-1.0)])
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
        \\intentar
        \\    json.analizar("\"\\x\"")
        \\capturar (e)
        \\    imprimir(e.mensaje)
        \\fin
    ;
    try esperarSalida(src, "9 -0 1e21\n" ++
        "[\"x\\u0000y\\ty\",0.5,-0]\n" ++
        "JSON no admite el decimal nan\n" ++
        "JSON inválido: escape inválido en cadena\n");
}

fn comprobarGc(fuente: []const u8, salida: []const u8, maximo: usize) !void {
    const toks = try lexer.tokenizar(std.testing.allocator, fuente);
    defer std.testing.allocator.free(toks);
    var p = parser.Parser.init(std.testing.allocator, toks);
    defer p.deinit();
    const programa = try p.parsePrograma();
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    interp.gc_umbral = 128;
    interp.ejecutar(programa) catch |err| {
        if (interp.diag) |d| std.debug.print("diag: {s}\n", .{d});
        return err;
    };
    try interp.recolectar();
    try std.testing.expectEqualStrings(salida, interp.textoSalida());
    try std.testing.expect(interp.gc_recolecciones > 100);
    try std.testing.expect(interp.memoria_gc.maximo < maximo);
    try std.testing.expect(interp.arena.queryCapacity() < 64 * 1024);
}

test "GC presion 100000 concatenaciones listas diccionarios y texto" {
    try comprobarGc(
        \\i = 0
        \\mientras i < 100000
        \\    t = "a" + "b"
        \\    l = [i, i + 1, i + 2]
        \\    d = {"n": texto(i), "l": l}
        \\    i = i + 1
        \\fin
        \\imprimir(i, t, l[2], d["n"])
    , "100000 ab 100001 99999\n", 256 * 1024);
}

test "GC presion 100000 crecimiento de una cadena viva" {
    try comprobarGc(
        \\i = 0
        \\s = ""
        \\mientras i < 100000
        \\    s = s + "x"
        \\    i = i + 1
        \\fin
        \\imprimir(i, longitud(s))
    , "100000 100000\n", 2 * 1024 * 1024);
}

test "GC presion 100000 metodos recursion retornos errores y promesas" {
    try comprobarGc(
        \\modelo Caja
        \\    valor: texto
        \\    funcion obtener()
        \\        x = "temporal"
        \\        retornar valor
        \\    fin
        \\fin
        \\funcion bajar(n, valor)
        \\    si n == 0
        \\        retornar valor
        \\    fin
        \\    x = [n]
        \\    retornar bajar(n - 1, valor)
        \\fin
        \\asincrona funcion futuro(v)
        \\    retornar [v]
        \\fin
        \\funcion unir(a, b)
        \\    x = {"a": a}
        \\    retornar a + b
        \\fin
        \\i = 0
        \\mientras i < 100000
        \\    c = Caja(texto(i))
        \\    r = unir("x" + texto(i), bajar(2, c.obtener()))
        \\    p = futuro(r)
        \\    intentar
        \\        lanzar error("e" + texto(i))
        \\    capturar (e)
        \\        mensaje = e.mensaje
        \\    fin
        \\    intentar
        \\        x = 1 / 0
        \\    capturar (e)
        \\        mensaje_interno = e.mensaje
        \\    fin
        \\    i = i + 1
        \\fin
        \\imprimir(i, r, mensaje, (esperar p)[0], mensaje_interno)
    , "100000 x9999999999 e99999 x9999999999 división por cero\n", 512 * 1024);
}

test "GC conserva textos derivados y constructores parcialmente evaluados" {
    try comprobarGc(
        \\importar cadena
        \\funcion mover()
        \\    i = 0
        \\    mientras i < 100
        \\        basura = "x" + texto(i)
        \\        i = i + 1
        \\    fin
        \\    retornar "z"
        \\fin
        \\i = 0
        \\mientras i < 1000
        \\    partes = cadena.dividir("xx," + texto(i), ",")
        \\    recorte = cadena.recortar("   " + texto(i) + "  ")
        \\    l = [partes[1], mover()]
        \\    d = {recorte: mover()}
        \\    i = i + 1
        \\fin
        \\imprimir(partes[1], recorte, l[0], d["999"])
    , "999 999 999 z\n", 256 * 1024);
}

test "GC para itera una instantanea aunque el cuerpo agregue y reemplace" {
    try comprobarGc(
        \\l = [texto(1), texto(2)]
        \\suma = ""
        \\i = 0
        \\para x en l
        \\    agregar(l, "nuevo" + texto(i))
        \\    l[0] = "reemplazo" + texto(i)
        \\    j = 0
        \\    mientras j < 20000
        \\        basura = [texto(j)]
        \\        j = j + 1
        \\    fin
        \\    suma = suma + x
        \\    i = i + 1
        \\fin
        \\imprimir(suma, longitud(l), l[0])
    , "12 4 reemplazo1\n", 256 * 1024);
}

test "GC recursion profunda con temporales en cada marco" {
    try comprobarGc(
        \\funcion bajar(n, acumulado)
        \\    si n == 0
        \\        retornar acumulado
        \\    fin
        \\    j = 0
        \\    mientras j < 100
        \\        basura = {"k": texto(j)}
        \\        j = j + 1
        \\    fin
        \\    retornar bajar(n - 1, acumulado + texto(n))
        \\fin
        \\i = 0
        \\mientras i < 20
        \\    r = bajar(60, "")
        \\    i = i + 1
        \\fin
        \\imprimir(longitud(r))
    , "111\n", 512 * 1024);
}

test "GC marcado iterativo conserva ciclos y cadenas profundas" {
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    var actual: Valor = .nulo;
    for (0..10000) |_| {
        const lista = try interp.nuevaLista();
        try lista.append(interp.allocator, actual);
        actual = .{ .lista = lista };
    }
    try actual.lista.append(interp.allocator, actual);
    try interp.global.definir(interp.allocator, "raiz", actual);
    interp.raices_temporales.clearRetainingCapacity();
    try interp.recolectar();
    try std.testing.expectEqual(@as(usize, 10001), interp.gc_objetos.count());
    _ = interp.global.asignar("raiz", .nulo);
    try interp.recolectar();
    try std.testing.expectEqual(@as(usize, 1), interp.gc_objetos.count());
}

fn probarGcSinMemoria(a: std.mem.Allocator) !void {
    var interp = try Interprete.init(a);
    defer interp.deinit();
    _ = try interp.copiarTexto("descartable");
    interp.raices_temporales.clearRetainingCapacity();
    try interp.recolectar();
}

test "GC conserva propiedad y libera recursos ante fallos de asignacion" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, probarGcSinMemoria, .{});
}

test "red: cabeceras con CR/LF, ':' o nombre vacio se rechazan sin abortar" {
    var interp = try Interprete.init(std.testing.allocator);
    defer interp.deinit();
    const casos = [_]struct { nombre: []const u8, valor: []const u8 }{
        .{ .nombre = "X-Valor", .valor = "a\r\nInyectada: 1" },
        .{ .nombre = "X:Nombre", .valor = "a" },
        .{ .nombre = "X\nNombre", .valor = "a" },
        .{ .nombre = "", .valor = "a" },
    };
    for (casos) |caso| {
        const d = try interp.nuevoDiccionario();
        try d.put(interp.allocator, caso.nombre, .{ .texto = caso.valor });
        try std.testing.expectError(error.ErrorEjecucion, cabecerasDe(&interp, .{ .diccionario = d }));
    }
    const valido = try interp.nuevoDiccionario();
    try valido.put(interp.allocator, "Content-Type", .{ .texto = "application/json" });
    const hs = try cabecerasDe(&interp, .{ .diccionario = valido });
    defer interp.allocator.free(hs);
    try std.testing.expectEqualStrings("application/json", hs[0].value);
}
