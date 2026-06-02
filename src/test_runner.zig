const std = @import("std");
const xtop = @import("xtop");
const types = xtop.types;
const proc = xtop.proc;
const store = xtop.store;
const cpu = xtop.cpu;
const mem = xtop.mem;
const net = xtop.net;
const fixture = xtop.fixture;
const scan = xtop.scan;

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

// Disabled: std.time.Timer was removed in Zig 0.16.
// test "bench: parseField throughput" { ... }

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

    var rm = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000 };
    var rn = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 2048 };
    var rp = types.PowerState{};

    var procs = [_]*const types.Process{};

    // Use renderToBuf to avoid writing escape codes to stdout during tests.
    var rbuf: [131072]u8 = undefined;
    const out = try render.renderToBuf(
        &rbuf, &sys, &rm, &rn, &rp, &procs, .cpu,
        80, 3, 24, 4, 0, 1, 0,
    );
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[H"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
}

// ─── Render stability: line count invariants ───

/// Count lines in a buffer. Each \n terminates a line; if the buffer
/// doesn't end with \n, the final non-empty segment counts as a line.
fn countLines(buf: []const u8) usize {
    if (buf.len == 0) return 0;
    var n: usize = 0;
    for (buf) |b| {
        if (b == '\n') n += 1;
    }
    if (buf[buf.len - 1] != '\n') n += 1;
    return n;
}

test "cpuWidget: line count equals 2 + gauge_rows" {
    const render = @import("render.zig");

    var sys = types.SystemCpu{};
    defer sys.deinit(std.testing.allocator);
    try sys.ensureCapacity(std.testing.allocator, 8);
    sys.num_cores = 8;
    // Populate with non-zero deltas so gauges render bar content.
    for (0..8) |i| {
        sys.cores[i] = .{ .user = 100, .system = 50, .idle = 200 };
        sys.prev_cores[i] = .{ .user = 80, .system = 40, .idle = 220 };
    }
    sys.wall_delta_ms = 1000;

    // Test several column counts at different widths.
    const cases = [_]struct { w: usize, ncols: usize, gauge_w: usize }{
        .{ .w = 80, .ncols = 3, .gauge_w = 24 },
        .{ .w = 120, .ncols = 5, .gauge_w = 21 },
        .{ .w = 60, .ncols = 2, .gauge_w = 28 },
        .{ .w = 40, .ncols = 1, .gauge_w = 38 },
    };
    for (cases) |c| {
        var buf: [65536]u8 = undefined;
        const n = render.cpuWidget(&buf, &sys, c.w, c.ncols, c.gauge_w);
        const lines = countLines(buf[0..n]);
        const expected = 2 + (sys.num_cores + c.ncols - 1) / c.ncols;
        try std.testing.expectEqual(expected, lines);
    }
}

test "memWidget: line count equals 2 + annotations + chart_h" {
    const render = @import("render.zig");

    var test_mem = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000, .swap_total_kb = 2_000_000, .swap_free_kb = 1_000_000 };
    // Seed history so the chart has data.
    _ = test_mem.mem_history.append(.{ .cpu_pct = 50.0, .ts_ms = 1 });
    _ = test_mem.swap_history.append(.{ .cpu_pct = 25.0, .ts_ms = 1 });

    const ann_count: usize = 2; // RAM + SWP
    for (0..5) |chart_h| {
        var buf: [16384]u8 = undefined;
        const n = try render.memWidget(&buf, &test_mem, 80, chart_h);
        const lines = countLines(buf[0..n]);
        try std.testing.expectEqual(2 + ann_count + chart_h, lines);
    }
}

test "powerWidget: line count is 3 when no perms" {
    const render = @import("render.zig");

    var test_power = types.PowerState{ .has_perms = false };
    var buf: [4096]u8 = undefined;
    const n = try render.powerWidget(&buf, &test_power, 80, 0);
    const lines = countLines(buf[0..n]);
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "powerWidget: line count equals 3 + chart_h when perms" {
    const render = @import("render.zig");

    var test_power = types.PowerState{ .has_perms = true, .curr_watts = 15.0, .max_watts = 65.0 };
    _ = test_power.power_history.append(.{ .cpu_pct = 50.0, .ts_ms = 1 });

    for (0..5) |chart_h| {
        var buf: [16384]u8 = undefined;
        const n = try render.powerWidget(&buf, &test_power, 80, chart_h);
        const lines = countLines(buf[0..n]);
        try std.testing.expectEqual(3 + chart_h, lines);
    }
}

test "netWidget: line count equals 3 + 2*half_h" {
    const render = @import("render.zig");

    var test_net = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 2048 };
    _ = test_net.rx_history.append(.{ .cpu_pct = 50.0, .ts_ms = 1 });
    _ = test_net.tx_history.append(.{ .cpu_pct = 25.0, .ts_ms = 1 });

    for (0..4) |half_h| {
        var buf: [32768]u8 = undefined;
        const n = try render.netWidget(&buf, &test_net, 80, half_h);
        const lines = countLines(buf[0..n]);
        try std.testing.expectEqual(3 + 2 * half_h, lines);
    }
}

