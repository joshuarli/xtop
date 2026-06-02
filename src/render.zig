const std = @import("std");
const xtop = @import("xtop");
const types = xtop.types;
const tui = @import("tui.zig");

const SystemCpu = types.SystemCpu;
const MemState = types.MemState;
const NetState = types.NetState;
const PowerState = types.PowerState;
const Process = types.Process;
const SampleRing = types.SampleRing;
const TOP_N = types.TOP_N;

const CHART_H_MAX: usize = 4;
const HALF_H_MAX: usize = 3;
const MIN_GAUGE_W: usize = 22;

pub fn render(
    sys: *const SystemCpu,
    mem: *const MemState,
    net: *const NetState,
    power: *const PowerState,
    procs: []const *const Process,
    sort_key: types.SortKey,
) !void {
    const ts = tui.getTermSize();
    const w = ts.w;
    const h = ts.h;

    // Pre-compute CPU gauge rows (non-negotiable).
    const box_inner = w -| 2;
    const ncols: usize = @max(1, box_inner / MIN_GAUGE_W);
    const gauge_w = (box_inner -| (ncols - 1) * 2) / ncols;
    const cpu_gauge_rows = (sys.num_cores + ncols - 1) / ncols;
    const cpu_rows = 2 + cpu_gauge_rows;

    // Minimum rows per compressed widget (box borders + annotations only).
    const mem_ann: usize = if (mem.swap_total_kb > 0) 2 else 1;
    const mem_min: usize = 2 + mem_ann;
    const pwr_min: usize = 3; // box + one content row
    const net_min: usize = 3;
    const proc_min: usize = 4; // box + header + divider
    const status_rows: usize = 1;

    const fixed = cpu_rows + mem_min + pwr_min + net_min + proc_min + status_rows;

    // Height budget — allocate chart rows and process rows from surplus.
    const surplus: usize = if (h > fixed) h - fixed else 0;

    // Priority: memory chart → power chart → network chart → process rows.
    var mem_chart_h: usize = 0;
    var pwr_chart_h: usize = 0;
    var net_half_h: usize = 0;
    var proc_max_rows: usize = 0;
    var avail: usize = surplus;

    if (avail >= CHART_H_MAX) {
        mem_chart_h = CHART_H_MAX;
        avail -= CHART_H_MAX;
    } else if (avail > 0) {
        mem_chart_h = avail;
        avail = 0;
    }

    if (power.has_perms and avail >= CHART_H_MAX) {
        pwr_chart_h = CHART_H_MAX;
        avail -= CHART_H_MAX;
    } else if (power.has_perms and avail > 0) {
        pwr_chart_h = avail;
        avail = 0;
    }

    if (avail >= HALF_H_MAX * 2) {
        net_half_h = HALF_H_MAX;
        avail -= HALF_H_MAX * 2;
    } else if (avail >= 2) {
        net_half_h = avail / 2;
        avail -= net_half_h * 2;
    }

    proc_max_rows = @min(TOP_N, avail);

    // Render into buffer sized for up to 1024 cores.
    var b: [131072]u8 = undefined;
    const out = try renderToBuf(&b, sys, mem, net, power, procs, sort_key, w, ncols, gauge_w, mem_chart_h, pwr_chart_h, net_half_h, proc_max_rows);
    _ = try tui.writeAll(out);
}

pub fn renderToBuf(
    buf: []u8,
    sys: *const SystemCpu,
    mem: *const MemState,
    net: *const NetState,
    power: *const PowerState,
    procs: []const *const Process,
    sort_key: types.SortKey,
    w: usize,
    ncols: usize,
    gauge_w: usize,
    mem_chart_h: usize,
    pwr_chart_h: usize,
    net_half_h: usize,
    proc_max_rows: usize,
) ![]const u8 {
    var o: usize = 0;
    o += tui.wrs(buf[o..], "\x1b[?2026h\x1b[H");
    o += cpuWidget(buf[o..], sys, w, ncols, gauge_w);
    o += try memWidget(buf[o..], mem, w, mem_chart_h);
    o += try powerWidget(buf[o..], power, w, pwr_chart_h);
    o += try netWidget(buf[o..], net, w, net_half_h);
    o += try procWidget(buf[o..], procs, mem.total_kb, w, proc_max_rows);
    o += (try std.fmt.bufPrint(buf[o..], "  sort: {s} | c/m: sort  q: quit\x1b[K\x1b[J\x1b[?2026l", .{if (sort_key == .cpu) "CPU" else "MEM"})).len;
    return buf[0..o];
}

