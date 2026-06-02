// xtop library: Linux /proc filesystem parsers and process model.
//
// Public API surface. The binary (main.zig, render.zig) consumes this.
// Tests import through root.zig for API coverage validation.

pub const types = @import("types.zig");
pub const proc = @import("proc.zig");
pub const scan = @import("scan.zig");
pub const cpu = @import("cpu.zig");
pub const mem = @import("mem.zig");
pub const net = @import("net.zig");
pub const power = @import("power.zig");
pub const store = @import("store.zig");
pub const fixture = @import("fixture.zig");

test {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(proc);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(cpu);
    std.testing.refAllDecls(mem);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(fixture);
    std.testing.refAllDecls(@This());
}

const std = @import("std");