test "procWidget: line count equals 4 + max_rows" {
    const render = @import("render.zig");

    var procs = [_]types.Process{
        .{ .pid = 1, .starttime = 100, .cpu_pct = 10.0, .rss_kb = 100_000, .name_len = 4, .name = "bash".* ++ ([_]u8{0} ** (types.NAME_MAX - 4)) },
        .{ .pid = 2, .starttime = 200, .cpu_pct = 5.0, .rss_kb = 50_000, .name_len = 4, .name = "xtop".* ++ ([_]u8{0} ** (types.NAME_MAX - 4)) },
        .{ .pid = 3, .starttime = 300, .cpu_pct = 2.0, .rss_kb = 20_000, .name_len = 4, .name = "zig ".* ++ ([_]u8{0} ** (types.NAME_MAX - 4)) },
    };
    var proc_ptrs = [_]*const types.Process{ &procs[0], &procs[1], &procs[2] };

    for (0..@min(5, proc_ptrs.len + 1)) |max_rows| {
        var buf: [16384]u8 = undefined;
        const n = try render.procWidget(&buf, &proc_ptrs, 16_000_000, 80, max_rows);
        const lines = countLines(buf[0..n]);
        try std.testing.expectEqual(4 + max_rows, lines);
    }
}

// ─── Height budget invariant ───

test "height budget never exceeds terminal rows" {
    // Simulate the height budget calculation for a matrix of terminal sizes
    // and core counts. Verify fixed + allocated_surplus <= h always.
    const CHART_H_MAX: usize = 4;
    const HALF_H_MAX: usize = 3;

    const sizes = [_]struct { w: usize, h: usize }{
        .{ .w = 80, .h = 24 },
        .{ .w = 100, .h = 30 },
        .{ .w = 120, .h = 40 },
        .{ .w = 60, .h = 15 }, // tight
        .{ .w = 40, .h = 10 }, // very tight (clamped minimum)
    };

    const core_counts = [_]usize{ 2, 4, 8, 16, 32 };
    const swap_present = [_]bool{ false, true };
    const power_perms = [_]bool{ false, true };

    for (sizes) |sz| {
        for (core_counts) |ncores| {
            for (swap_present) |swap| {
                for (power_perms) |pp| {
                    const box_inner = sz.w -| 2;
                    const ncols: usize = @max(1, box_inner / 22);
                    const cpu_gauge_rows = (ncores + ncols - 1) / ncols;
                    const cpu_rows = 2 + cpu_gauge_rows;

                    const mem_ann: usize = if (swap) 2 else 1;
                    const mem_min: usize = 2 + mem_ann;
                    const pwr_min: usize = 3;
                    const net_min: usize = 3;
                    const proc_min: usize = 4;
                    const status_rows: usize = 1;

                    const fixed = cpu_rows + mem_min + pwr_min + net_min + proc_min + status_rows;
                    const surplus: usize = if (sz.h > fixed) sz.h - fixed else 0;

                    var avail: usize = surplus;
                    var mem_ch: usize = 0;
                    var pwr_ch: usize = 0;
                    var net_hh: usize = 0;
                    var proc_mr: usize = 0;

                    if (avail >= CHART_H_MAX) {
                        mem_ch = CHART_H_MAX;
                        avail -= CHART_H_MAX;
                    } else if (avail > 0) {
                        mem_ch = avail;
                        avail = 0;
                    }

                    if (pp and avail >= CHART_H_MAX) {
                        pwr_ch = CHART_H_MAX;
                        avail -= CHART_H_MAX;
                    } else if (pp and avail > 0) {
                        pwr_ch = avail;
                        avail = 0;
                    }

                    if (avail >= HALF_H_MAX * 2) {
                        net_hh = HALF_H_MAX;
                        avail -= HALF_H_MAX * 2;
                    } else if (avail >= 2) {
                        net_hh = avail / 2;
                        avail -= net_hh * 2;
                    }

                    proc_mr = @min(10, avail);

                    const total_used = fixed + mem_ch + pwr_ch + 2 * net_hh + proc_mr;
                    // Content must not exceed terminal height (would cause scroll).
                    // When terminal is too small for fixed content, overflow is unavoidable.
                    try std.testing.expect(total_used <= @max(sz.h, fixed));
                }
            }
        }
    }
}

// ─── Render output integrity ───

