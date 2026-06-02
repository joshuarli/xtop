const std = @import("std");
const linux = std.os.linux;

pub const STDOUT_FD = std.posix.STDOUT_FILENO;

pub const R = "\x1b[0m";
pub const BL = "\x1b[34m";
pub const G = "\x1b[32m";
pub const RD = "\x1b[31m";
pub const Y = "\x1b[33m";
pub const M = "\x1b[35m";
pub const C = "\x1b[36m";
pub const BW = "\x1b[1;37m";
pub const BR = "\x1b[90m";
pub const OR = "\x1b[38;5;208m";

pub const CPU_COLORS = [_][]const u8{ BL, G, RD, Y, M, C, C, BR };

pub const BLOCKS = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub const BOX_TOP_SUFFIX = "┐" ++ R ++ "\n";
pub const BOX_BOTTOM_SUFFIX = "┘" ++ R ++ "\n";

pub const TermSize = struct {
    w: usize,
    h: usize,
};

pub fn getTermSize() TermSize {
    var ws: std.posix.winsize = @bitCast(@as(u64, 0));
    const rc = linux.ioctl(STDOUT_FD, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return .{ .w = 80, .h = 24 };
    return .{ .w = @max(20, @as(usize, ws.col)), .h = @max(10, @as(usize, ws.row)) };
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

// ─── Box drawing ───

pub fn boxTop(buf: []u8, title: []const u8, w: usize) !usize {
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
    o += wrs(buf[o..], BOX_TOP_SUFFIX);
    return o;
}

pub fn boxBottom(buf: []u8, w: usize) !usize {
    var o: usize = 0;
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "└");
    var i: usize = 0;
    while (i < w - 2) : (i += 1) o += wrs(buf[o..], "─");
    o += wrs(buf[o..], BOX_BOTTOM_SUFFIX);
    return o;
}

pub fn boxRow(buf: []u8, content: []const u8, w: usize) !usize {
    var o: usize = 0;
    o += wrs(buf[o..], BR);
    o += wrs(buf[o..], "│");
    o += wrs(buf[o..], R);
    const vw = visualW(content);
    if (vw <= w - 2) {
        o += wrs(buf[o..], content);
        const pad_n = w - 2 -| vw;
        @memset(buf[o .. o + pad_n], ' ');
        o += pad_n;
    } else {
        o += writeVisualTrunc(buf[o..], content, w - 2);
    }
    o += wrs(buf[o..], BR ++ "│" ++ R ++ "\n");
    return o;
}

// ─── ANSI-aware string helpers ───

pub fn visualW(s: []const u8) usize {
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
pub fn writeVisualTrunc(buf: []u8, s: []const u8, max_visual: usize) usize {
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

pub fn padLabel(buf: []u8, s: []const u8, width: usize) []const u8 {
    const pad = width -| s.len;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..s.len], s);
    return buf[0..pad + s.len];
}

// ─── I/O ───

pub fn wrs(buf: []u8, s: []const u8) usize {
    @memcpy(buf[0..s.len], s);
    return s.len;
}

pub fn writeAll(bytes: []const u8) !void {
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

pub fn wfd(fd: std.posix.fd_t, bytes: []const u8) usize {
    const r = linux.write(fd, bytes.ptr, bytes.len);
    return if (@as(isize, @bitCast(r)) < 0) 0 else r;
}
