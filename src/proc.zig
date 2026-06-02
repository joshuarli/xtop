const std = @import("std");
const types = @import("types.zig");
const linux = std.os.linux;

const Pid = types.Pid;
const ProcReadResult = types.ProcReadResult;
const NAME_MAX = types.NAME_MAX;
const is_digit = types.charset.is_digit;

/// Like std.posix.read but avoids the stdlib's unexpected-errno debug trace
/// for errno values we intentionally discard (e.g. EACCES on foreign procs).
fn readFd(fd: std.posix.fd_t, buf: []u8) error{Unexpected}!usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return error.Unexpected;
    return rc;
}

/// Read /proc/pid/stat, /proc/pid/statm, and /proc/pid/cmdline for a single PID.
/// Returns ProcReadResult with valid=false if the process should be skipped
/// (kernel thread, zombie, permission denied, or vanished).
pub fn readProcData(pid: Pid) ProcReadResult {
    var stat_buf: [1024]u8 = undefined;
    var statm_buf: [256]u8 = undefined;
    var cmdline_buf: [512]u8 = undefined;

    // Read /proc/pid/cmdline first — fastpath kernel thread filter.
    // Kernel threads have empty cmdline, so we can skip stat/statm entirely.
    var cmdline_path_buf: [types.proc_path.cmdline_max]u8 = undefined;
    const cmdline_path = std.fmt.bufPrintZ(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch return invalid(pid);
    const cmdline_fd = std.posix.openatZ(std.posix.AT.FDCWD, cmdline_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(cmdline_fd);
    const cmdline_len = readFd(cmdline_fd, &cmdline_buf) catch return invalid(pid);

    // Empty cmdline → kernel thread (uncommon on typical desktop/server).
    if (cmdline_len == 0) {
        @branchHint(.unlikely);
        return invalid(pid);
    }

    // Extract argv[0] from cmdline: up to first null byte
    var name_len: usize = 0;
    for (cmdline_buf[0..cmdline_len]) |byte| {
        if (byte == 0) break;
        name_len += 1;
    }
    if (name_len == 0) return invalid(pid);

    // Take basename of argv[0] — everything after the last '/'
    var name = [_]u8{0} ** NAME_MAX;
    const argv0 = cmdline_buf[0..name_len];
    const basename = if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |idx|
        argv0[idx + 1 ..]
    else
        argv0;
    @memcpy(name[0..@min(basename.len, NAME_MAX)], basename[0..@min(basename.len, NAME_MAX)]);

    // Read /proc/pid/stat
    var stat_path_buf: [types.proc_path.stat_max]u8 = undefined;
    const stat_path = std.fmt.bufPrintZ(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch return invalid(pid);
    const stat_fd = std.posix.openatZ(std.posix.AT.FDCWD, stat_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(stat_fd);
    const stat_len = readFd(stat_fd, &stat_buf) catch return invalid(pid);
    const stat_str = stat_buf[0..stat_len];

    // Format: pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime ...
    const comm_start = std.mem.indexOfScalar(u8, stat_str, '(') orelse return invalid(pid);
    _ = comm_start;
    const comm_end = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse return invalid(pid);

    // Fields after ") " — state is the char right after ")"
    const rest = stat_str[comm_end + 1 ..];
    if (rest.len < 2) return invalid(pid);
    const state = rest[1]; // skip space after ')'

    // Filter zombie/dead processes (rare).
    if (state == 'Z' or state == 'X' or state == 'z') {
        @branchHint(.unlikely);
        return invalid(pid);
    }

    // Parse numeric fields from the substring after "state "
    // Indices (0-based from after state): 11=utime, 12=stime, 19=starttime
    const fields_str = rest[2..]; // skip state char and space
    const utime = parseField(fields_str, 11) catch return invalid(pid);
    const stime = parseField(fields_str, 12) catch return invalid(pid);
    const starttime = parseField(fields_str, 19) catch return invalid(pid);

    // Read /proc/pid/statm for RSS
    var statm_path_buf: [types.proc_path.statm_max]u8 = undefined;
    const statm_path = std.fmt.bufPrintZ(&statm_path_buf, "/proc/{d}/statm", .{pid}) catch return invalid(pid);
    const statm_fd = std.posix.openatZ(std.posix.AT.FDCWD, statm_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(statm_fd);
    const statm_len = readFd(statm_fd, &statm_buf) catch return invalid(pid);

    // statm: "size resident shared text lib data dt"
    const rss_pages = parseField(statm_buf[0..statm_len], 1) catch return invalid(pid);

    // Read /proc/pid/io for I/O counters
    var io_buf: [512]u8 = undefined;
    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;
    var io_path_buf: [types.proc_path.io_max]u8 = undefined;
    if (std.fmt.bufPrintZ(&io_path_buf, "/proc/{d}/io", .{pid})) |io_path| {
        if (std.posix.openatZ(std.posix.AT.FDCWD, io_path, .{ .ACCMODE = .RDONLY }, 0)) |io_fd| {
            defer closeFd(io_fd);
            if (readFd(io_fd, &io_buf)) |io_len| {
                var lines = std.mem.splitScalar(u8, io_buf[0..io_len], '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "read_bytes:")) {
                        read_bytes = parseKv(line) catch 0;
                    } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
                        write_bytes = parseKv(line) catch 0;
                    }
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    return .{
        .pid = pid,
        .valid = true,
        .utime = utime,
        .stime = stime,
        .starttime = starttime,
        .state = @intCast(state),
        .rss_pages = rss_pages,
        .read_bytes = read_bytes,
        .write_bytes = write_bytes,
        .name = name,
        .name_len = @intCast(@min(basename.len, NAME_MAX)),
    };
}

fn invalid(pid: Pid) ProcReadResult {
    return .{
        .pid = pid,
        .valid = false,
        .utime = 0,
        .stime = 0,
        .starttime = 0,
        .state = 0,
        .rss_pages = 0,
        .read_bytes = 0,
        .write_bytes = 0,
        .name = [_]u8{0} ** NAME_MAX,
        .name_len = 0,
    };
}

fn parseKv(line: []const u8) !u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Invalid;
    const rest = line[colon + 1 ..];
    const trimmed = std.mem.trim(u8, rest, &.{ ' ', '\t' });
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch error.Invalid;
}

/// Parse the nth space-separated field from a string as u64.
/// Uses SIMD-accelerated scanning via @Vector for the space-finding loop.
pub fn parseField(s: []const u8, index: usize) error{Invalid}!u64 {
    const field_start = indexOfNthSpace(s, index) orelse return error.Invalid;
    const field_end = if (std.mem.indexOfScalarPos(u8, s, field_start, ' ')) |pos|
        pos
    else blk: {
        var end = s.len;
        if (end > 0 and s[end - 1] == '\n') end -= 1;
        break :blk end;
    };
    if (field_start >= field_end) return error.Invalid;
    return std.fmt.parseUnsigned(u64, s[field_start..field_end], 10) catch return error.Invalid;
}

/// SIMD-accelerated: find the byte offset where the nth space-separated field
/// starts. Uses @Vector to skip 32-byte chunks that contain no spaces.
fn indexOfNthSpace(s: []const u8, n: usize) ?usize {
    if (n == 0) return 0; // first field starts at offset 0

    const vec_len: usize = 32;
    var space_count: usize = 0;
    var i: usize = 0;

    while (i + vec_len <= s.len) : (i += vec_len) {
        const chunk: @Vector(vec_len, u8) = s[i..][0..vec_len].*;
        const mask = @as(@Vector(vec_len, u1), @bitCast(chunk == @as(@Vector(vec_len, u8), @splat(' '))));
        if (@reduce(.Or, mask) == 0) continue; // no spaces in this chunk — skip

        inline for (0..vec_len) |j| {
            if (s[i + j] == ' ') {
                space_count += 1;
                if (space_count == n) return i + j + 1;
            }
        }
    }

    // Tail (less than vec_len bytes remaining)
    while (i < s.len) : (i += 1) {
        if (s[i] == ' ') {
            space_count += 1;
            if (space_count == n) return i + 1;
        }
    }
    return null;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}

test "parseField" {
    const s = "size 12345 shared text lib data dt\n";
    const val = try parseField(s, 1);
    try std.testing.expectEqual(12345, val);
}