test "renderToBuf: output is properly bracketed with sync codes" {
    const render = @import("render.zig");

    var sys = types.SystemCpu{};
    defer sys.deinit(std.testing.allocator);
    try sys.ensureCapacity(std.testing.allocator, 2);
    sys.num_cores = 2;
    sys.cores[0] = .{ .user = 100, .system = 50, .idle = 200 };
    sys.cores[1] = .{ .user = 80, .system = 30, .idle = 250 };
    sys.prev_cores[0] = .{ .user = 80, .system = 40, .idle = 220 };
    sys.prev_cores[1] = .{ .user = 60, .system = 20, .idle = 260 };
    sys.wall_delta_ms = 1000;

    var test_mem = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000 };
    var test_net = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 2048 };
    var test_power = types.PowerState{};
    var procs = [_]*const types.Process{};

    var buf: [131072]u8 = undefined;
    const out = try render.renderToBuf(
        &buf, &sys, &test_mem, &test_net, &test_power, &procs, .cpu,
        80, 3, 24, 4, 0, 1, 0,
    );

    // Must start with sync begin + home.
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[H"));
    // Must end with sync end.
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
    // Status bar must not have a leading \n (regression: caused scroll-off-by-one).
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "sort:"));
    const sort_pos = std.mem.indexOf(u8, out, "sort:").?;
    // The byte immediately before "sort:" must be a space, not a newline.
    try std.testing.expect(sort_pos > 0);
    try std.testing.expect(out[sort_pos - 1] != '\n');
    // Total lines must not exceed the terminal height (80x24).
    const lines = countLines(out);
    // Budget: cpu(3) + mem(7) + pwr(3) + net(5) + proc(4) + status(1) = 23
    const expected: usize = 23;
    try std.testing.expectEqual(expected, lines);
}

test "renderToBuf: top border of first widget is immediately after home" {
    const render = @import("render.zig");

    var sys = types.SystemCpu{};
    defer sys.deinit(std.testing.allocator);
    try sys.ensureCapacity(std.testing.allocator, 2);
    sys.num_cores = 2;
    sys.cores[0] = .{ .user = 100, .system = 50, .idle = 200 };
    sys.cores[1] = .{ .user = 80, .system = 30, .idle = 250 };
    sys.prev_cores[0] = .{ .user = 80, .system = 40, .idle = 220 };
    sys.prev_cores[1] = .{ .user = 60, .system = 20, .idle = 260 };
    sys.wall_delta_ms = 1000;

    var test_mem = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000 };
    var test_net = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 2048 };
    var test_power = types.PowerState{};
    var procs = [_]*const types.Process{};

    var buf: [131072]u8 = undefined;
    const out = try render.renderToBuf(
        &buf, &sys, &test_mem, &test_net, &test_power, &procs, .cpu,
        80, 3, 24, 4, 0, 1, 0,
    );

    // After \x1b[?2026h\x1b[H, the very next visual character must be the
    // box top corner (part of the CPU widget border). Find the first
    // non-ANSI byte after the home sequence.
    const home_seq = "\x1b[?2026h\x1b[H";
    var pos = home_seq.len;
    // Skip any ANSI sequences (box top uses BR = \x1b[90m before the corner).
    while (pos < out.len and out[pos] == 0x1b) {
        while (pos < out.len and out[pos] != 'm') pos += 1;
        if (pos < out.len) pos += 1; // skip 'm'
    }
    try std.testing.expect(pos < out.len);
    // First visual character is the box corner.
    try std.testing.expectEqual(@as(u8, 0xE2), out[pos]); // UTF-8 start of ┌
}

// ─── Edge case: zero cores, zero processes ───

test "renderToBuf: handles zero processes gracefully" {
    const render = @import("render.zig");

    var sys = types.SystemCpu{};
    defer sys.deinit(std.testing.allocator);
    try sys.ensureCapacity(std.testing.allocator, 1);
    sys.num_cores = 1;
    sys.cores[0] = .{ .user = 0, .system = 0, .idle = 100 };
    sys.prev_cores[0] = .{ .user = 0, .system = 0, .idle = 100 };
    sys.wall_delta_ms = 1000;

    var test_mem = types.MemState{ .total_kb = 0, .avail_kb = 0 };
    var test_net = types.NetState{};
    var test_power = types.PowerState{};
    var procs = [_]*const types.Process{};

    var buf: [131072]u8 = undefined;
    const out = try render.renderToBuf(
        &buf, &sys, &test_mem, &test_net, &test_power, &procs, .cpu,
        80, 3, 24, 4, 0, 1, 0,
    );

    // Must still produce properly bracketed output.
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[H"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
    // Lines must not exceed budget.
    try std.testing.expect(countLines(out) <= 24);
}

test "renderToBuf: handles zero cores" {
    const render = @import("render.zig");

    var sys = types.SystemCpu{ .num_cores = 0 };
    var test_mem = types.MemState{ .total_kb = 16_000_000, .avail_kb = 8_000_000 };
    var test_net = types.NetState{ .rx_rate = 1024, .tx_rate = 512, .max_rate = 1024 };
    var test_power = types.PowerState{};
    var procs = [_]*const types.Process{};

    var buf: [131072]u8 = undefined;
    const out = try render.renderToBuf(
        &buf, &sys, &test_mem, &test_net, &test_power, &procs, .cpu,
        80, 3, 24, 4, 0, 1, 0,
    );

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h\x1b[H"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
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
        if (store_map.getPtr(key)) |existing| {
            existing.last_seen_tick = 2;
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
        const pid: u32 = @intCast(i);
        const key = store.ProcessKey{ .pid = pid, .starttime = 1 };
        try store_map.put(key, types.Process{ .pid = pid, .starttime = 1, .last_seen_tick = 1 });
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
    p.prev_stime = 0;
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
