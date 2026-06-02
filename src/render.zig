const std = @import("std");
const xtop = @import("xtop");
const types = xtop.types;
const linux = std.os.linux;

const SystemCpu = types.SystemCpu;
const MemState = types.MemState;
const NetState = types.NetState;
const PowerState = types.PowerState;
const Process = types.Process;
const SampleRing = types.SampleRing;
const TOP_N = types.TOP_N;

const STDOUT_FD = std.posix.STDOUT_FILENO;

const R = "\x1b[0m";
const BL = "\x1b[34m";
const G = "\x1b[32m";
const RD = "\x1b[31m";
const Y = "\x1b[33m";
const M = "\x1b[35m";
const C = "\x1b[36m";
const BW = "\x1b[1;37m";
const BR = "\x1b[90m";

const CPU_COLORS = [_][]const u8{ BL, G, RD, Y, M, C, C, BR };

const CHART_H: usize = 4;
const CPU_BAR: usize = 7;

const BLOCKS = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn getTermWidth() usize {
    var ws: std.posix.winsize = @bitCast(@as(u64, 0));
    const rc = linux.ioctl(STDOUT_FD, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return 80;
    return @max(20, @as(usize, ws.col));
}

pub fn enterRawMode() !std.posix.termios {
    const orig = try std.posix.tcgetattr(STDOUT_FD);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(STDOUT_FD, .FLUSH, raw);
    _ = wfd(STDOUT_FD, "\x1b[?1049h\x1b[?25l\x1b[H");
    return orig;
}

pub fn restoreTerminal(orig: std.posix.termios) void {
    _ = wfd(STDOUT_FD, "\x1b[?1049l\x1b[?25h");
    std.posix.tcsetattr(STDOUT_FD, .FLUSH, orig) catch {};
}

pub fn render(
    sys: *const SystemCpu,
    mem: *const MemState,
    net: *const NetState,
    power: *const PowerState,
    procs: []const *const Process,
    sort_key: types.SortKey,
) !void {
    const w = getTermWidth();
    // Render buffer sized for up to 1024 cores (~50KB CPU grid + charts + table).
    var b: [131072]u8 = undefined;
    var o: usize = 0;
    o += wrs(b[o..], "\x1b[?2026h\x1b[H");
    o += try cpuBox(b[o..], sys, w);
    o += try memChart(b[o..], mem, w);
    o += try powerChart(b[o..], power, w);
    o += try netChart(b[o..], net, w);
    o += try procTable(b[o..], procs, mem.total_kb, w);
    o += (try std.fmt.bufPrint(b[o..], "\n  sort: {s} | c/m: sort  q: quit\x1b[K\x1b[J\x1b[?2026l", .{if (sort_key == .cpu) "CPU" else "MEM"})).len;
    _ = try writeAll(b[0..o]);
}

// ─── Box helpers ───

fn boxTop(buf: []u8, title: []const u8, w: usize) !usize {
    var o: usize = 0;
    const dw = (w -| title.len -| 4) / 2;
    const dr = w -| title.len -| 4 -| dw;
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "┌");
    var i: usize = 0;
    while (i < dw) : (i += 1) o += wrs(buf[o..], "─");
    o += wrs(buf[o..], " ");
    o += wrs(buf[o..], BW);
    o += wrs(buf[o..], title);
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], " ");
    i = 0;
    while (i < dr) : (i += 1) o += wrs(buf[o..], "─");
    o += (try std.fmt.bufPrint(buf[o..], "┐{s}\n", .{R})).len;
    return o;
}

fn boxBottom(buf: []u8, w: usize) !usize {
    var o: usize = 0;
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "└");
    var i: usize = 0;
    while (i < w - 2) : (i += 1) o += wrs(buf[o..], "─");
    o += (try std.fmt.bufPrint(buf[o..], "┘{s}\n", .{R})).len;
    return o;
}

fn boxRow(buf: []u8, content: []const u8, w: usize) !usize {
    var o: usize = 0;
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "│");
    o += wrs(buf[o..], R);
    const vw = visualW(content);
    if (vw <= w - 2) {
        o += wrs(buf[o..], content);
        var i: usize = 0;
        while (i < w - 2 - vw) : (i += 1) {
            buf[o] = ' ';
            o += 1;
        }
    } else {
        o += writeVisualTrunc(buf[o..], content, w - 2);
    }
    o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ BR, R })).len;
    return o;
}

