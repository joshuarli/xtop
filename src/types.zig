const std = @import("std");

pub const Pid = u32;

pub const NAME_MAX = 64;
pub const RING_SIZE = 300;
pub const SPARK_WIDTH = 30;
pub const TOP_N = 20;
pub const MAX_CPUS = 512;

pub const Sample = struct {
    cpu_pct: f32,
    ts_ms: u64,
};

pub const RingBuffer = struct {
    data: [RING_SIZE]Sample = [_]Sample{.{ .cpu_pct = 0, .ts_ms = 0 }} ** RING_SIZE,
    head: usize = 0,
    len: usize = 0,

    pub fn append(rb: *RingBuffer, sample: Sample) void {
        rb.data[rb.head] = sample;
        rb.head = (rb.head + 1) % RING_SIZE;
        if (rb.len < RING_SIZE) rb.len += 1;
    }

    /// Return the last N values from the ringbuffer in chronological order.
    pub fn lastN(rb: *const RingBuffer, n: usize, out: []f32) []f32 {
        const count = @min(n, rb.len);
        if (count == 0) return out[0..0];
        const start = (rb.head + RING_SIZE - count) % RING_SIZE;
        for (0..count) |i| {
            const idx = (start + i) % RING_SIZE;
            out[i] = rb.data[idx].cpu_pct;
        }
        return out[0..count];
    }

    pub fn sparkline(rb: *const RingBuffer, buf: []u8) []const u8 {
        if (rb.len == 0) return "";
        const step = @max(1, rb.len / SPARK_WIDTH);
        var out_len: usize = 0;
        var i: usize = 0;
        while (i < rb.len and out_len + 3 <= buf.len) : (i += step) {
            const idx = (rb.head + RING_SIZE - rb.len + i) % RING_SIZE;
            const level = sparkLevel(rb.data[idx].cpu_pct);
            const bytes = SPARK_CHARS[level];
            buf[out_len] = bytes[0];
            buf[out_len + 1] = bytes[1];
            buf[out_len + 2] = bytes[2];
            out_len += 3;
        }
        return buf[0..out_len];
    }

    fn sparkLevel(cpu_pct: f32) u3 {
        if (cpu_pct <= 0) return 0;
        // 8 spark levels: 0..7
        // Each level represents ~12.5% normalized CPU (100% / 8)
        const level: usize = @intFromFloat(@min(@floor(cpu_pct / 12.5), 7));
        return @intCast(level);
    }
};

const SPARK_CHARS = [_][3]u8{
    [_]u8{ 0xE2, 0x96, 0x81 }, // ▁
    [_]u8{ 0xE2, 0x96, 0x82 }, // ▂
    [_]u8{ 0xE2, 0x96, 0x83 }, // ▃
    [_]u8{ 0xE2, 0x96, 0x84 }, // ▄
    [_]u8{ 0xE2, 0x96, 0x85 }, // ▅
    [_]u8{ 0xE2, 0x96, 0x86 }, // ▆
    [_]u8{ 0xE2, 0x96, 0x87 }, // ▇
    [_]u8{ 0xE2, 0x96, 0x88 }, // █
};

pub const Process = struct {
    pid: Pid,
    starttime: u64,
    name: [NAME_MAX]u8 = [_]u8{0} ** NAME_MAX,
    name_len: u8 = 0,
    prev_utime: u64 = 0,
    prev_stime: u64 = 0,
    cpu_pct: f32 = 0,
    rss_kb: u64 = 0,
    prev_read_bytes: u64 = 0,
    prev_write_bytes: u64 = 0,
    read_rate: u64 = 0, // bytes per second
    write_rate: u64 = 0,
    ring: ?*RingBuffer = null,
    last_seen_tick: u64 = 0,
};

pub const CpuCore = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,
    guest: u64 = 0,
    guest_nice: u64 = 0,

    pub fn total(c: CpuCore) u64 {
        return c.user + c.nice + c.system + c.idle + c.iowait +
            c.irq + c.softirq + c.steal + c.guest + c.guest_nice;
    }

    pub fn active(c: CpuCore) u64 {
        return c.user + c.nice + c.system + c.irq + c.softirq + c.steal + c.guest + c.guest_nice;
    }
};