// ─── CPU widget ───

pub fn cpuWidget(buf: []u8, sys: *const SystemCpu, w: usize, ncols: usize, gauge_w: usize) usize {
    var cb: [65536]u8 = undefined;
    var cl: usize = 0;
    const rows = (sys.num_cores + ncols - 1) / ncols;
    for (0..rows) |row| {
        for (0..ncols) |ci| {
            const i = ci * rows + row;
            if (i >= sys.num_cores) break;
            cl += cpuGauge(cb[cl..], sys, i, gauge_w) catch cl;
            if (ci < ncols - 1 and i + rows < sys.num_cores) cl += tui.wrs(cb[cl..], "  ");
        }
        cl += tui.wrs(cb[cl..], "\n");
    }
    var o: usize = 0;
    o += tui.boxTop(buf[o..], "CPU", w) catch o;
    var lines = std.mem.splitScalar(u8, cb[0..cl], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        o += tui.boxRow(buf[o..], line, w) catch o;
    }
    o += tui.boxBottom(buf[o..], w) catch o;
    return o;
}

fn cpuGauge(buf: []u8, sys: *const SystemCpu, i: usize, gauge_w: usize) !usize {
    const core = sys.cores[i];
    const prev = sys.prev_cores[i];
    const td = core.total() -| prev.total();
    const ad = if (td > 0) core.active() -| prev.active() else 0;
    const pct: f32 = if (td > 0) @as(f32, @floatFromInt(ad)) / @as(f32, @floatFromInt(td)) * 100.0 else 0;

    var pt: [6]u8 = undefined;
    const ptl = (try std.fmt.bufPrint(&pt, "{d: >4.1}%", .{@min(pct, 999.9)})).len;
    const cpu_bar = gauge_w -| 5;
    const fl = cpu_bar -| ptl;
    var o: usize = 0;
    o += (try std.fmt.bufPrint(buf[o..], "{s}{d: >3}{s}[", .{ tui.C, i, tui.R })).len;
    var bp: usize = 0;
    if (td > 0) {
        const ds = [_]u64{ core.nice -| prev.nice, core.user -| prev.user, core.system -| prev.system, core.irq -| prev.irq, core.softirq -| prev.softirq, core.steal -| prev.steal, core.guest -| prev.guest, core.iowait -| prev.iowait };
        for (ds, 0..) |d, ci| {
            if (d == 0) continue;
            const sw = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(td)) * @as(f32, @floatFromInt(cpu_bar)))));
            const n = @min(@max(1, sw), fl -| bp);
            if (n == 0) break;
            o += tui.wrs(buf[o..], tui.CPU_COLORS[ci]);
            @memset(buf[o .. o + n], '|');
            o += n;
            bp += n;
        }
    }
    while (bp < fl) : (bp += 1) {
        buf[o] = ' ';
        o += 1;
    }
    o += (try std.fmt.bufPrint(buf[o..], "{s}{s}]{s}", .{ tui.BW, pt[0..ptl], tui.R })).len;
    return o;
}

// ─── Solid block area chart ───