fn visualW(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1;
        } else {
            w += 1;
            i += 1;
        }
    }
    return w;
}

/// Write at most max_visual visual characters from s into buf, preserving ANSI
/// escape sequences and appending a reset code.
fn writeVisualTrunc(buf: []u8, s: []const u8, max_visual: usize) usize {
    var o: usize = 0;
    var vw: usize = 0;
    var i: usize = 0;
    while (i < s.len and vw < max_visual) {
        if (s[i] == 0x1b) {
            const start = i;
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1;
            const seq = s[start..i];
            @memcpy(buf[o..][0..seq.len], seq);
            o += seq.len;
        } else {
            buf[o] = s[i];
            o += 1;
            vw += 1;
            i += 1;
        }
    }
    o += wrs(buf[o..], R);
    return o;
}

// ─── CPU: htop-style pipe gauges ───

fn cpuBox(buf: []u8, sys: *const SystemCpu, w: usize) !usize {
    // 1024 cores × ~64 chars per gauge row = ~65KB worst case.
    var cb: [65536]u8 = undefined;
    var cl: usize = 0;
    const box_inner = w -| 2;
    const gauge_w: usize = 17;
    const ncols: usize = @max(1, box_inner / gauge_w);
    const rows = (sys.num_cores + ncols - 1) / ncols;
    for (0..rows) |row| {
        for (0..ncols) |ci| {
            const i = ci * rows + row;
            if (i >= sys.num_cores) break;
            cl += try cpuGauge(cb[cl..], sys, i);
            if (ci < ncols - 1 and i + rows < sys.num_cores) cl += wrs(cb[cl..], "  ");
        }
        cl += wrs(cb[cl..], "\n");
    }
    var o: usize = 0;
    o += try boxTop(buf[o..], "CPU", w);
    var lines = std.mem.splitScalar(u8, cb[0..cl], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        o += try boxRow(buf[o..], line, w);
    }
    o += try boxBottom(buf[o..], w);
    return o;
}

fn cpuGauge(buf: []u8, sys: *const SystemCpu, i: usize) !usize {
    const core = sys.cores[i];
    const prev = sys.prev_cores[i];
    const td = core.total() -| prev.total();
    const ad = if (td > 0) core.active() -| prev.active() else 0;
    const pct: f32 = if (td > 0) @as(f32, @floatFromInt(ad)) / @as(f32, @floatFromInt(td)) * 100.0 else 0;

    var pt: [6]u8 = undefined;
    const ptl = (try std.fmt.bufPrint(&pt, "{d: >4.1}%", .{@min(pct, 999.9)})).len;
    const fl = CPU_BAR -| ptl;
    var o: usize = 0;
    o += (try std.fmt.bufPrint(buf[o..], "{s}{d: >3}{s}[", .{ C, i, R })).len;
    var bp: usize = 0;
    if (td > 0) {
        const ds = [_]u64{ core.nice -| prev.nice, core.user -| prev.user, core.system -| prev.system, core.irq -| prev.irq, core.softirq -| prev.softirq, core.steal -| prev.steal, core.guest -| prev.guest, core.iowait -| prev.iowait };
        for (ds, 0..) |d, ci| {
            if (d == 0) continue;
            const sw = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(td)) * @as(f32, @floatFromInt(CPU_BAR)))));
            const n = @min(@max(1, sw), fl -| bp);
            if (n == 0) break;
            o += wrs(buf[o..], CPU_COLORS[ci]);
            @memset(buf[o .. o + n], '|');
            o += n;
            bp += n;
        }
    }
    while (bp < fl) : (bp += 1) {
        buf[o] = ' ';
        o += 1;
    }
    o += (try std.fmt.bufPrint(buf[o..], "{s}{s}]{s}", .{ BW, pt[0..ptl], R })).len;
    return o;
}

// ─── Solid block area chart ───
//
// Renders a chart with `█` block characters forming a filled area.
// One char = one column = one time point. CHART_H rows of vertical resolution.

