const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const MemState = types.MemState;

/// Read /proc/meminfo into MemState.
pub fn readMemInfo(mem: *MemState) void {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/meminfo", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;
    parseMemInfo(mem, buf[0..n]);
}

/// Parse /proc/meminfo content into MemState (test-only, use readMemInfo in production).
fn parseMemInfo(mem: *MemState, info: []const u8) void {
    var lines = std.mem.splitScalar(u8, info, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mem.total_kb = parseKbValue(line) catch 0;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mem.avail_kb = parseKbValue(line) catch 0;
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            mem.swap_total_kb = parseKbValue(line) catch 0;
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            mem.swap_free_kb = parseKbValue(line) catch 0;
        }
    }
}

test "parseMemInfo from fixture" {
    const fixture = @import("fixture.zig");
    var buf: [4096]u8 = undefined;
    const data = fixture.load(&buf, "fixtures/0001", "meminfo");
    try std.testing.expect(data.len > 0);

    var mem = MemState{};
    parseMemInfo(&mem, data);
    try std.testing.expect(mem.total_kb > 0);
    try std.testing.expect(mem.avail_kb > 0);
    try std.testing.expect(mem.avail_kb <= mem.total_kb);
}

fn parseKbValue(line: []const u8) !u64 {
    var parts = std.mem.splitScalar(u8, line, ':');
    _ = parts.next();
    const rest = parts.next() orelse return error.Invalid;
    const trimmed = std.mem.trim(u8, rest, &.{ ' ', '\t' });
    const kb_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    return std.fmt.parseUnsigned(u64, trimmed[0..kb_end], 10) catch error.Invalid;
}
