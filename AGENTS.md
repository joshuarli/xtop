# xtop — Linux process monitor

## Build & Test

```sh
zig build                       # debug build → zig-out/bin/xtop
zig build run                   # build + run
zig build -Doptimize=ReleaseSafe # release build
zig build test                  # test suite
```

Before committing, run:
```sh
zig fmt --check src/*.zig build.zig
zig build test
```

Format errors in `zig fmt --check` are **hard failures** — fix before committing.

## Architecture

```
main.zig      entry, CLI, signals, main loop (1Hz tick)
types.zig     all structs: Process, RingBuffer, CpuCore, MemState, NetState, ...
proc.zig      read /proc/pid/{stat,statm,cmdline,io} for one PID
store.zig     ProcessStore: HashMap<(pid,starttime), Process>, update/cleanup/sort
cpu.zig       parse /proc/stat → per-core CPU deltas
mem.zig       parse /proc/meminfo → MemState
net.zig       parse /proc/net/dev → NetState (RX/TX rates + totals)
power.zig     read Intel RAPL energy_uj from /sys/class/powercap → PowerState (watts)
scan.zig      scan /proc for numeric PIDs via getdents64
render.zig    terminal rendering (alt screen, box borders, block-char charts)
fixture.zig   load raw /proc fixture files for tests
```

**Data flow per tick:** `scan` → `Io.async(proc.readProcData)` for each PID → `store.updateProcess` (CPU% delta, I/O rates) → `store.cleanupStore` → sort → `render`

System-level reads each tick: `cpu.readCpuStat` → `mem.readMemInfo` → `net.readNetDev` → `power.readPowerInfo` → append % to ring buffers

**Power tracking** (`power.zig`): reads `/sys/class/powercap/intel-rapl:0/energy_uj` (cumulative microjoules, root-only). Computes watts as `Δenergy / Δtime` across the 1s tick interval. Handles counter wrap via `max_energy_range_uj`. On first call samples a baseline (no power computed). On permission failure sets `has_perms = false` — render shows `"(root required for power stats)"` instead of the chart. The power graph uses the same `renderChart()` as memory, with wattage scaled to max observed.

**Key design decisions:**
- RingBuffers only for system-level history (mem, swap, net, power, per-core CPU), not per-process
- Process CPU% via delta of utime+stime between ticks (htop-style)
- PID disambiguation via (pid, starttime) composite key
- Kernel threads filtered by empty /proc/pid/cmdline
- `std.Io.Threaded` (thread pool) for parallel /proc reads

## Test Infrastructure

**Unit tests** live in `test` blocks within each source file. `test_runner.zig` imports all modules; `zig build test` compiles and runs them.

**Fixtures** (`fixtures/`): raw /proc snapshots captured across 3 ticks. Each tick subdirectory contains `stat`, `meminfo`, `netdev`, and per-PID subdirectories with `stat`, `statm`, `cmdline`, `io`. Use `fixture.load(buf, dir, name)` to load a fixture file.

## Comptime usage

- **RingBuffer(T, size)** is a generic comptime type. `SampleRing = RingBuffer(Sample, RING_SIZE)` is the concrete alias used everywhere.
- **CpuCore field iteration** via `@typeInfo(CpuCore).@"struct".fields` — the struct field order IS the /proc/stat column order. Do not reorder CpuCore fields.
- **`charset` struct** with comptime-generated `is_digit` and `is_space` lookup tables. Zero-cost at runtime.
- **`@compileError`** platform guard: `builtin.os.tag != .linux` fails at compile time.

## Coding Style

- Zig 0.16.0 stdlib only, Linux only, x86_64 + aarch64
- No TUI frameworks, no config system, no io_uring
- Short names in render.zig (color codes, frequent locals) — the file is dense by necessity
- Descriptive names elsewhere
- Prefer fixed buffers + slices over heap allocation in hot paths
- `defer` for cleanup; no manual free in success paths
- Errors propagate via `try`/`catch`; `catch` with `logErr()` for non-critical hot-path failures
- Per-tick allocations use an `ArenaAllocator` (freed in one shot at end of tick)
- `pid_to_key: HashMap(Pid, ProcessKey)` provides O(1) PID-reuse detection alongside the main store

## Deliberate Non-Goals

- **No `build.zig.zon`** — zero external dependencies. The project is stdlib-only.
- **No config file / CLI flags** — sort key (c/m) and quit (q) are the only controls. No YAML/TOML/JSON config, no `--sort`, no `--interval`.

**Test-only code stays out of release builds by construction.** Test instrumentation (`parse*` helpers, `fixture.zig`) is either private or never imported by production code. Zig's dead code elimination strips anything unreachable from the call graph — no feature flags needed. Don't add test-only imports to production modules; keep tests in `test {}` blocks within the same file.