fn renderChart(
    buf: []u8,
    title: []const u8,
    series: anytype,
    y_max_label: []const u8,
    y_min_label: []const u8,
    rows_before: []const []const u8,
    w: usize,
) !usize {
    const n_series = series.len;
    const y_w: usize = 5;
    const n_cols = w -| 2 -| y_w;
    if (n_cols < 4 or n_series == 0) return 0;

    // Right-aligned decimation for each series
    var data: [4][200]f32 = undefined;
    for (series, 0..) |s, si| {
        decimate(&data[si], n_cols, s.rb);
    }

    var o: usize = 0;
    o += try boxTop(buf[o..], title, w);

    for (rows_before) |line| {
        o += try boxRow(buf[o..], line, w);
    }

    // Chart rows (top to bottom), each row = 8 sub-levels
    const total_lev = CHART_H * 8;
    for (0..CHART_H) |cr| {
        const row_bot = (CHART_H - 1 - cr) * 8;

        o += wrs(buf[o..], BR);
        o += wrs(buf[o..], "│");
        o += wrs(buf[o..], R);

        if (cr == 0) {
            o += wrs(buf[o..], y_max_label);
        } else if (cr == CHART_H - 1) {
            o += wrs(buf[o..], y_min_label);
        } else {
            var i: usize = 0;
            while (i < y_w) : (i += 1) {
                buf[o] = ' ';
                o += 1;
            }
        }

        for (0..n_cols) |ci| {
            var max_fill: f32 = -1.0;
            var clr: ?[]const u8 = null;
            for (series, 0..) |s, si| {
                const v = data[si][ci];
                if (v >= 0 and v > max_fill) {
                    max_fill = v;
                    clr = s.color;
                }
            }

            if (max_fill < 0) {
                buf[o] = ' ';
                o += 1;
            } else {
                const fill_lev = max_fill / 100.0 * @as(f32, @floatFromInt(total_lev));
                const in_row = @max(0, @min(8, @as(isize, @intFromFloat(@round(fill_lev - @as(f32, @floatFromInt(row_bot)))))));
                if (in_row == 0) {
                    buf[o] = ' ';
                    o += 1;
                } else {
                    if (clr) |c| o += wrs(buf[o..], c);
                    o += wrs(buf[o..], BLOCKS[@intCast(in_row)]);
                }
            }
        }

        const used = 1 + y_w + n_cols + 1;
        if (used < w) {
            var i: usize = 0;
            while (i < w - used) : (i += 1) {
                buf[o] = ' ';
                o += 1;
            }
        }
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ BR, R })).len;
    }

    o += try boxBottom(buf[o..], w);
    return o;
}

fn padLabel(buf: []u8, s: []const u8, width: usize) []const u8 {
    const pad = width -| s.len;
    var o: usize = 0;
    var i: usize = 0;
    while (i < pad) : (i += 1) {
        buf[o] = ' ';
        o += 1;
    }
    @memcpy(buf[o..][0..s.len], s);
    o += s.len;
    return buf[0..o];
}

// ─── Memory chart ───

fn memChart(buf: []u8, mem: *const MemState, w: usize) !usize {
    const Series = struct { rb: *const SampleRing, color: []const u8 };
    var s: [2]Series = undefined;
    s[0] = .{ .rb = &mem.mem_history, .color = M };
    var n: usize = 1;
    if (mem.swap_total_kb > 0) {
        s[1] = .{ .rb = &mem.swap_history, .color = Y };
        n = 2;
    }

    const mu = mem.total_kb -| mem.avail_kb;
    const mp: f32 = if (mem.total_kb > 0) @as(f32, @floatFromInt(mu)) / @as(f32, @floatFromInt(mem.total_kb)) * 100.0 else 0;

    var sb: [32]u8 = undefined;
    var ann_buf: [128]u8 = undefined;
    var anns: [2][]const u8 = undefined;
    var ann_count: usize = 0;

    anns[ann_count] = try std.fmt.bufPrint(&ann_buf, "{s}RAM:{s} {d: >4.1}%  {s}{s} / {s}{s}", .{
        M, R, @min(mp, 999.9), G, fsize(&sb, mu), R, fsize(sb[16..], mem.total_kb),
    });
    ann_count += 1;

    if (mem.swap_total_kb > 0) {
        const su = mem.swap_total_kb -| mem.swap_free_kb;
        const sp: f32 = @as(f32, @floatFromInt(su)) / @as(f32, @floatFromInt(mem.swap_total_kb)) * 100.0;
        anns[ann_count] = try std.fmt.bufPrint(ann_buf[64..], "{s}SWP:{s} {d: >4.1}%  {s}{s} / {s}{s}", .{
            Y, R, @min(sp, 999.9), G, fsize(&sb, su), R, fsize(sb[16..], mem.swap_total_kb),
        });
        ann_count += 1;
    }

    var ymax: [8]u8 = undefined;
    var ymin: [8]u8 = undefined;
    return renderChart(buf, "Memory", s[0..n], padLabel(&ymax, "100%", 5), padLabel(&ymin, "  0%", 5), anns[0..ann_count], w);
}

