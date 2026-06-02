const std = @import("std");
const builtin = @import("builtin");
const xtop = @import("xtop");
const types = xtop.types;
const proc = xtop.proc;
const scan = xtop.scan;
const cpu = xtop.cpu;
const mem = xtop.mem;
const net = xtop.net;
const power = xtop.power;
const store = xtop.store;

const linux = std.os.linux;
const Io = std.Io;
const Pid = types.Pid;
const Process = types.Process;
const ProcReadResult = types.ProcReadResult;
const SystemCpu = types.SystemCpu;
const MemState = types.MemState;
const NetState = types.NetState;
const PowerState = types.PowerState;
const SortKey = types.SortKey;
const TOP_N = types.TOP_N;

const ProcessKey = store.ProcessKey;
const ProcessMap = store.ProcessMap;
const PidMap = store.PidMap;
const render = @import("render.zig");

var shutdown_flag = std.atomic.Value(bool).init(false);
var resize_flag = std.atomic.Value(bool).init(false);
var key_event = std.atomic.Value(u8).init(0);
var saved_termios: ?std.posix.termios = null;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    // Parse CLI flags before entering raw mode (so help/version print normally).
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_iter.skip(); // skip program name
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buf: [512]u8 = undefined;
            var stdout_file = std.Io.File.stdout().writer(init.io, &buf);
            try stdout_file.interface.writeAll(
                \\xtop — Linux process monitor
                \\
                \\Usage: xtop [flags]
                \\
                \\Flags:
                \\  -h, --help      Print this help and exit
                \\  --version       Print version and exit
                \\
                \\Keys:
                \\  c               Sort by CPU
                \\  m               Sort by memory
                \\  q               Quit
                \\
            );
            return;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [256]u8 = undefined;
            var stdout_file = std.Io.File.stdout().writer(init.io, &buf);
            try stdout_file.interface.print("xtop {s}\n", .{getVersion()});
            return;
        }
    }

    const original_termios = try render.enterRawMode();
    defer render.restoreTerminal(original_termios);
    saved_termios = original_termios;
    setupSignals();

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const input_thread = try std.Thread.spawn(.{}, inputThreadFn, .{});
    defer input_thread.join();

    var syscpu = SystemCpu{};
    defer syscpu.deinit(allocator);
    var mem_state = MemState{};
    var net_state = NetState{};
    var power_state = PowerState{};
    var proc_store = ProcessMap.init(allocator);
    defer proc_store.deinit();
    var proc_list = std.ArrayList(*Process).empty;
    defer proc_list.deinit(allocator);
    var pid_to_key = PidMap.init(allocator);
    defer pid_to_key.deinit();

    mem.readMemInfo(&mem_state);
    net.readNetDev(&net_state);
    power.readPowerInfo(&power_state);

    var sort_key: SortKey = .cpu;
    var tick: u64 = 0;

    while (!shutdown_flag.load(.acquire)) {
        tick += 1;
        const tick_start = Io.Timestamp.now(io, .awake);

        if (resize_flag.swap(false, .acq_rel)) {}

        const pressed = key_event.swap(0, .acq_rel);
        switch (pressed) {
            'c' => sort_key = .cpu,
            'm' => sort_key = .mem,
            'q' => {
                @branchHint(.unlikely);
                shutdown_flag.store(true, .release);
            },
            else => {},
        }
        if (shutdown_flag.load(.acquire)) break;

        try runTick(allocator, io, tick, &syscpu, &mem_state, &net_state, &power_state, &proc_store, &proc_list, &pid_to_key, sort_key, null);

        const elapsed = Io.Timestamp.now(io, .awake);
        const sleep_ns: i96 = @as(i96, std.time.ns_per_s) -| tick_start.durationTo(elapsed).nanoseconds;
        if (sleep_ns > 0 and !shutdown_flag.load(.acquire)) sleepNs(sleep_ns);
    }
}

