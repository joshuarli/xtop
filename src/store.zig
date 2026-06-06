const std = @import("std");
const types = @import("types.zig");
const Process = types.Process;
const ProcReadResult = types.ProcReadResult;

pub const ProcessKey = struct { pid: u32, starttime: u64 };

// AutoHashMap stores entries as individually heap-allocated nodes, so
// `getPtr` / `valueIterator` pointers remain stable across insertions.
// This is why proc_list can safely hold `*Process` into the store.
pub const ProcessMap = std.AutoHashMap(ProcessKey, Process);
pub const PidMap = std.AutoHashMap(types.Pid, ProcessKey);

/// Compute CPU% and I/O rates from deltas, update a Process in-place.
pub fn updateProcess(proc_ptr: *Process, result: *const ProcReadResult, wall_delta_ms: u64, num_cores: usize, tick: u64) void {
    @memcpy(proc_ptr.name[0..result.name_len], result.name[0..result.name_len]);
    proc_ptr.name_len = result.name_len;

    if (wall_delta_ms > 0 and num_cores > 0) {
        const prev_total = proc_ptr.prev_utime + proc_ptr.prev_stime;
        const cur_total = result.utime + result.stime;
        const delta = cur_total -| prev_total;
        // wall_delta_ms is aggregate tick-ms across all cores.
        // Convert to single-core wall ticks so CPU% is per-core
        // (a single-threaded process burning one core shows 100%).
        const wall_ticks = wall_delta_ms / 10 / num_cores;
        if (wall_ticks > 0) {
            proc_ptr.cpu_pct = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(wall_ticks)) * 100.0;
        } else {
            proc_ptr.cpu_pct = 0;
        }
    } else {
        proc_ptr.cpu_pct = 0;
    }

    proc_ptr.prev_utime = result.utime;
    proc_ptr.prev_stime = result.stime;
    proc_ptr.rss_kb = result.rss_pages * 4;

    if (wall_delta_ms > 0) {
        proc_ptr.read_rate = (result.read_bytes -| proc_ptr.prev_read_bytes) * 1000 / wall_delta_ms;
        proc_ptr.write_rate = (result.write_bytes -| proc_ptr.prev_write_bytes) * 1000 / wall_delta_ms;
    } else {
        proc_ptr.read_rate = 0;
        proc_ptr.write_rate = 0;
    }
    proc_ptr.prev_read_bytes = result.read_bytes;
    proc_ptr.prev_write_bytes = result.write_bytes;

    proc_ptr.last_seen_tick = tick;
}

/// Remove processes not seen in the current tick.
/// `store` must be a hash map — misuse is caught at compile time.
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
        _ = store.remove(key);
    }
}

pub fn cmpByCpu(_: void, a: *const Process, b: *const Process) bool {
    return a.cpu_pct > b.cpu_pct;
}
pub fn cmpByMem(_: void, a: *const Process, b: *const Process) bool {
    return a.rss_kb > b.rss_kb;
}

test "updateProcess CPU% delta" {
    var p = Process{ .pid = 1234, .starttime = 100 };
    var r = ProcReadResult{
        .pid = 1234,
        .valid = true,
        .utime = 100,
        .stime = 50,
        .starttime = 100,
        .state = 'R',
        .rss_pages = 256,
        .read_bytes = 1000,
        .write_bytes = 500,
        .name = [_]u8{0} ** types.NAME_MAX,
        .name_len = 4,
    };
    @memcpy(r.name[0..4], "test");

    updateProcess(&p, &r, 1000, 4, 1);
    try std.testing.expectEqual(@as(u64, 100), p.prev_utime);
    try std.testing.expectEqual(@as(u64, 50), p.prev_stime);

    var r2 = r;
    r2.utime = 120;
    r2.stime = 80;
    updateProcess(&p, &r2, 1000, 4, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), p.cpu_pct, 0.1);
}

test "updateProcess I/O rate" {
    var p = Process{ .pid = 1234, .starttime = 100 };
    var r = ProcReadResult{
        .pid = 1234,
        .valid = true,
        .utime = 0,
        .stime = 0,
        .starttime = 100,
        .state = 'R',
        .rss_pages = 0,
        .read_bytes = 0,
        .write_bytes = 0,
        .name = [_]u8{0} ** types.NAME_MAX,
        .name_len = 0,
    };

    updateProcess(&p, &r, 1000, 1, 1);
    var r2 = r;
    r2.read_bytes = 1024;
    r2.write_bytes = 512;
    updateProcess(&p, &r2, 1000, 1, 2);
    try std.testing.expectEqual(@as(u64, 1024), p.read_rate);
    try std.testing.expectEqual(@as(u64, 512), p.write_rate);
}
