const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const NetState = types.NetState;

/// Read /proc/net/dev and compute network rate deltas.
pub fn readNetDev(net: *NetState) void {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/net/dev", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;
    parseNetDev(net, buf[0..n]);
}

/// Parse /proc/net/dev content into NetState (test-only, use readNetDev in production).
fn parseNetDev(net: *NetState, data: []const u8) void {
    net.prev_rx_bytes = net.rx_bytes;
    net.prev_tx_bytes = net.tx_bytes;
    net.rx_bytes = 0;
    net.tx_bytes = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // skip header 1
    _ = lines.next(); // skip header 2

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = line[colon + 1 ..];
        var fields = std.mem.splitScalar(u8, rest, ' ');
        var field_idx: usize = 0;
        var rx: u64 = 0;
        var tx: u64 = 0;
        while (fields.next()) |f| {
            if (f.len == 0) continue;
            const val = std.fmt.parseUnsigned(u64, f, 10) catch 0;
            if (field_idx == 0) rx = val else if (field_idx == 8) tx = val;
            field_idx += 1;
            if (field_idx > 8) break;
        }
        net.rx_bytes += rx;
        net.tx_bytes += tx;
    }

    if (net.prev_rx_bytes > 0) {
        const rx_delta = net.rx_bytes -| net.prev_rx_bytes;
        const tx_delta = net.tx_bytes -| net.prev_tx_bytes;
        net.rx_rate = rx_delta;
        net.tx_rate = tx_delta;
        net.rx_total += rx_delta;
        net.tx_total += tx_delta;
    }
}

test "parseNetDev from fixture" {
    const fixture = @import("fixture.zig");
    var buf: [8192]u8 = undefined;
    const data = fixture.load(&buf, "fixtures/0001", "netdev");
    try std.testing.expect(data.len > 0);

    var net = NetState{};
    parseNetDev(&net, data);
    // First parse: rates are 0 (no previous data)
    try std.testing.expectEqual(@as(u64, 0), net.rx_rate);
    try std.testing.expectEqual(@as(u64, 0), net.tx_rate);

    // Second parse with same data: deltas should be 0 (same counters)
    parseNetDev(&net, data);
    try std.testing.expectEqual(@as(u64, 0), net.rx_rate);
}