pub const SystemCpu = struct {
    cores: [MAX_CPUS]CpuCore = [_]CpuCore{.{}} ** MAX_CPUS,
    num_cores: usize = 0,
    prev_cores: [MAX_CPUS]CpuCore = [_]CpuCore{.{}} ** MAX_CPUS,
    core_history: [MAX_CPUS]RingBuffer = [_]RingBuffer{RingBuffer{}} ** MAX_CPUS,
    wall_delta_ms: u64 = 0,
};

pub const MemState = struct {
    total_kb: u64 = 0,
    avail_kb: u64 = 0,
    swap_total_kb: u64 = 0,
    swap_free_kb: u64 = 0,
    mem_history: RingBuffer = RingBuffer{},
    swap_history: RingBuffer = RingBuffer{},
};

pub const NetState = struct {
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    prev_rx_bytes: u64 = 0,
    prev_tx_bytes: u64 = 0,
    rx_rate: u64 = 0,
    tx_rate: u64 = 0,
    rx_total: u64 = 0,
    tx_total: u64 = 0,
    rx_history: RingBuffer = RingBuffer{},
    tx_history: RingBuffer = RingBuffer{},
    max_rate: u64 = 1024,
};

pub const ProcReadResult = struct {
    pid: Pid,
    valid: bool,
    utime: u64,
    stime: u64,
    starttime: u64,
    state: u8,
    rss_pages: u64,
    read_bytes: u64,
    write_bytes: u64,
    name: [NAME_MAX]u8,
    name_len: u8,
};

pub const SortKey = enum {
    cpu,
    mem,
};

test "RingBuffer append and lastN" {
    var rb = RingBuffer{};
    try std.testing.expectEqual(0, rb.len);
    try std.testing.expectEqual(0, rb.head);

    rb.append(.{ .cpu_pct = 10.0, .ts_ms = 1 });
    try std.testing.expectEqual(1, rb.len);
    rb.append(.{ .cpu_pct = 20.0, .ts_ms = 2 });
    try std.testing.expectEqual(2, rb.len);
    rb.append(.{ .cpu_pct = 30.0, .ts_ms = 3 });
    try std.testing.expectEqual(3, rb.len);

    var out: [10]f32 = undefined;
    const vals = rb.lastN(3, &out);
    try std.testing.expectEqual(3, vals.len);
    try std.testing.expectApproxEqAbs(10.0, vals[0], 0.01);
    try std.testing.expectApproxEqAbs(20.0, vals[1], 0.01);
    try std.testing.expectApproxEqAbs(30.0, vals[2], 0.01);
}

test "RingBuffer wrap around" {
    var rb = RingBuffer{};
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        rb.append(.{ .cpu_pct = @floatFromInt(i), .ts_ms = @intCast(i) });
    }
    try std.testing.expectEqual(300, rb.len);
    // Next append wraps
    rb.append(.{ .cpu_pct = 300.0, .ts_ms = 300 });
    try std.testing.expectEqual(300, rb.len); // still 300, oldest dropped

    var out: [5]f32 = undefined;
    const vals = rb.lastN(5, &out);
    try std.testing.expectEqual(5, vals.len);
    try std.testing.expectApproxEqAbs(296.0, vals[0], 0.01);
    try std.testing.expectApproxEqAbs(300.0, vals[4], 0.01);
}

test "RingBuffer sparkline" {
    var rb = RingBuffer{};
    rb.append(.{ .cpu_pct = 0.0, .ts_ms = 1 });
    rb.append(.{ .cpu_pct = 50.0, .ts_ms = 2 });
    rb.append(.{ .cpu_pct = 100.0, .ts_ms = 3 });

    var buf: [90]u8 = undefined;
    const spark = rb.sparkline(&buf);
    try std.testing.expect(spark.len > 0);
}
