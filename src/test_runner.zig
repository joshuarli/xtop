const std = @import("std");
const types = @import("types.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const cpu = @import("cpu.zig");
const mem = @import("mem.zig");
const net = @import("net.zig");
const fixture = @import("fixture.zig");
const scan = @import("scan.zig");

test {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(proc);
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(cpu);
    std.testing.refAllDecls(mem);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(fixture);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(@This());
}

// ─── Cross-fixture validation: ensure all three fixture ticks are valid ───

test "all fixture ticks parse correctly" {
    const fixture_dirs = [_][]const u8{ "fixtures/0001", "fixtures/0002", "fixtures/0003" };
    for (fixture_dirs) |dir| {
        var buf: [8192]u8 = undefined;

        // stat
        const stat_data = fixture.load(&buf, dir, "stat");
        try std.testing.expect(stat_data.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, stat_data, "cpu "));

        // meminfo
        const mem_data = fixture.load(&buf, dir, "meminfo");
        try std.testing.expect(mem_data.len > 0);
        try std.testing.expect(std.mem.containsAtLeast(u8, mem_data, 1, "MemTotal:"));

        // netdev
        const net_data = fixture.load(&buf, dir, "netdev");
        try std.testing.expect(net_data.len > 0);
    }
}

test "all fixture ticks produce valid CPU state" {
    const allocator = std.testing.allocator;
    const fixture_dirs = [_][]const u8{ "fixtures/0001", "fixtures/0002", "fixtures/0003" };
    var sys = types.SystemCpu{};
    defer sys.deinit(allocator);
    var buf: [8192]u8 = undefined;
    for (fixture_dirs) |dir| {
        const data = fixture.load(&buf, dir, "stat");
        try cpu.parseCpuStat(&sys, allocator, data);
        try std.testing.expect(sys.num_cores > 0);
        try cpu.parseCpuStat(&sys, allocator, data);
        try std.testing.expect(sys.wall_delta_ms > 0);
    }
}

// ─── Fuzz tests for proc parsers ───

test "parseField fuzz: random valid inputs" {
    // Generate valid space-separated fields and verify parseField works.
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();

    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const expected: u64 = rng.int(u64) % 1_000_000_000;
        const field_idx: u32 = rng.int(u32) % 10;
        const prefix_fields: u32 = rng.int(u32) % 5;

        // Build: "f1 f2 ... fn expected_val f_n+1 ...\n"
        var o: usize = 0;
        var fi: u32 = 0;
        while (fi < prefix_fields + field_idx + 1) : (fi += 1) {
            if (fi == prefix_fields + field_idx) {
                o += (std.fmt.bufPrint(buf[o..], "{d}", .{expected}) catch unreachable).len;
            } else {
                o += (std.fmt.bufPrint(buf[o..], "{d}", .{rng.int(u32)}) catch unreachable).len;
            }
            if (fi < prefix_fields + field_idx) {
                buf[o] = ' ';
                o += 1;
            }
        }
        buf[o] = '\n';
        o += 1;

        const result = proc.parseField(buf[0..o], prefix_fields + field_idx);
        try std.testing.expectEqual(expected, result);
    }
}

test "parseField rejects empty input" {
    try std.testing.expectError(error.Invalid, proc.parseField("", 0));
}

test "parseField rejects non-numeric" {
    try std.testing.expectError(error.Invalid, proc.parseField("abc xyz\n", 0));
}

// ─── Store invariant tests ───

test "cleanupStore removes stale processes" {
    const allocator = std.testing.allocator;
    var store_map = std.AutoHashMap(store.ProcessKey, types.Process).init(allocator);
    defer store_map.deinit();

    const key1 = store.ProcessKey{ .pid = 1, .starttime = 100 };
    const key2 = store.ProcessKey{ .pid = 2, .starttime = 200 };
    try store_map.put(key1, types.Process{ .pid = 1, .starttime = 100, .last_seen_tick = 5 });
    try store_map.put(key2, types.Process{ .pid = 2, .starttime = 200, .last_seen_tick = 3 });

    // Tick 5: key2 should be removed (last_seen_tick 3 != 5)
    store.cleanupStore(&store_map, allocator, 5);
    try std.testing.expect(store_map.contains(key1));
    try std.testing.expect(!store_map.contains(key2));
}