fn renderChart(
    buf: []u8,
    title: []const u8,
    series: anytype,
    y_max_label: []const u8,
    y_min_label: []const u8,
    rows_before: []const []const u8,
    chart_h: usize,
    w: usize,
) !usize {
    const n_series = series.len;
    const y_w: usize = 5;
    const n_cols = w -| 2 -| y_w;
    if (n_cols < 4 or n_series == 0) return 0;

    var o: usize = 0;
    o += try tui.boxTop(buf[o..], title, w);

    for (rows_before) |line| {
        o += try tui.boxRow(buf[o..], line, w);
    }

    if (chart_h == 0) {
        o += try tui.boxBottom(buf[o..], w);
        return o;
    }

    // Right-aligned decimation for each series
    var data: [4][200]f32 = undefined;
    for (series, 0..) |s, si| {
        decimate(&data[si], n_cols, s.rb);
    }

    // Chart rows (top to bottom), each row = 8 sub-levels
    const total_lev = chart_h * 8;
    for (0..chart_h) |cr| {
        const row_bot = (chart_h - 1 - cr) * 8;

        o += tui.wrs(buf[o..], tui.BR);
        o += tui.wrs(buf[o..], "│");
        o += tui.wrs(buf[o..], tui.R);

        if (cr == 0) {
            o += tui.wrs(buf[o..], y_max_label);
        } else if (cr == chart_h - 1) {
            o += tui.wrs(buf[o..], y_min_label);
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
                    if (clr) |c| o += tui.wrs(buf[o..], c);
                    o += tui.wrs(buf[o..], tui.BLOCKS[@intCast(in_row)]);
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
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ tui.BR, tui.R })).len;
    }

    o += try tui.boxBottom(buf[o..], w);
    return o;
}

// ─── Memory widget ───

pub fn memWidget(buf: []u8, mem: *const MemState, w: usize, chart_h: usize) !usize {
    const Series = struct { rb: *const SampleRing, color: []const u8 };
    var s: [2]Series = undefined;
    s[0] = .{ .rb = &mem.mem_history, .color = tui.M };
    var n: usize = 1;
    if (mem.swap_total_kb > 0) {
        s[1] = .{ .rb = &mem.swap_history, .color = tui.Y };
        n = 2;
    }

    const mu = mem.total_kb -| mem.avail_kb;
    const mp: f32 = if (mem.total_kb > 0) @as(f32, @floatFromInt(mu)) / @as(f32, @floatFromInt(mem.total_kb)) * 100.0 else 0;

    var sb: [32]u8 = undefined;
    var ann_buf: [128]u8 = undefined;
    var anns: [2][]const u8 = undefined;
    var ann_count: usize = 0;

    anns[ann_count] = try std.fmt.bufPrint(&ann_buf, "{s}RAM:{s} {d: >4.1}%  {s}{s} / {s}{s}", .{
        tui.M, tui.R, @min(mp, 999.9), tui.G, fsize(&sb, mu), tui.R, fsize(sb[16..], mem.total_kb),
    });
    ann_count += 1;

    if (mem.swap_total_kb > 0) {
        const su = mem.swap_total_kb -| mem.swap_free_kb;
        const sp: f32 = @as(f32, @floatFromInt(su)) / @as(f32, @floatFromInt(mem.swap_total_kb)) * 100.0;
        anns[ann_count] = try std.fmt.bufPrint(ann_buf[64..], "{s}SWP:{s} {d: >4.1}%  {s}{s} / {s}{s}", .{
            tui.Y, tui.R, @min(sp, 999.9), tui.G, fsize(&sb, su), tui.R, fsize(sb[16..], mem.swap_total_kb),
        });
        ann_count += 1;
    }

    var ymax: [8]u8 = undefined;
    var ymin: [8]u8 = undefined;
    return renderChart(buf, "Memory", s[0..n], tui.padLabel(&ymax, "100%", 5), tui.padLabel(&ymin, "  0%", 5), anns[0..ann_count], chart_h, w);
}

// ─── Power widget ───

