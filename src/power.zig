const std = @import("std");
const linux = std.os.linux;

const PowerState = @import("types.zig").PowerState;

const RAPL_PATH = "/sys/class/powercap/intel-rapl:0";

fn readFileInt(path: [*:0]const u8, file: [*:0]const u8) u64 {
    var pb: [256]u8 = undefined;
    const full = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ path, file }) catch return 0;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, full, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = linux.close(fd);
    var buf: [32]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return 0;
    return std.fmt.parseUnsigned(u64, std.mem.trimEnd(u8, buf[0..n], "\n"), 10) catch 0;
}

/// Read RAPL energy counter and compute power in watts.
/// On first call, samples initial energy and returns (no power computed).
/// On permission failure, sets has_perms=false and returns silently.
pub fn readPowerInfo(state: *PowerState) void {
    if (!state.has_perms) return;

    // Open energy_uj directly to detect permission errors.
    // max_energy_range_uj is world-readable but energy_uj requires root,
    // so we can't rely on a dual-read heuristic.
    var pb: [256]u8 = undefined;
    const epath = std.fmt.bufPrintZ(&pb, "{s}/energy_uj", .{RAPL_PATH}) catch {
        state.has_perms = false;
        return;
    };
    const efd = std.posix.openatZ(std.posix.AT.FDCWD, epath, .{ .ACCMODE = .RDONLY }, 0) catch {
        state.has_perms = false;
        return;
    };
    defer _ = linux.close(efd);

    var buf: [32]u8 = undefined;
    const n = std.posix.read(efd, &buf) catch {
        state.has_perms = false;
        return;
    };
    const energy = std.fmt.parseUnsigned(u64, std.mem.trimEnd(u8, buf[0..n], "\n"), 10) catch {
        state.has_perms = false;
        return;
    };

    if (state.max_energy_range_uj == 0) {
        state.max_energy_range_uj = readFileInt(RAPL_PATH, "max_energy_range_uj");
    }

    // First sample: store baseline, no power computed yet
    if (state.prev_energy_uj == 0) {
        state.prev_energy_uj = energy;
        return;
    }

    // Compute delta, handling counter wrap
    const delta_uj: i65 = @as(i65, @intCast(energy)) -| @as(i65, @intCast(state.prev_energy_uj));
    const delta = if (delta_uj < 0)
        @as(i65, @intCast(state.max_energy_range_uj)) + delta_uj
    else
        delta_uj;

    state.prev_energy_uj = energy;

    const watts = @as(f64, @floatFromInt(delta)) / 1_000_000.0;
    state.curr_watts = watts;
    if (watts > state.max_watts) state.max_watts = watts;
    if (state.max_watts < 1.0) state.max_watts = 1.0;
}
