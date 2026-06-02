const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) @compileError("xtop is Linux-only");
}

pub const Pid = u32;

pub const NAME_MAX = 64;
pub const RING_SIZE = 300;
pub const TOP_N = 10;
/// Fallback upper bound for core count (used only if /proc/stat can't be read).
pub const MAX_CPUS_FALLBACK = 64;

pub const Sample = struct {
    cpu_pct: f32,
    ts_ms: u64,
};

pub const charset = struct {
    pub const is_digit: [256]bool = blk: {
        var t = [_]bool{false} ** 256;
        for ("0123456789") |c| t[c] = true;
        break :blk t;
    };

    pub const is_space: [256]bool = blk: {
        var t = [_]bool{false} ** 256;
        t[' '] = true;
        t['\t'] = true;
        t['\n'] = true;
        t['\r'] = true;
        break :blk t;
    };
};

pub fn RingBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        data: [size]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn append(self: *Self, item: T) void {
            self.data[self.head] = item;
            self.head = (self.head + 1) % size;
            if (self.len < size) self.len += 1;
        }

        pub fn lastN(self: *const Self, n: usize, out: []T) []T {
            const count = @min(n, self.len);
            if (count == 0) return out[0..0];
            const start = (self.head + size - count) % size;
            for (0..count) |i| {
                const idx = (start + i) % size;
                out[i] = self.data[idx];
            }
            return out[0..count];
        }
    };
}

pub const SampleRing = RingBuffer(Sample, RING_SIZE);

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
    read_rate: u64 = 0,
    write_rate: u64 = 0,
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

/// Per-core CPU state. Core arrays are heap-allocated on first readCpuStat()
/// to match the actual core count — no wasted virtual memory on small machines.
pub const SystemCpu = struct {
    cores: []CpuCore = &.{},
    num_cores: usize = 0,
    prev_cores: []CpuCore = &.{},
    wall_delta_ms: u64 = 0,

    /// Allocate (or reallocate) core arrays for `n` cores. Safe to call
    /// redundantly — if capacity already matches, it's a no-op.
    /// On allocation failure, the previous state is preserved.
    pub fn ensureCapacity(self: *SystemCpu, allocator: std.mem.Allocator, n: usize) !void {
        if (self.cores.len == n) return;
        const new_cores = try allocator.alloc(CpuCore, n);
        errdefer allocator.free(new_cores);
        const new_prev = try allocator.alloc(CpuCore, n);
        self.deinit(allocator);
        self.cores = new_cores;
        self.prev_cores = new_prev;
        @memset(self.cores, .{});
        @memset(self.prev_cores, .{});
    }

    /// Free all core arrays. Safe to call on a zeroed struct.
    pub fn deinit(self: *SystemCpu, allocator: std.mem.Allocator) void {
        if (self.cores.len > 0) allocator.free(self.cores);
        if (self.prev_cores.len > 0) allocator.free(self.prev_cores);
        self.cores = &.{};
        self.prev_cores = &.{};
        self.num_cores = 0;
    }
};

pub const MemState = struct {
    total_kb: u64 = 0,
    avail_kb: u64 = 0,
    swap_total_kb: u64 = 0,
    swap_free_kb: u64 = 0,
    mem_history: SampleRing = SampleRing{},
    swap_history: SampleRing = SampleRing{},
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
    rx_history: SampleRing = SampleRing{},
    tx_history: SampleRing = SampleRing{},
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

pub const PowerState = struct {
    curr_watts: f64 = 0,
    max_watts: f64 = 1.0,
    power_history: SampleRing = SampleRing{},
    has_perms: bool = true,
    prev_energy_uj: u64 = 0,
    max_energy_range_uj: u64 = 0,
};

pub const SortKey = enum {
    cpu,
    mem,
};

// Comptime-computed buffer sizes for /proc path construction.
// Pid is u32, so max 10 decimal digits. Each path is:
//   "/proc/" + <max 10 digits> + "/suffix" + null terminator
pub const proc_path = struct {
    pub const pid_digits_max = 10; // ceil(log10(2^32))
    pub const prefix_len = "/proc/".len;

    pub const cmdline_max: usize = prefix_len + pid_digits_max + "/cmdline".len + 1;
    pub const stat_max: usize = prefix_len + pid_digits_max + "/stat".len + 1;
    pub const statm_max: usize = prefix_len + pid_digits_max + "/statm".len + 1;
    pub const io_max: usize = prefix_len + pid_digits_max + "/io".len + 1;
};

test "RingBuffer append and lastN" {
    var rb = SampleRing{};
    try std.testing.expectEqual(0, rb.len);
    try std.testing.expectEqual(0, rb.head);

    rb.append(.{ .cpu_pct = 10.0, .ts_ms = 1 });
    try std.testing.expectEqual(1, rb.len);
    rb.append(.{ .cpu_pct = 20.0, .ts_ms = 2 });
    try std.testing.expectEqual(2, rb.len);
    rb.append(.{ .cpu_pct = 30.0, .ts_ms = 3 });
    try std.testing.expectEqual(3, rb.len);

    var out: [10]Sample = undefined;
    const vals = rb.lastN(3, &out);
    try std.testing.expectEqual(3, vals.len);
    try std.testing.expectApproxEqAbs(10.0, vals[0].cpu_pct, 0.01);
    try std.testing.expectApproxEqAbs(20.0, vals[1].cpu_pct, 0.01);
    try std.testing.expectApproxEqAbs(30.0, vals[2].cpu_pct, 0.01);
}

test "RingBuffer wrap around" {
    var rb = SampleRing{};
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        rb.append(.{ .cpu_pct = @floatFromInt(i), .ts_ms = @intCast(i) });
    }
    try std.testing.expectEqual(300, rb.len);
    rb.append(.{ .cpu_pct = 300.0, .ts_ms = 300 });
    try std.testing.expectEqual(300, rb.len);

    var out: [5]Sample = undefined;
    const vals = rb.lastN(5, &out);
    try std.testing.expectEqual(5, vals.len);
    try std.testing.expectApproxEqAbs(296.0, vals[0].cpu_pct, 0.01);
    try std.testing.expectApproxEqAbs(300.0, vals[4].cpu_pct, 0.01);
}

test "charset tables" {
    for ("0123456789") |c| try std.testing.expect(charset.is_digit[c]);
    try std.testing.expect(!charset.is_digit['a']);
    try std.testing.expect(!charset.is_digit['/']);
    try std.testing.expect(!charset.is_digit[':']);
}
