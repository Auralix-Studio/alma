//! Cuenta los bytes solicitados al allocator, incluidas capacidades de colecciones
//! y tablas. No pretende medir la sobrecarga interna del allocator ni el RSS.
const std = @import("std");

pub const Memoria = struct {
    padre: std.mem.Allocator,
    bytes: usize = 0,
    maximo: usize = 0,

    pub fn allocator(self: *Memoria) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn cambiar(self: *Memoria, antes: usize, despues: usize) void {
        self.bytes = self.bytes - antes + despues;
        self.maximo = @max(self.maximo, self.bytes);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Memoria = @ptrCast(@alignCast(ctx));
        const p = self.padre.rawAlloc(n, alignment, ra) orelse return null;
        self.cambiar(0, n);
        return p;
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Memoria = @ptrCast(@alignCast(ctx));
        if (!self.padre.rawResize(old, alignment, n, ra)) return false;
        self.cambiar(old.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Memoria = @ptrCast(@alignCast(ctx));
        const p = self.padre.rawRemap(old, alignment, n, ra) orelse return null;
        self.cambiar(old.len, n);
        return p;
    }
    fn free(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Memoria = @ptrCast(@alignCast(ctx));
        self.padre.rawFree(old, alignment, ra);
        self.cambiar(old.len, 0);
    }
};
