const std = @import("std");
const types = @import("types.zig");
const linux = std.os.linux;

const Pid = types.Pid;
const ProcReadResult = types.ProcReadResult;
const NAME_MAX = types.NAME_MAX;

/// Read /proc/pid/stat, /proc/pid/statm, and /proc/pid/cmdline for a single PID.
/// Returns ProcReadResult with valid=false if the process should be skipped
/// (kernel thread, zombie, permission denied, or vanished).
pub fn readProcData(pid: Pid) ProcReadResult {
    var stat_buf: [1024]u8 = undefined;
    var statm_buf: [256]u8 = undefined;
    var cmdline_buf: [512]u8 = undefined;

    // Read /proc/pid/cmdline first — fastpath kernel thread filter.
    // Kernel threads have empty cmdline, so we can skip stat/statm entirely.
    var cmdline_path_buf: [32]u8 = [_]u8{0} ** 32;
    const cmdline_path = std.fmt.bufPrintZ(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch return invalid(pid);
    const cmdline_fd = std.posix.openatZ(std.posix.AT.FDCWD, cmdline_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(cmdline_fd);
    const cmdline_len = std.posix.read(cmdline_fd, &cmdline_buf) catch return invalid(pid);

    // Empty cmdline → kernel thread
    if (cmdline_len == 0) return invalid(pid);

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
    var stat_path_buf: [32]u8 = [_]u8{0} ** 32;
    const stat_path = std.fmt.bufPrintZ(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch return invalid(pid);
    const stat_fd = std.posix.openatZ(std.posix.AT.FDCWD, stat_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(stat_fd);
    const stat_len = std.posix.read(stat_fd, &stat_buf) catch return invalid(pid);
    const stat_str = stat_buf[0..stat_len];

    // Parse comm and remaining fields.
    // Format: pid (comm) state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime ...
    const comm_start = std.mem.indexOfScalar(u8, stat_str, '(') orelse return invalid(pid);
    _ = comm_start;
    const comm_end = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse return invalid(pid);

    // Fields after ") " — state is the char right after ")"
    const rest = stat_str[comm_end + 1 ..];
    if (rest.len < 2) return invalid(pid);
    const state = rest[1]; // skip space after ')'

    // Filter zombie/dead processes
    if (state == 'Z' or state == 'X' or state == 'z') return invalid(pid);

    // Parse numeric fields from the substring after "state "
    // The remaining is: " ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice ..."
    const fields_str = rest[2..]; // skip state char and space

    // We need:
    // fields[11] = utime  (0-indexed from after state)
    // fields[12] = stime
    // fields[19] = starttime
    // Total: 20+ fields needed, we need indices 11, 12, 19
    const utime = parseField(fields_str, 11) catch return invalid(pid);
    const stime = parseField(fields_str, 12) catch return invalid(pid);
    const starttime = parseField(fields_str, 19) catch return invalid(pid);

    // Read /proc/pid/statm for RSS
    var statm_path_buf: [34]u8 = [_]u8{0} ** 34;
    const statm_path = std.fmt.bufPrintZ(&statm_path_buf, "/proc/{d}/statm", .{pid}) catch return invalid(pid);
    const statm_fd = std.posix.openatZ(std.posix.AT.FDCWD, statm_path, .{ .ACCMODE = .RDONLY }, 0) catch return invalid(pid);
    defer closeFd(statm_fd);
    const statm_len = std.posix.read(statm_fd, &statm_buf) catch return invalid(pid);

    // statm: "size resident shared text lib data dt"
    const rss_pages = parseField(statm_buf[0..statm_len], 1) catch return invalid(pid);

    // Read /proc/pid/io for I/O counters
    var io_buf: [512]u8 = undefined;
    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;
    var io_path_buf: [30]u8 = [_]u8{0} ** 30;
    if (std.fmt.bufPrintZ(&io_path_buf, "/proc/{d}/io", .{pid})) |io_path| {
        if (std.posix.openatZ(std.posix.AT.FDCWD, io_path, .{ .ACCMODE = .RDONLY }, 0)) |io_fd| {
            defer closeFd(io_fd);
            if (std.posix.read(io_fd, &io_buf)) |io_len| {
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
    const trimmed = std.mem.trim(u8, rest, &.{' ', '\t'});
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch error.Invalid;
}

/// Parse the nth space-separated field from a string as u64.
fn parseField(s: []const u8, index: usize) error{Invalid}!u64 {
    var field_start: usize = 0;
    var field_count: usize = 0;

    for (s, 0..) |c, i| {
        if (c == ' ') {
            if (field_count == index) {
                return std.fmt.parseUnsigned(u64, s[field_start..i], 10) catch return error.Invalid;
            }
            field_count += 1;
            field_start = i + 1;
        }
    }
    // Last field (no trailing space)
    if (field_count == index) {
        if (field_start < s.len and s[field_start] == '\n') {
            // strip trailing newline
            const end = s.len - 1;
            return std.fmt.parseUnsigned(u64, s[field_start..end], 10) catch return error.Invalid;
        }
        return std.fmt.parseUnsigned(u64, s[field_start..], 10) catch return error.Invalid;
    }
    return error.Invalid;
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}

test "parseField" {
    const s = "size 12345 shared text lib data dt\n";
    const val = try parseField(s, 1);
    try std.testing.expectEqual(12345, val);
}
