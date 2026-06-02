const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const SystemCpu = types.SystemCpu;
const CpuCore = types.CpuCore;
const MAX_CPUS = types.MAX_CPUS;

/// Read /proc/stat and compute per-core CPU utilization deltas.
pub fn readCpuStat(sys: *SystemCpu) !void {
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/proc/stat", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try parseCpuStat(sys, buf[0..n]);
}

/// Parse /proc/stat content into SystemCpu (test-only, use readCpuStat in production).
fn parseCpuStat(sys: *SystemCpu, stat_str: []const u8) !void {
    sys.prev_cores = sys.cores;
    sys.wall_delta_ms = 0;

    var lines = std.mem.splitScalar(u8, stat_str, '\n');
    var core_idx: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 4 or !std.mem.startsWith(u8, line, "cpu")) continue;
        if (line[3] == ' ') continue;
        const fields_str = line[3..];
        if (fields_str.len == 0) continue;
        const space_idx = std.mem.indexOfScalar(u8, fields_str, ' ') orelse continue;
        const field_data = fields_str[space_idx + 1 ..];
        if (core_idx >= MAX_CPUS) break;

        var core = CpuCore{};
        var field_iter = std.mem.splitScalar(u8, field_data, ' ');
        const fields = [_]*u64{ &core.user, &core.nice, &core.system, &core.idle, &core.iowait, &core.irq, &core.softirq, &core.steal, &core.guest, &core.guest_nice };
        for (fields) |field_ptr| {
            const val_str = field_iter.next() orelse break;
            field_ptr.* = std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
        }
        sys.cores[core_idx] = core;
        core_idx += 1;
    }
    sys.num_cores = core_idx;

    // Compute wall delta from aggregate line
    lines = std.mem.splitScalar(u8, stat_str, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        const data = line[4..];
        var agg: CpuCore = .{};
        var field_iter = std.mem.splitScalar(u8, data, ' ');
        const agg_fields = [_]*u64{ &agg.user, &agg.nice, &agg.system, &agg.idle, &agg.iowait, &agg.irq, &agg.softirq, &agg.steal, &agg.guest, &agg.guest_nice };
        for (agg_fields) |field_ptr| {
            const val_str = field_iter.next() orelse break;
            field_ptr.* = std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
        }
        var prev_total: u64 = 0;
        for (sys.prev_cores[0..sys.num_cores]) |pc| {
            prev_total += pc.total();
        }
        sys.wall_delta_ms = (agg.total() -| prev_total) * 10;
        break;
    }
}

test "parseCpuStat from fixture" {
    const fixture = @import("fixture.zig");
    var buf: [8192]u8 = undefined;
    const data = fixture.load(&buf, "fixtures/0001", "stat");
    try std.testing.expect(data.len > 0);

    var sys = SystemCpu{};
    try parseCpuStat(&sys, data);
    try std.testing.expect(sys.num_cores > 0);
    try std.testing.expect(sys.num_cores <= MAX_CPUS);

    // First parse: wall_delta_ms should be huge (no prev data)
    // Parse again to get a real delta
    try parseCpuStat(&sys, data);
    try std.testing.expect(sys.wall_delta_ms > 0);

    // Verify at least one core has non-zero values
    var has_nonzero = false;
    for (sys.cores[0..sys.num_cores]) |c| {
        if (c.user + c.system + c.idle > 0) has_nonzero = true;
    }
    try std.testing.expect(has_nonzero);
}