// ─── Power chart ───

fn powerChart(buf: []u8, power: *const PowerState, w: usize) !usize {
    if (!power.has_perms) {
        var o: usize = 0;
        o += try boxTop(buf[o..], "Power", w);
        o += try boxRow(buf[o..], "  (root required for power stats)", w);
        o += try boxBottom(buf[o..], w);
        return o;
    }

    const Series = struct { rb: *const SampleRing, color: []const u8 };
    var s = [1]Series{.{ .rb = &power.power_history, .color = M }};

    var ann_buf: [64]u8 = undefined;
    var anns: [1][]const u8 = undefined;
    anns[0] = try std.fmt.bufPrint(&ann_buf, "{s}PWR:{s} {d: >5.1}W  max: {d:.1}W", .{
        M, R, power.curr_watts, power.max_watts,
    });

    var ymax_lbl: [8]u8 = undefined;
    var ymin_lbl: [8]u8 = undefined;
    var max_watts_buf: [8]u8 = undefined;
    const max_watts_str = try std.fmt.bufPrint(&max_watts_buf, "{d:.0}W", .{power.max_watts});

    return renderChart(buf, "Power", &s, padLabel(&ymax_lbl, max_watts_str, 5), padLabel(&ymin_lbl, "  0W", 5), &anns, w);
}

