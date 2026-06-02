const std = @import("std");

/// Load the contents of a fixture file into a buffer. Returns empty string on failure.
pub fn load(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
    var pb: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, name }) catch return "";
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return "";
    defer _ = std.os.linux.close(fd);
    const n = std.posix.read(fd, buf) catch return "";
    return buf[0..n];
}

test "fixtures exist and are readable" {
    var buf: [8192]u8 = undefined;
    const stat = load(&buf, "fixtures/0001", "stat");
    try std.testing.expect(stat.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, stat, "cpu "));

    const meminfo = load(&buf, "fixtures/0001", "meminfo");
    try std.testing.expect(meminfo.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, meminfo, 1, "MemTotal:"));

    const netdev = load(&buf, "fixtures/0001", "netdev");
    try std.testing.expect(netdev.len > 0);
}
