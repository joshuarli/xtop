const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const Pid = types.Pid;
const is_digit = types.charset.is_digit;

/// Kernel ABI: linux_dirent64 as returned by getdents64(2).
const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8, // variable-length; name extends past this field
};

/// Scan /proc for numeric directory entries (PIDs). Returns slice into pids.
pub fn scanProc(pids: []Pid) ![]Pid {
    const dir = try std.posix.openatZ(std.posix.AT.FDCWD, "/proc", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(dir);

    var buf: [4096]u8 align(8) = undefined;
    var count: usize = 0;
    var buf_offset: usize = 0;
    var buf_len: usize = 0;

    while (count < pids.len) {
        if (buf_offset >= buf_len) {
            const n = linux.getdents64(dir, &buf, buf.len);
            const signed: isize = @bitCast(n);
            if (signed < 0) break;
            if (n == 0) break;
            buf_len = n;
            buf_offset = 0;
        }

        if (buf_offset + @sizeOf(LinuxDirent64) > buf_len) break;
        const reclen = std.mem.readInt(u16, buf[buf_offset + @offsetOf(LinuxDirent64, "d_reclen") ..][0..2], .little);
        if (reclen == 0 or buf_offset + reclen > buf_len) break;
        const d_type = buf[buf_offset + @offsetOf(LinuxDirent64, "d_type")];
        const name_start = buf_offset + @offsetOf(LinuxDirent64, "d_name");
        const name_end = buf_offset + reclen;
        const name = buf[name_start..@min(name_end, buf_len)];

        if (d_type == std.posix.DT.DIR) {
            var pid: Pid = 0;
            var valid = name.len > 0;
            for (name) |c| {
                if (c == 0) break;
                if (!is_digit[c]) {
                    valid = false;
                    break;
                }
                pid = pid * 10 + @as(Pid, c - '0');
            }
            if (valid and pid > 0) {
                pids[count] = pid;
                count += 1;
            }
        }
        buf_offset += reclen;
    }
    return pids[0..count];
}

test "scanProc reads PIDs from /proc" {
    // Integration test: /proc must exist and contain at least PID 1.
    var pids: [4096]Pid = undefined;
    const found = try scanProc(&pids);
    try std.testing.expect(found.len > 0);

    var has_init = false;
    for (found) |p| {
        if (p == 1) has_init = true;
    }
    try std.testing.expect(has_init);
}