fn netChart(buf: []u8, net: *const NetState, w: usize) !usize {
    const half_h: usize = 3;
    const y_w: usize = 5;
    const n_cols = w -| 2 -| y_w;
    if (n_cols < 4) return 0;

    const max_rate: u64 = @max(@max(net.rx_rate, net.tx_rate), 1024);

    var tx_vals: [200]f32 = undefined;
    var rx_vals: [200]f32 = undefined;
    decimate(&tx_vals, n_cols, &net.tx_history);
    decimate(&rx_vals, n_cols, &net.rx_history);

    var title_buf: [80]u8 = undefined;
    var tmp: [16]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "Network — TX:{s} RX:{s}", .{
        rateLabel(&tmp, net.tx_rate), rateLabel(tmp[8..], net.rx_rate),
    });

    var scale_buf: [8]u8 = undefined;
    const max_lbl = rateLabel(&scale_buf, max_rate);
    var max_pad: [8]u8 = undefined;
    const max_label = padLabel(&max_pad, max_lbl, y_w);

    var o: usize = 0;
    o += try boxTop(buf[o..], title, w);

    const tx_lev = half_h * 8;
    for (0..half_h) |cr| {
        const row_bot = (half_h - 1 - cr) * 8;
        o += wrs(buf[o..], BR);
        o += wrs(buf[o..], "│");
        o += wrs(buf[o..], R);
        o += if (cr == 0) wrs(buf[o..], max_label) else wrs(buf[o..], "     ");

        for (0..n_cols) |ci| {
            if (tx_vals[ci] < 0) {
                buf[o] = ' ';
                o += 1;
                continue;
            }
            const v = tx_vals[ci] / 100.0 * @as(f32, @floatFromInt(max_rate));
            const frac = v / @as(f32, @floatFromInt(max_rate));
            const fill = frac * @as(f32, @floatFromInt(tx_lev));
            const in_row = @max(0, @min(8, @as(isize, @intFromFloat(@round(fill - @as(f32, @floatFromInt(row_bot)))))));
            if (in_row == 0) {
                buf[o] = ' ';
                o += 1;
            } else {
                o += wrs(buf[o..], RD);
                o += wrs(buf[o..], BLOCKS[@intCast(in_row)]);
            }
        }
        const used = 1 + y_w + n_cols + 1;
        if (used < w) {
            var i: usize = 0;
            while (i < w - used) : (i += 1) {
                buf[o] = ' ';
                o += 1;
            }
        }
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ BR, R })).len;
    }

    // Center divider
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "│");
    o += wrs(buf[o..], R);
    o += wrs(buf[o..], "    0");
    o += wrs(buf[o..], BR);
    var di: usize = 0;
    while (di < n_cols) : (di += 1) o += wrs(buf[o..], "─");
    o += wrs(buf[o..], R);
    const used_c = 1 + y_w + n_cols + 1;
    if (used_c < w) {
        var i: usize = 0;
        while (i < w - used_c) : (i += 1) {
            buf[o] = ' ';
            o += 1;
        }
    }
    o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ BR, R })).len;

    for (0..half_h) |cr| {
        const row_bot = cr * 8;
        o += wrs(buf[o..], BR);
        o += wrs(buf[o..], "│");
        o += wrs(buf[o..], R);
        o += if (cr == half_h - 1) wrs(buf[o..], max_label) else wrs(buf[o..], "     ");

        for (0..n_cols) |ci| {
            if (rx_vals[ci] < 0) {
                buf[o] = ' ';
                o += 1;
                continue;
            }
            const v = rx_vals[ci] / 100.0 * @as(f32, @floatFromInt(max_rate));
            const frac = v / @as(f32, @floatFromInt(max_rate));
            const fill = frac * @as(f32, @floatFromInt(tx_lev));
            const in_row = @max(0, @min(8, @as(isize, @intFromFloat(@round(fill - @as(f32, @floatFromInt(row_bot)))))));
            if (in_row == 0) {
                buf[o] = ' ';
                o += 1;
            } else {
                o += wrs(buf[o..], G);
                o += wrs(buf[o..], BLOCKS[@intCast(in_row)]);
            }
        }
        const used = 1 + y_w + n_cols + 1;
        if (used < w) {
            var i: usize = 0;
            while (i < w - used) : (i += 1) {
                buf[o] = ' ';
                o += 1;
            }
        }
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ BR, R })).len;
    }

    o += try boxBottom(buf[o..], w);
    return o;
}

/// Decimate a SampleRing's cpu_pct values into `out[0..n]`. Right-aligned:
/// if fewer than n samples exist, they appear at the right end. Unfilled
/// slots on the left are set to -1.0 (sentinel for "no data").
fn decimate(out: []f32, n: usize, rb: *const SampleRing) void {
    for (0..n) |j| {
        out[j] = -1.0;
    }
    var raw: [types.RING_SIZE]types.Sample = undefined;
    const vals = rb.lastN(@min(types.RING_SIZE, rb.len), &raw);
    if (vals.len < 2) return;
    const start = n -| vals.len;
    for (vals, 0..) |v, i| {
        if (start + i < n) out[start + i] = v.cpu_pct;
    }
}

fn rateLabel(buf: []u8, bps: u64) []const u8 {
    const label = if (bps < 1024) std.fmt.bufPrint(buf, "{d: >4}B", .{bps}) else if (bps < 1024 * 1024) std.fmt.bufPrint(buf, "{d:.1}K", .{@as(f32, @floatFromInt(bps)) / 1024.0}) else std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f32, @floatFromInt(bps)) / (1024.0 * 1024.0)});
    return label catch {
        @memcpy(buf[0..5], "   0B");
        return buf[0..5];
    };
}

fn fsize(buf: []u8, kb: u64) []const u8 {
    if (kb == 0) return "    0";
    const b = kb * 1024;
    if (b < 1024 * 1024) return (std.fmt.bufPrint(buf, "{d:.1}KiB", .{@as(f32, @floatFromInt(kb))}) catch return "0")[0..];
    if (b < 1024 * 1024 * 1024) return (std.fmt.bufPrint(buf, "{d:.1}MiB", .{@as(f32, @floatFromInt(kb)) / 1024.0}) catch return "0")[0..];
    return (std.fmt.bufPrint(buf, "{d:.1}GiB", .{@as(f32, @floatFromInt(kb)) / (1024.0 * 1024.0)}) catch return "0")[0..];
}

