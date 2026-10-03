const std = @import("std");
pub fn main() !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{}", .{std.fmt.fmtFloatBit(3.0, .decimal)}) catch unreachable;
    std.debug.print("{s}\n", .{s});
    const s2 = std.fmt.bufPrint(&buf, "{d}", .{3.0}) catch unreachable;
    std.debug.print("{s}\n", .{s2});
}