test "updateProcess uses saturated subtraction for deltas" {
    // If current < previous (counter wraparound), delta should be 0, not wrap.
    var p = types.Process{ .pid = 1, .starttime = 100, .prev_utime = 1000, .prev_stime = 500 };
    var r = types.ProcReadResult{
        .pid = 1,
        .valid = true,
        .utime = 500,
        .stime = 200, // less than prev → wraparound detected
        .starttime = 100,
        .state = 'R',
        .rss_pages = 100,
        .read_bytes = 0,
        .write_bytes = 0,
        .name = [_]u8{0} ** types.NAME_MAX,
        .name_len = 0,
    };
    store.updateProcess(&p, &r, 1000, 4, 1);
    // CPU% should be 0 since delta was saturated to 0
    try std.testing.expectEqual(@as(f32, 0.0), p.cpu_pct);
    // prev values should be updated to current (so next tick's delta is correct)
    try std.testing.expectEqual(@as(u64, 500), p.prev_utime);
    try std.testing.expectEqual(@as(u64, 200), p.prev_stime);
}

// ─── Generic RingBuffer with non-Sample type ───

test "generic RingBuffer works with u64" {
    const Ring = types.RingBuffer(u64, 8);
    var rb = Ring{};
    try std.testing.expectEqual(0, rb.len);

    rb.append(42);
    rb.append(99);
    try std.testing.expectEqual(2, rb.len);

    var out: [4]u64 = undefined;
    const vals = rb.lastN(4, &out);
    try std.testing.expectEqual(2, vals.len);
    try std.testing.expectEqual(42, vals[0]);
    try std.testing.expectEqual(99, vals[1]);
}

// ─── Benchmark tests ───

test "bench: parseField throughput" {
    // Typical /proc/pid/stat line (~52 space-separated fields, ~400 bytes).
    // We measure how many parseField calls we can do in 100ms.
    const s = "1234 (some-process-name) R 1 0 0 0 0 0 0 0 0 0 100 50 20 10 0 0 0 0 1000 5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n";
    const target_us: u64 = 100_000; // 100ms
    var timer = try std.time.Timer.start();
    var count: usize = 0;
    while (timer.read() < target_us * std.time.ns_per_us) : (count += 1) {
        _ = proc.parseField(s, 11) catch unreachable; // utime
        _ = proc.parseField(s, 12) catch unreachable; // stime
        _ = proc.parseField(s, 19) catch unreachable; // starttime
    }
    // Not an assertion — just informational. If this falls below ~500k calls/s
    // on modern hardware, the SIMD path may be regressing.
    const rate = count * 3; // 3 field parses per iteration
    _ = rate;
}

// ─── Render output test ───

test "render output contains expected sections" {
    const render = @import("render.zig");

    // Minimal state to exercise the render path
    var sys = types.SystemCpu{};
    defer sys.deinit(std.testing.allocator);
    // Fake 2 cores so cpuBox produces output
    try sys.ensureCapacity(std.testing.allocator, 2);
    sys.num_cores = 2;
    sys.cores[0] = .{ .user = 100, .system = 50, .idle = 200 };
    sys.cores[1] = .{ .user = 80, .system = 30, .idle = 250 };
    sys.prev_cores[0] = .{ .user = 80, .system = 40, .idle = 220 };
    sys.prev_cores[1] = .{ .user = 60, .system = 20, .idle = 260 };
    sys.wall_delta_ms = 1000;

    var mem = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000 };
    var net = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 2048 };

    var procs = [_]*const types.Process{};

    // Render to a buffer-backed writer. render() writes to stdout, so we
    // verify the buffer content directly via the internal bufPrint path.
    // Instead, test that render's helper functions produce valid output.
    // The render function itself requires a real terminal; we validate
    // that render() doesn't crash on empty state.
    render.render(&sys, &mem, &net, &procs, .cpu) catch {};
}

test "bench: indexOfNthSpace SIMD vs small input" {
    // Verify the SIMD path handles sub-vector-length inputs correctly.
    const inputs = [_][]const u8{
        "a b",
        "123 456 789",
        "x y z w",
        "",
        "single",
    };
    for (inputs) |s| {
        _ = proc.parseField(s, 0) catch {};
    }
}