// ─── Process table ───

fn procTable(buf: []u8, procs: []const *const Process, total_mem_kb: u64, w: usize) !usize {
    var o: usize = 0;
    const show_io = w >= 65;
    const name_w: usize = if (show_io) @max(4, @min(15, w -| 39)) else @max(4, @min(15, w -| 25));

    // Header
    o += wrs(buf[o..], "\n  PID    ");
    o += writePaddedName(buf[o..], "NAME", name_w);
    if (show_io) {
        o += wrs(buf[o..], " CPU%   MEM%   R/s     W/s\n  ");
    } else {
        o += wrs(buf[o..], " CPU%   MEM%\n  ");
    }

    // Divider
    const div_w: usize = if (show_io) 6 + 2 + name_w + 1 + 5 + 2 + 5 + 2 + 5 + 2 + 5 else 6 + 2 + name_w + 1 + 5 + 2 + 5;
    var di: usize = 0;
    while (di < div_w) : (di += 1) {
        buf[o] = '-';
        o += 1;
    }
    buf[o] = '\n';
    o += 1;

    for (procs, 0..) |proc, i| {
        if (i >= TOP_N) break;
        const mp: f32 = if (total_mem_kb > 0) @as(f32, @floatFromInt(proc.rss_kb)) / @as(f32, @floatFromInt(total_mem_kb)) * 100.0 else 0;
        o += (try std.fmt.bufPrint(buf[o..], "  {d: >6}  ", .{proc.pid})).len;
        const nm = proc.name[0..@min(proc.name_len, name_w)];
        @memcpy(buf[o..][0..nm.len], nm);
        o += nm.len;
        var p: usize = nm.len;
        while (p < name_w) : (p += 1) {
            buf[o] = ' ';
            o += 1;
        }
        buf[o] = ' ';
        o += 1;
        o += (try std.fmt.bufPrint(buf[o..], "{d: >5.1}  {d: >5.1}", .{ @min(proc.cpu_pct, 999.9), @min(mp, 999.9) })).len;
        if (show_io) {
            o += wrs(buf[o..], "   ");
            o += try fmtRate(buf[o..], proc.read_rate);
            o += wrs(buf[o..], "   ");
            o += try fmtRate(buf[o..], proc.write_rate);
        }
        o += wrs(buf[o..], "   ");
        buf[o] = '\n';
        o += 1;
    }
    return o;
}

fn writePaddedName(buf: []u8, name: []const u8, width: usize) usize {
    const n = @min(name.len, width);
    @memcpy(buf[0..n], name[0..n]);
    var o: usize = n;
    while (o < width) : (o += 1) {
        buf[o] = ' ';
    }
    return o;
}

fn fmtRate(buf: []u8, bps: u64) !usize {
    if (bps == 0) return (try std.fmt.bufPrint(buf, "    0 ", .{})).len;
    if (bps < 1024) return (try std.fmt.bufPrint(buf, "{d: >4}B ", .{bps})).len;
    if (bps < 1024 * 1024) return (try std.fmt.bufPrint(buf, "{d: >4}K", .{bps / 1024})).len;
    return (try std.fmt.bufPrint(buf, "{d: >4}M", .{bps / (1024 * 1024)})).len;
}

// ─── I/O ───

fn wrs(buf: []u8, s: []const u8) usize {
    @memcpy(buf[0..s.len], s);
    return s.len;
}

fn writeAll(bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(STDOUT_FD, bytes.ptr + off, bytes.len - off);
        const s: isize = @bitCast(r);
        if (s < 0) {
            if (s == -@as(isize, @intFromEnum(linux.E.INTR))) continue;
            return error.IoError;
        }
        if (r == 0) return error.Closed;
        off += r;
    }
}

fn wfd(fd: std.posix.fd_t, bytes: []const u8) usize {
    const r = linux.write(fd, bytes.ptr, bytes.len);
    return if (@as(isize, @bitCast(r)) < 0) 0 else r;
}