pub fn powerWidget(buf: []u8, power: *const PowerState, w: usize, chart_h: usize) !usize {
    if (!power.has_perms) {
        var o: usize = 0;
        o += try tui.boxTop(buf[o..], "Power", w);
        o += try tui.boxRow(buf[o..], "  (root required for power stats)", w);
        o += try tui.boxBottom(buf[o..], w);
        return o;
    }

    const Series = struct { rb: *const SampleRing, color: []const u8 };
    var s = [1]Series{.{ .rb = &power.power_history, .color = tui.OR }};

    var ann_buf: [64]u8 = undefined;
    var anns: [1][]const u8 = undefined;
    anns[0] = try std.fmt.bufPrint(&ann_buf, "{s}PWR:{s} {d: >5.1}W  max: {d:.1}W", .{
        tui.OR, tui.R, power.curr_watts, power.max_watts,
    });

    var ymax_lbl: [8]u8 = undefined;
    var ymin_lbl: [8]u8 = undefined;
    var max_watts_buf: [8]u8 = undefined;
    const max_watts_str = try std.fmt.bufPrint(&max_watts_buf, "{d:.0}W", .{power.max_watts});

    return renderChart(buf, "Power", &s, tui.padLabel(&ymax_lbl, max_watts_str, 5), tui.padLabel(&ymin_lbl, "  0W", 5), &anns, chart_h, w);
}

// ─── Network widget ───

pub fn netWidget(buf: []u8, net: *const NetState, w: usize, half_h: usize) !usize {
    const y_w: usize = 5;
    const n_cols = w -| 2 -| y_w;
    if (n_cols < 4) return 0;

    const max_rate: u64 = @max(@max(net.rx_rate, net.tx_rate), 1024);

    var title_buf: [80]u8 = undefined;
    var tmp: [16]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "Network — up:{s} dn:{s}", .{
        rateLabel(&tmp, net.tx_rate), rateLabel(tmp[8..], net.rx_rate),
    });

    var scale_buf: [8]u8 = undefined;
    const max_lbl = rateLabel(&scale_buf, max_rate);
    var max_pad: [8]u8 = undefined;
    const max_label = tui.padLabel(&max_pad, max_lbl, y_w);

    var o: usize = 0;
    o += try tui.boxTop(buf[o..], title, w);

    if (half_h == 0) {
        // Minimal: current rates annotation only, no chart.
        var ann: [64]u8 = undefined;
        const al = (try std.fmt.bufPrint(&ann, "  up:{s}  dn:{s}", .{
            rateLabel(&tmp, net.tx_rate), rateLabel(tmp[8..], net.rx_rate),
        })).len;
        o += try tui.boxRow(buf[o..], ann[0..al], w);
        o += try tui.boxBottom(buf[o..], w);
        return o;
    }

    var tx_vals: [200]f32 = undefined;
    var rx_vals: [200]f32 = undefined;
    decimate(&tx_vals, n_cols, &net.tx_history);
    decimate(&rx_vals, n_cols, &net.rx_history);

    const tx_lev = half_h * 8;
    for (0..half_h) |cr| {
        const row_bot = (half_h - 1 - cr) * 8;
        o += tui.wrs(buf[o..], tui.BR);
        o += tui.wrs(buf[o..], "│");
        o += tui.wrs(buf[o..], tui.R);
        o += if (cr == 0) tui.wrs(buf[o..], max_label) else tui.wrs(buf[o..], "     ");

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
                o += tui.wrs(buf[o..], tui.RD);
                o += tui.wrs(buf[o..], tui.BLOCKS[@intCast(in_row)]);
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
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ tui.BR, tui.R })).len;
    }

    // Center divider
    o += tui.wrs(buf[o..], tui.BR);
    o += tui.wrs(buf[o..], "│");
    o += tui.wrs(buf[o..], tui.R);
    o += tui.wrs(buf[o..], "    0");
    o += tui.wrs(buf[o..], tui.BR);
    var di: usize = 0;
    while (di < n_cols) : (di += 1) o += tui.wrs(buf[o..], "─");
    o += tui.wrs(buf[o..], tui.R);
    const used_c = 1 + y_w + n_cols + 1;
    if (used_c < w) {
        var i: usize = 0;
        while (i < w - used_c) : (i += 1) {
            buf[o] = ' ';
            o += 1;
        }
    }
    o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ tui.BR, tui.R })).len;

    for (0..half_h) |cr| {
        const row_bot = cr * 8;
        o += tui.wrs(buf[o..], tui.BR);
        o += tui.wrs(buf[o..], "│");
        o += tui.wrs(buf[o..], tui.R);
        o += if (cr == half_h - 1) tui.wrs(buf[o..], max_label) else tui.wrs(buf[o..], "     ");

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
                o += tui.wrs(buf[o..], tui.BL);
                o += tui.wrs(buf[o..], tui.BLOCKS[@intCast(in_row)]);
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
        o += (try std.fmt.bufPrint(buf[o..], "{s}│{s}\n", .{ tui.BR, tui.R })).len;
    }

    o += try tui.boxBottom(buf[o..], w);
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