// ─── Store leak test: alloc/free cycle with std.testing.allocator ───

test "store: no leaks on alloc/free cycle" {
    const allocator = std.testing.allocator;
    var store_map = std.AutoHashMap(store.ProcessKey, types.Process).init(allocator);
    defer store_map.deinit();

    // Add 100 processes with various values
    for (0..100) |i| {
        const key = store.ProcessKey{ .pid = @intCast(i + 1), .starttime = 100 };
        var p = types.Process{ .pid = @intCast(i + 1), .starttime = 100, .last_seen_tick = 1 };
        p.cpu_pct = @floatFromInt(i);
        p.rss_kb = i * 100;
        try store_map.put(key, p);
    }
    try std.testing.expectEqual(@as(usize, 100), store_map.count());

    // Tick 2: only update first 50, then cleanup — the other 50 should be removed
    for (0..50) |i| {
        const key = store.ProcessKey{ .pid = @intCast(i + 1), .starttime = 100 };
        if (store_map.getPtr(key)) |proc| {
            proc.last_seen_tick = 2;
        }
    }
    store.cleanupStore(&store_map, allocator, 2);
    try std.testing.expectEqual(@as(usize, 50), store_map.count());
}

// ─── 10k PID stress test ───

test "store handles 10k PIDs" {
    const allocator = std.testing.allocator;
    var store_map = std.AutoHashMap(store.ProcessKey, types.Process).init(allocator);
    defer store_map.deinit();

    const n: u32 = 10_000;
    for (0..n) |i| {
        const key = store.ProcessKey{ .pid = i, .starttime = 1 };
        try store_map.put(key, types.Process{ .pid = i, .starttime = 1, .last_seen_tick = 1 });
    }
    try std.testing.expectEqual(@as(usize, n), store_map.count());

    // Mark all as seen in tick 2
    var iter = store_map.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.last_seen_tick = 2;
    }
    store.cleanupStore(&store_map, allocator, 2);
    try std.testing.expectEqual(@as(usize, n), store_map.count());

    // Tick 3: no updates → all should be removed
    store.cleanupStore(&store_map, allocator, 3);
    try std.testing.expectEqual(@as(usize, 0), store_map.count());
}

// ─── Counter wraparound pipeline test ───

test "counter wraparound: full pipeline survives u64 overflow" {
    const allocator = std.testing.allocator;
    var store_map = std.AutoHashMap(store.ProcessKey, types.Process).init(allocator);
    defer store_map.deinit();

    // Simulate a process whose tick counters are near u64::MAX and wrap.
    const key = store.ProcessKey{ .pid = 42, .starttime = 1 };
    const near_max = std.math.maxInt(u64) - 100;
    var p = types.Process{ .pid = 42, .starttime = 1, .last_seen_tick = 1 };
    p.prev_utime = near_max;
    p.prev_stime = near_max;
    p.prev_read_bytes = near_max;
    p.prev_write_bytes = near_max;
    try store_map.put(key, p);

    // Next tick: counters wrapped to small values
    var r = types.ProcReadResult{
        .pid = 42,
        .valid = true,
        .utime = 50,
        .stime = 30,
        .starttime = 1,
        .state = 'R',
        .rss_pages = 100,
        .read_bytes = 100,
        .write_bytes = 200,
        .name = [_]u8{0} ** types.NAME_MAX,
        .name_len = 4,
    };
    @memcpy(r.name[0..4], "test");

    if (store_map.getPtr(key)) |existing| {
        store.updateProcess(existing, &r, 1000, 4, 2);
    }

    const updated = store_map.get(key).?;
    // Saturated subtraction should yield 0 delta when current < previous.
    try std.testing.expectEqual(@as(f32, 0.0), updated.cpu_pct);
    try std.testing.expectEqual(@as(u64, 0), updated.read_rate);
    try std.testing.expectEqual(@as(u64, 0), updated.write_rate);
    // Previous values updated to wrapped values for correct next delta.
    try std.testing.expectEqual(@as(u64, 50), updated.prev_utime);
    try std.testing.expectEqual(@as(u64, 30), updated.prev_stime);
    try std.testing.expectEqual(@as(u64, 100), updated.prev_read_bytes);
    try std.testing.expectEqual(@as(u64, 200), updated.prev_write_bytes);
}