/// Execute one tick: scan, read, process, sort, render.
fn runTick(
    allocator: std.mem.Allocator,
    io: Io,
    tick: u64,
    syscpu: *SystemCpu,
    mem_state: *MemState,
    net_state: *NetState,
    power_state: *PowerState,
    proc_store: *ProcessMap,
    proc_list: *std.ArrayList(*Process),
    pid_to_key: *PidMap,
    sort_key: SortKey,
    capture_dir: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const pid_max = readPidMax();
    const pid_buf = try aa.alloc(Pid, pid_max);
    const pids = scan.scanProc(pid_buf) catch |err| {
        logErr("scan", err);
        return;
    };

    cpu.readCpuStat(syscpu, allocator) catch |err| {
        logErr("cpu", err);
    };

    mem.readMemInfo(mem_state);
    net.readNetDev(net_state);
    power.readPowerInfo(power_state);

    // System history
    const mp: f32 = if (mem_state.total_kb > 0)
        @as(f32, @floatFromInt(mem_state.total_kb -| mem_state.avail_kb)) / @as(f32, @floatFromInt(mem_state.total_kb)) * 100.0
    else
        0;
    mem_state.mem_history.append(.{ .cpu_pct = mp, .ts_ms = @intCast(tick) });
    if (mem_state.swap_total_kb > 0) {
        const sp: f32 = @as(f32, @floatFromInt(mem_state.swap_total_kb -| mem_state.swap_free_kb)) / @as(f32, @floatFromInt(mem_state.swap_total_kb)) * 100.0;
        mem_state.swap_history.append(.{ .cpu_pct = sp, .ts_ms = @intCast(tick) });
    }
    const nmax = @max(net_state.rx_rate, net_state.tx_rate);
    if (nmax > net_state.max_rate) net_state.max_rate = nmax;
    if (net_state.max_rate < 1024) net_state.max_rate = 1024;
    if (net_state.max_rate > 0) {
        net_state.rx_history.append(.{ .cpu_pct = @as(f32, @floatFromInt(net_state.rx_rate)) / @as(f32, @floatFromInt(net_state.max_rate)) * 100.0, .ts_ms = @intCast(tick) });
        net_state.tx_history.append(.{ .cpu_pct = @as(f32, @floatFromInt(net_state.tx_rate)) / @as(f32, @floatFromInt(net_state.max_rate)) * 100.0, .ts_ms = @intCast(tick) });
    }
    if (power_state.has_perms and power_state.prev_energy_uj > 0) {
        const pp: f32 = @floatCast(power_state.curr_watts / power_state.max_watts * 100.0);
        power_state.power_history.append(.{ .cpu_pct = pp, .ts_ms = @intCast(tick) });
    }

    // Async proc reads — futures use arena since they live exactly one tick
    var futures: std.ArrayList(Io.Future(ProcReadResult)) = .empty;
    try futures.ensureTotalCapacity(aa, pids.len);
    for (pids) |pid| {
        futures.appendAssumeCapacity(Io.async(io, proc.readProcData, .{pid}));
    }

    for (futures.items) |*future| {
        const result = future.await(io);
        if (!result.valid) continue;
        const key = ProcessKey{ .pid = result.pid, .starttime = result.starttime };
        if (proc_store.getPtr(key)) |existing| {
            store.updateProcess(existing, &result, syscpu.wall_delta_ms, syscpu.num_cores, tick);
        } else {
            // O(1) PID-reuse detection via secondary index
            if (pid_to_key.get(result.pid)) |old_key| {
                if (old_key.starttime != result.starttime) {
                    _ = proc_store.remove(old_key);
                }
            }
            pid_to_key.put(result.pid, key) catch |err| {
                logErr("pid_to_key", err);
            };
            var new_proc = Process{ .pid = result.pid, .starttime = result.starttime };
            store.updateProcess(&new_proc, &result, syscpu.wall_delta_ms, syscpu.num_cores, tick);
            proc_store.put(key, new_proc) catch |err| {
                logErr("proc_store.put", err);
                continue;
            };
        }
    }
    // futures deinit not needed — arena handles it

    store.cleanupStore(proc_store, allocator, tick);

    proc_list.clearRetainingCapacity();
    var iter = proc_store.iterator();
    while (iter.next()) |entry| {
        proc_list.append(allocator, entry.value_ptr) catch break;
    }
    switch (sort_key) {
        .cpu => std.mem.sort(*Process, proc_list.items, {}, store.cmpByCpu),
        .mem => std.mem.sort(*Process, proc_list.items, {}, store.cmpByMem),
    }
    const top = if (proc_list.items.len < TOP_N) proc_list.items else proc_list.items[0..TOP_N];

    if (capture_dir) |dir| {
        try captureTick(dir, tick, syscpu, mem_state, net_state, proc_list);
    } else {
        render.render(syscpu, mem_state, net_state, power_state, top, sort_key) catch |err| {
            logErr("render", err);
        };
    }
}

