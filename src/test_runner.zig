const std = @import("std");
const types = @import("types.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");
const cpu = @import("cpu.zig");
const mem = @import("mem.zig");
const net = @import("net.zig");
const fixture = @import("fixture.zig");

test {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(proc);
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(cpu);
    std.testing.refAllDecls(mem);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(fixture);
    std.testing.refAllDecls(@This());
}
