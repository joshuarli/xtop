# xtop — Linux process monitor

## Build & Test

```sh
make debug      # debug build → zig-out/bin/xtop
make release    # optimized build
make test       # run all unit tests
make clean      # remove build artifacts
```

Direct:
```sh
zig build                       # debug
zig build -Doptimize=ReleaseSafe # release
zig build test                  # test suite
zig test src/<mod>.zig -I src   # single module
```

## Architecture

```
main.zig      entry, CLI, signals, main loop (1Hz tick)
types.zig     all structs: Process, RingBuffer, CpuCore, MemState, NetState, ...
proc.zig      read /proc/pid/{stat,statm,cmdline,io} for one PID
store.zig     ProcessStore: HashMap<(pid,starttime), Process>, update/cleanup/sort
cpu.zig       parse /proc/stat → per-core CPU deltas
mem.zig       parse /proc/meminfo → MemState
net.zig       parse /proc/net/dev → NetState (RX/TX rates + totals)
scan.zig      scan /proc for numeric PIDs via getdents64
render.zig    terminal rendering (alt screen, box borders, block-char charts)
fixture.zig   load raw /proc fixture files for tests
```

**Data flow per tick:** `scan` → `Io.async(proc.readProcData)` for each PID → `store.updateProcess` (CPU% delta, I/O rates) → `store.cleanupStore` → sort → `render`

**Key design decisions:**
- RingBuffers only for system-level history (mem, swap, net, per-core CPU), not per-process
- Process CPU% via delta of utime+stime between ticks (htop-style)
- PID disambiguation via (pid, starttime) composite key
- Kernel threads filtered by empty /proc/pid/cmdline
- `std.Io.Threaded` (thread pool) for parallel /proc reads

## Test Infrastructure

**Unit tests** live in `test` blocks within each source file. `test_runner.zig` imports all modules; `zig build test` compiles and runs them.

**Fixtures** (`fixtures/`): raw /proc snapshots captured across 3 ticks. Each tick subdirectory contains `stat`, `meminfo`, `netdev`, and per-PID subdirectories with `stat`, `statm`, `cmdline`, `io`. Use `fixture.load(buf, dir, name)` to load a fixture file.

## Coding Style

- Zig 0.16.0 stdlib only, Linux only, x86_64 + aarch64
- No TUI frameworks, no config system, no io_uring
- Short names in render.zig (color codes, frequent locals) — the file is dense by necessity
- Descriptive names elsewhere
- Prefer fixed buffers + slices over heap allocation in hot paths
- `defer` for cleanup; no manual free in success paths
- Errors propagate via `try`/`catch`; silent `catch {}` used only for non-critical rendering failures

**Test-only code stays out of release builds by construction.** Test instrumentation (`parse*` helpers, `fixture.zig`) is either private or never imported by production code. Zig's dead code elimination strips anything unreachable from the call graph — no feature flags needed. Don't add test-only imports to production modules; keep tests in `test {}` blocks within the same file.
