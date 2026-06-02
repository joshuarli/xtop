const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const SystemCpu = types.SystemCpu;
const CpuCore = types.CpuCore;

/// Return pointers to all u64 fields of a CpuCore in /proc/stat column order.
/// Generated at comptime from the struct definition — the struct field order
/// IS the /proc/stat column order. Do not reorder CpuCore fields.
fn cpuCoreFieldPtrs(core: *CpuCore) [10]*u64 {
    const fields = @typeInfo(CpuCore).@"struct".fields;
    var result: [fields.len]*u64 = undefined;
    inline for (fields, 0..) |f, i| {
        result[i] = &@field(core, f.name);
    }
    return result;
}

/// Read /proc/stat and compute per-core CPU utilization deltas.
/// On first call, allocates core arrays sized to the actual core count.
pub fn readCpuStat(sys: *SystemCpu, allocator: std.mem.Allocator) !void {
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/proc/stat", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try parseCpuStat(sys, allocator, buf[0..n]);
}

/// Parse /proc/stat content into SystemCpu. Exported for testing — prefer
/// readCpuStat in production code.
pub fn parseCpuStat(sys: *SystemCpu, allocator: std.mem.Allocator, stat_str: []const u8) !void {
    // Count cores first so we can allocate exactly
    var core_count: usize = 0;
    var lines = std.mem.splitScalar(u8, stat_str, '\n');
    while (lines.next()) |line| {
        if (line.len < 4 or !std.mem.startsWith(u8, line, "cpu")) continue;
        if (line[3] == ' ') continue;
        core_count += 1;
    }

    if (core_count == 0) return;
    try sys.ensureCapacity(allocator, core_count);

    @memcpy(sys.prev_cores[0..core_count], sys.cores[0..core_count]);
    sys.wall_delta_ms = 0;

    var prev_total: u64 = 0;
    for (sys.prev_cores[0..sys.num_cores]) |pc| {
        prev_total += pc.total();
    }
    // If this is the first parse (num_cores was 0), save the raw counters
    // so the next tick can compute a real delta.
    const first_parse = sys.num_cores == 0;
    sys.num_cores = core_count;

    lines = std.mem.splitScalar(u8, stat_str, '\n');
    var core_idx: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 4 or !std.mem.startsWith(u8, line, "cpu")) continue;
        if (line[3] == ' ') continue;
        const fields_str = line[3..];
        if (fields_str.len == 0) continue;
        const space_idx = std.mem.indexOfScalar(u8, fields_str, ' ') orelse continue;
        const field_data = fields_str[space_idx + 1 ..];
        if (core_idx >= core_count) break;

        var core = CpuCore{};
        var field_iter = std.mem.splitScalar(u8, field_data, ' ');
        for (cpuCoreFieldPtrs(&core)) |field_ptr| {
            const val_str = field_iter.next() orelse break;
            field_ptr.* = std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
        }
        sys.cores[core_idx] = core;
        core_idx += 1;
    }

    // Compute wall delta from aggregate "cpu " line. On first parse we have
    // no previous data, so wall_delta_ms stays 0 (prev_cores all zero).
    if (!first_parse) {
        lines = std.mem.splitScalar(u8, stat_str, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu ")) continue;
            const data = line[4..];
            var agg: CpuCore = .{};
            var field_iter = std.mem.splitScalar(u8, data, ' ');
            for (cpuCoreFieldPtrs(&agg)) |field_ptr| {
                const val_str = field_iter.next() orelse break;
                field_ptr.* = std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
            }
            sys.wall_delta_ms = (agg.total() -| prev_total) * 10;
            break;
        }
    }
}

test "parseCpuStat from fixture" {
    const allocator = std.testing.allocator;
    const fixture = @import("fixture.zig");

    var buf: [8192]u8 = undefined;
    const data = fixture.load(&buf, "fixtures/0001", "stat");
    try std.testing.expect(data.len > 0);

    var sys = SystemCpu{};
    defer sys.deinit(allocator);
    try parseCpuStat(&sys, allocator, data);
    try std.testing.expect(sys.num_cores > 0);

    // Second parse to get a real delta
    try parseCpuStat(&sys, allocator, data);
    try std.testing.expect(sys.wall_delta_ms > 0);

    var has_nonzero = false;
    for (sys.cores[0..sys.num_cores]) |c| {
        if (c.user + c.system + c.idle > 0) has_nonzero = true;
    }
    try std.testing.expect(has_nonzero);
}
