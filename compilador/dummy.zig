const std = @import("std");

pub fn main() !void {
    inline for (@typeInfo(std.http.Client).@"struct".fields) |f| {
        std.debug.print("Client field: {s}\n", .{f.name});
    }
    std.debug.print("---\n", .{});
    inline for (@typeInfo(std.http.Client.FetchOptions).@"struct".fields) |f| {
        std.debug.print("FetchOptions field: {s}\n", .{f.name});
    }
}
