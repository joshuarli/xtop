const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const Pid = types.Pid;

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

        if (buf_offset + 19 > buf_len) break;
        const reclen = std.mem.readInt(u16, buf[buf_offset + 16 ..][0..2], .little);
        if (reclen == 0 or buf_offset + reclen > buf_len) break;
        const d_type = buf[buf_offset + 18];
        const name_start = buf_offset + 19;
        const name_end = buf_offset + reclen;
        const name = buf[name_start..@min(name_end, buf_len)];

        if (d_type == std.posix.DT.DIR) {
            var pid: Pid = 0;
            var valid = name.len > 0;
            for (name) |c| {
                if (c == 0) break;
                if (c < '0' or c > '9') { valid = false; break; }
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