fn inputThreadFn() void {
    var buf: [1]u8 = undefined;
    while (!shutdown_flag.load(.acquire)) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch continue;
        if (n == 1) {
            key_event.store(buf[0], .monotonic);
            if (buf[0] == 'q') {
                shutdown_flag.store(true, .release);
                return;
            }
        }
    }
}

fn setupSignals() void {
    const act = std.posix.Sigaction{ .handler = .{ .handler = sigwinchHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.WINCH, &act, null);
    const ta = std.posix.Sigaction{ .handler = .{ .handler = sigtermHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &ta, null);
    std.posix.sigaction(.TERM, &ta, null);
    const tstp = std.posix.Sigaction{ .handler = .{ .handler = sigtstpHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TSTP, &tstp, null);
    const cont = std.posix.Sigaction{ .handler = .{ .handler = sigcontHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.CONT, &cont, null);
}

fn sigwinchHandler(_: std.posix.SIG) callconv(.c) void {
    resize_flag.store(true, .monotonic);
}
fn sigtermHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_flag.store(true, .release);
}
fn sigtstpHandler(_: std.posix.SIG) callconv(.c) void {
    if (saved_termios) |t| {
        _ = linux.write(std.posix.STDOUT_FILENO, @as([*]const u8, @ptrCast("\x1b[?1049l\x1b[?25h")), 12);
        std.posix.tcsetattr(std.posix.STDOUT_FILENO, .FLUSH, t) catch {};
    }
    const dfl = std.posix.Sigaction{ .handler = .{ .handler = linux.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TSTP, &dfl, null);
    std.posix.raise(.TSTP) catch {};
}

fn sigcontHandler(_: std.posix.SIG) callconv(.c) void {
    if (saved_termios) |_| {
        _ = linux.write(std.posix.STDOUT_FILENO, @as([*]const u8, @ptrCast("\x1b[?1049h\x1b[H")), 11);
    }
    const tstp = std.posix.Sigaction{ .handler = .{ .handler = sigtstpHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TSTP, &tstp, null);
}

fn readCmdlineFlag(allocator: std.mem.Allocator, flag: []const u8) ?[]const u8 {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/self/cmdline", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return null;
    var args = std.mem.splitScalar(u8, buf[0..n], 0);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            if (args.next()) |val| {
                if (val.len > 0) return allocator.dupeZ(u8, val) catch null;
            }
        }
    }
    return null;
}

fn runCapture(allocator: std.mem.Allocator, cap_dir: []const u8) !void {
    const msg = "CAPTURE_START\n";
    _ = linux.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
    setupSignals();
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var syscpu = SystemCpu{};
    defer syscpu.deinit(allocator);
    var mem_state = MemState{};
    var net_state = NetState{};
    var power_state = PowerState{};
    var proc_store = ProcessMap.init(allocator);
    defer proc_store.deinit();
    var proc_list = std.ArrayList(*Process).empty;
    defer proc_list.deinit(allocator);
    var pid_to_key = PidMap.init(allocator);
    defer pid_to_key.deinit();
    mem.readMemInfo(&mem_state);
    net.readNetDev(&net_state);
    power.readPowerInfo(&power_state);

    const max_ticks: u64 = 5;
    var tick: u64 = 0;
    while (tick < max_ticks and !shutdown_flag.load(.acquire)) {
        tick += 1;
        const t0 = Io.Timestamp.now(io, .awake);
        try runTick(allocator, io, tick, &syscpu, &mem_state, &net_state, &power_state, &proc_store, &proc_list, &pid_to_key, .cpu, cap_dir);
        try captureTick(cap_dir, tick, &syscpu, &mem_state, &net_state, &proc_list);
        const elap = Io.Timestamp.now(io, .awake);
        const sn: i96 = @as(i96, std.time.ns_per_s) -| t0.durationTo(elap).nanoseconds;
        if (sn > 0) sleepNs(sn);
    }
}

fn captureTick(dir: []const u8, tick: u64, sys: *const SystemCpu, m: *const MemState, n: *const NetState, procs: *const std.ArrayList(*Process)) !void {
    var pb: [256]u8 = undefined;
    const td = std.fmt.bufPrint(&pb, "{s}/{d:0>4}", .{ dir, tick }) catch {
        _ = linux.write(std.posix.STDERR_FILENO, @as([*]const u8, @ptrCast("bufprint fail\n")), 14);
        return;
    };
    _ = linux.write(std.posix.STDERR_FILENO, @as([*]const u8, @ptrCast("td=")), 3);
    _ = linux.write(std.posix.STDERR_FILENO, td.ptr, td.len);
    _ = linux.write(std.posix.STDERR_FILENO, @as([*]const u8, @ptrCast("\n")), 1);

    const mkret = linux.mkdirat(std.posix.AT.FDCWD, @as([*:0]const u8, @ptrCast(td)), 0o755);
    if (mkret != 0) {
        _ = linux.write(std.posix.STDERR_FILENO, @as([*]const u8, @ptrCast("mkdir failed\n")), 13);
        return;
    }

    var buf: [8192]u8 = undefined;

    // CPU
    {
        var o: usize = 0;
        o += (try std.fmt.bufPrint(buf[o..], "num_cores={d} wall_delta_ms={d}\n", .{ sys.num_cores, sys.wall_delta_ms })).len;
        for (sys.cores[0..sys.num_cores], 0..) |c, i| {
            o += (try std.fmt.bufPrint(buf[o..], "core{d} user={d} nice={d} system={d} idle={d} iowait={d} irq={d} softirq={d} steal={d} guest={d} guest_nice={d}\n", .{ i, c.user, c.nice, c.system, c.idle, c.iowait, c.irq, c.softirq, c.steal, c.guest, c.guest_nice })).len;
        }
        writeFile(td, "cpu", buf[0..o]);
    }

    // Mem
    {
        var o: usize = 0;
        o += (try std.fmt.bufPrint(buf[o..], "total_kb={d} avail_kb={d} swap_total_kb={d} swap_free_kb={d}\n", .{ m.total_kb, m.avail_kb, m.swap_total_kb, m.swap_free_kb })).len;
        writeFile(td, "mem", buf[0..o]);
    }

    // Net
    {
        var o: usize = 0;
        o += (try std.fmt.bufPrint(buf[o..], "rx_rate={d} tx_rate={d} rx_total={d} tx_total={d}\n", .{ n.rx_rate, n.tx_rate, n.rx_total, n.tx_total })).len;
        writeFile(td, "net", buf[0..o]);
    }

    // Procs
    {
        var o: usize = 0;
        o += (try std.fmt.bufPrint(buf[o..], "{d}\n", .{procs.items.len})).len;
        for (procs.items) |p| {
            o += (try std.fmt.bufPrint(buf[o..], "{d} {d} {d:.1} {d} {d} {d} {s}\n", .{ p.pid, p.starttime, p.cpu_pct, p.rss_kb, p.read_rate, p.write_rate, p.name[0..p.name_len] })).len;
        }
        writeFile(td, "procs", buf[0..o]);
    }
}

fn writeFile(dir: []const u8, name: []const u8, data: []const u8) void {
    var pb: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, name }) catch return;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return;
    defer _ = linux.close(fd);
    _ = linux.write(fd, data.ptr, data.len);
}

fn getVersion() []const u8 {
    if (@hasDecl(@import("root"), "build_options")) {
        return @import("root").build_options.version;
    }
    return "unknown";
}

fn readPidMax() usize {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/sys/kernel/pid_max", .{ .ACCMODE = .RDONLY }, 0) catch return 32768;
    defer _ = linux.close(fd);
    var buf: [16]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return 32768;
    const val = std.fmt.parseUnsigned(usize, std.mem.trimEnd(u8, buf[0..n], "\n"), 10) catch return 32768;
    return @min(val, 1_000_000);
}

fn logErr(context: []const u8, err: anyerror) void {
    if (builtin.mode == .Debug) {
        std.debug.print("[xtop] {s}: {}\n", .{ context, err });
    }
}

fn sleepMs(ms: u64) void {
    sleepNs(@as(i96, @intCast(ms)) * std.time.ns_per_ms);
}
fn sleepNs(ns: i96) void {
    const req = linux.timespec{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
    _ = linux.nanosleep(&req, null);
}