// ─── Process widget ───

pub fn procWidget(buf: []u8, procs: []const *const Process, total_mem_kb: u64, w: usize, max_rows: usize) !usize {
    var o: usize = 0;
    o += try tui.boxTop(buf[o..], "Processes", w);

    const show_io = w >= 65;
    const name_w: usize = if (show_io) @max(4, @min(15, w -| 39)) else @max(4, @min(15, w -| 25));

    // Header row
    var hr: [128]u8 = undefined;
    var ho: usize = 0;
    ho += tui.wrs(hr[ho..], "  PID    ");
    ho += writePaddedName(hr[ho..], "NAME", name_w);
    if (show_io) {
        ho += (try std.fmt.bufPrint(hr[ho..], " CPU%   MEM%   R/s     W/s", .{})).len;
    } else {
        ho += (try std.fmt.bufPrint(hr[ho..], " CPU%   MEM%", .{})).len;
    }
    while (ho < w - 2) {
        hr[ho] = ' ';
        ho += 1;
    }
    o += try tui.boxRow(buf[o..], hr[0..ho], w);

    // Divider row
    var dr: [256]u8 = undefined;
    var d: usize = 0;
    while (d < w - 2) : (d += 1) {
        dr[d] = '-';
    }
    o += try tui.boxRow(buf[o..], dr[0..d], w);

    // Process rows
    const count = @min(max_rows, procs.len);
    var lb: [128]u8 = undefined;
    for (procs[0..count]) |proc| {
        const lo = formatProcLine(&lb, proc, total_mem_kb, name_w, show_io);
        // Pad to w-2 visual width
        const lw = tui.visualW(lb[0..lo]);
        var po = lo;
        while (po < lo + (w - 2 -| lw)) : (po += 1) {
            lb[po] = ' ';
        }
        o += try tui.boxRow(buf[o..], lb[0..po], w);
    }

    o += try tui.boxBottom(buf[o..], w);
    return o;
}

fn formatProcLine(line: []u8, proc: *const Process, total_mem_kb: u64, name_w: usize, show_io: bool) usize {
    var o: usize = 0;
    const mp: f32 = if (total_mem_kb > 0) @as(f32, @floatFromInt(proc.rss_kb)) / @as(f32, @floatFromInt(total_mem_kb)) * 100.0 else 0;
    o += (std.fmt.bufPrint(line[o..], "  {d: >6}  ", .{proc.pid}) catch unreachable).len;
    const nm = proc.name[0..@min(proc.name_len, name_w)];
    @memcpy(line[o..][0..nm.len], nm);
    o += nm.len;
    var p: usize = nm.len;
    while (p < name_w) : (p += 1) {
        line[o] = ' ';
        o += 1;
    }
    line[o] = ' ';
    o += 1;
    o += (std.fmt.bufPrint(line[o..], "{d: >5.1}  {d: >5.1}", .{ @min(proc.cpu_pct, 999.9), @min(mp, 999.9) }) catch unreachable).len;
    if (show_io) {
        o += tui.wrs(line[o..], "   ");
        o += fmtRate(line[o..], proc.read_rate) catch o;
        o += tui.wrs(line[o..], "   ");
        o += fmtRate(line[o..], proc.write_rate) catch o;
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
