const std = @import("std");
const types = @import("types.zig");
const Process = types.Process;
const ProcReadResult = types.ProcReadResult;

pub const ProcessKey = struct { pid: u32, starttime: u64 };

/// Compute CPU% and I/O rates from deltas, update a Process in-place.
pub fn updateProcess(proc_ptr: *Process, result: *const ProcReadResult, wall_delta_ms: u64, num_cores: usize, tick: u64) void {
    @memcpy(proc_ptr.name[0..result.name_len], result.name[0..result.name_len]);
    proc_ptr.name_len = result.name_len;

    if (wall_delta_ms > 0 and num_cores > 0) {
        const prev_total = proc_ptr.prev_utime + proc_ptr.prev_stime;
        const cur_total = result.utime + result.stime;
        const delta = cur_total -| prev_total;
        const wall_ticks = wall_delta_ms / 10;
        if (wall_ticks > 0) {
            proc_ptr.cpu_pct = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(wall_ticks)) * 100.0 / @as(f32, @floatFromInt(num_cores));
        } else { proc_ptr.cpu_pct = 0; }
    } else { proc_ptr.cpu_pct = 0; }

    proc_ptr.prev_utime = result.utime;
    proc_ptr.prev_stime = result.stime;
    proc_ptr.rss_kb = result.rss_pages * 4;

    if (wall_delta_ms > 0) {
        proc_ptr.read_rate = (result.read_bytes -| proc_ptr.prev_read_bytes) * 1000 / wall_delta_ms;
        proc_ptr.write_rate = (result.write_bytes -| proc_ptr.prev_write_bytes) * 1000 / wall_delta_ms;
    } else { proc_ptr.read_rate = 0; proc_ptr.write_rate = 0; }
    proc_ptr.prev_read_bytes = result.read_bytes;
    proc_ptr.prev_write_bytes = result.write_bytes;

    proc_ptr.last_seen_tick = tick;
}

/// Free ringbuffers from all processes in the store.
pub fn freeStore(store: anytype, allocator: std.mem.Allocator) void {
    var iter = store.valueIterator();
    while (iter.next()) |proc_ptr| {
        if (proc_ptr.ring) |ring| allocator.destroy(ring);
    }
}

/// Remove processes not seen in the current tick.
pub fn cleanupStore(store: anytype, allocator: std.mem.Allocator, current_tick: u64) void {
    var to_remove = std.ArrayList(ProcessKey).empty;
    defer to_remove.deinit(allocator);

    var iter = store.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.last_seen_tick != current_tick) {
            to_remove.append(allocator, entry.key_ptr.*) catch break;
        }
    }
    for (to_remove.items) |key| {
        if (store.getPtr(key)) |proc_ptr| {
            if (proc_ptr.ring) |ring| allocator.destroy(ring);
        }
        _ = store.remove(key);
    }
}

pub fn cmpByCpu(_: void, a: *const Process, b: *const Process) bool { return a.cpu_pct > b.cpu_pct; }
pub fn cmpByMem(_: void, a: *const Process, b: *const Process) bool { return a.rss_kb > b.rss_kb; }

test "updateProcess CPU% delta" {
    var p = Process{ .pid = 1234, .starttime = 100 };
    var r = ProcReadResult{
        .pid = 1234, .valid = true,
        .utime = 100, .stime = 50, .starttime = 100, .state = 'R',
        .rss_pages = 256, .read_bytes = 1000, .write_bytes = 500,
        .name = [_]u8{0} ** types.NAME_MAX, .name_len = 4,
    };
    @memcpy(r.name[0..4], "test");

    // First tick — no delta (prev values are 0)
    updateProcess(&p, &r, 1000, 4, 1);
    try std.testing.expectEqual(@as(u64, 100), p.prev_utime);
    try std.testing.expectEqual(@as(u64, 50), p.prev_stime);

    // Second tick — 1 second of wall time, process used 50 ticks
    var r2 = r;
    r2.utime = 120; // +20 ticks
    r2.stime = 80;  // +30 ticks, total +50
    updateProcess(&p, &r2, 1000, 4, 2);
    // 50 ticks / 100 wall_ticks * 100 / 4 cores = 12.5%
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), p.cpu_pct, 0.1);
}

test "updateProcess I/O rate" {
    var p = Process{ .pid = 1234, .starttime = 100 };
    var r = ProcReadResult{
        .pid = 1234, .valid = true,
        .utime = 0, .stime = 0, .starttime = 100, .state = 'R',
        .rss_pages = 0, .read_bytes = 0, .write_bytes = 0,
        .name = [_]u8{0} ** types.NAME_MAX, .name_len = 0,
    };

    updateProcess(&p, &r, 1000, 1, 1);
    var r2 = r;
    r2.read_bytes = 1024; // 1KB read in 1 second
    r2.write_bytes = 512;
    updateProcess(&p, &r2, 1000, 1, 2);
    try std.testing.expectEqual(@as(u64, 1024), p.read_rate);
    try std.testing.expectEqual(@as(u64, 512), p.write_rate);
}
