# porcupine-zig

A Zig 0.16 port of [porcupine-rust](https://github.com/debasishg/porcupine-rust),
which is itself a port of [porcupine](https://github.com/anishathalye/porcupine) —
a fast linearizability checker for testing the correctness of concurrent and
distributed systems.

## What is linearizability?

Linearizability is a correctness condition for concurrent systems. A history of
concurrent operations is linearizable if the operations can be reordered (while
respecting their real-time overlap) into a sequential execution that satisfies
the system's sequential specification.

## What it does

- Checks linearizability of concurrent operation histories against a sequential
  model.
- Accepts both `Operation` (completed call/return pairs with timestamps) and
  raw `Event` (call / return) history formats — use `Operation` for finished
  histories, `Event` for streaming or interleaved logs where calls and returns
  are recorded as they happen.
- Returns a tri-state `CheckResult` (`.ok`, `.illegal`, `.unknown`) with
  optional deadline-based timeout.
- P-compositional checking for partitionable models (e.g. key-value stores
  partitioned by key) — independent partitions run in parallel.
- `PowerSetModel` wrapper for nondeterministic sequential specifications
  (models with branching step semantics — lossy writes, replica reads,
  internal non-observable choices).

## Why it's fast

- DFS with backtracking, memoized by `(committed_set, model_state)` —
  equivalent search states are pruned across symmetric orderings.
- Index-based doubly-linked list (`u32` links instead of pointers) for
  pending operations — half the size, cache-friendlier walks.
- SBO bitset, inline up to 256 operations — no heap traffic for small
  partitions.
- Deferred-clone cache probing — cache hits never touch the heap
  (`hashWithBit` / `eqlWithBit` synthesise `set ∪ {bit}` on the fly).
- Per-partition arena allocator — bulk reclamation, no per-entry frees.
- Thread-pooled parallel partition dispatch with cooperative cancellation:
  atomic-counter pickup, sorted largest-first, kill-flag for sibling abort
  on a found violation.

## Toolchain

Zig 0.16 recommended (minimum 0.15 per `build.zig.zon`). Zero external
dependencies — pure `build.zig` + stdlib.

## Quick start

```zig
const std = @import("std");
const porcupine = @import("porcupine");

// A minimal register model.
const RegInput = struct { is_write: bool, value: i32 };
const Reg = struct {
    pub const State  = i32;
    pub const Input  = RegInput;
    pub const Output = i32;

    pub fn init(_: *const Reg, _: std.mem.Allocator) !State { return 0; }
    pub fn step(_: *const Reg, _: std.mem.Allocator,
                state: *const State, input: *const Input, output: *const Output) !?State {
        if (input.is_write) return input.value;
        if (output.* == state.*) return state.*;
        return null;
    }
    pub fn cloneState(_: *const Reg, _: std.mem.Allocator, s: *const State) !State { return s.*; }
    pub fn deinitState(_: *const Reg, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const Reg, a: *const State, b: *const State) bool { return a.* == b.*; }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const m = Reg{};
    const Op = porcupine.Operation(RegInput, i32);

    // Linearizable: write 42 at [0,10], read 42 at [20,30].
    const ok_history = [_]Op{
        .{ .client_id = 1, .input = .{ .is_write = true, .value = 42 },
           .call = 0, .output = 0, .return_time = 10 },
        .{ .client_id = 2, .input = .{ .is_write = false, .value = 0 },
           .call = 20, .output = 42, .return_time = 30 },
    };
    // The trailing `null` is an optional deadline — pass a `*const Deadline`
    // to bound runtime; `null` means "run to completion".
    std.debug.assert(try porcupine.checkOperations(Reg, alloc, &m, &ok_history, null) == .ok);

    // Not linearizable: same write, but the read returns 7 instead of 42.
    const bad_history = [_]Op{
        .{ .client_id = 1, .input = .{ .is_write = true, .value = 42 },
           .call = 0, .output = 0, .return_time = 10 },
        .{ .client_id = 2, .input = .{ .is_write = false, .value = 0 },
           .call = 20, .output = 7, .return_time = 30 },
    };
    std.debug.assert(try porcupine.checkOperations(Reg, alloc, &m, &bad_history, null) == .illegal);
}
```

## Defining a model

Zig has no trait system, so a "Model" is any struct that comptime satisfies the
shape documented in `src/model.zig`:

- `pub const State`, `pub const Input`, `pub const Output` — type declarations.
- `init`, `step`, `cloneState`, `deinitState`, `statesEqual` — required methods.
- `partition` and `partitionEvents` — optional methods for P-compositional
  checking.

See `tests/integration.zig` for working examples (plain register, partitioned
key-value store, nondeterministic model via `PowerSetModel`).

## Build

```
zig build                             # build the static library
zig build test                        # run unit + integration tests
zig build test -Doptimize=ReleaseFast # run tests with release optimisations
zig build bench -Doptimize=ReleaseFast -- 100 170   # micro-benchmark
```

Indicative numbers under `ReleaseFast`: ~33 µs/check on the 100-op register
bench, ~46 µs/check on the hashmap bench (see `benchmarks/bench.zig`).

## How it works

See [`docs/algorithm.md`](docs/algorithm.md) for the design doc — covers the
DFS + memoization, `lift` / `unlift` mechanics, parallel partition dispatch,
and a fully worked example traced step by step with diagrams of the search
tree, linked list, and cache.

For Zig-specific implementation patterns, see
[`docs/zig-feature-idioms.md`](docs/zig-feature-idioms.md) — walks the Status
bullets below and shows the Zig idiom each feature uses, with source
pointers — and [`docs/zig-idioms.md`](docs/zig-idioms.md) for general Zig
craft (error sets, casts, comptime generics, allocator handling).

## Status

Core features of the Rust port are ported:

- operation-based checking (`checkOperations`) and event-based checking
  (`checkEvents`);
- partitioning via `partition` / `partitionEvents` hooks;
- `PowerSetModel` wrapper for nondeterministic specifications;
- tri-state `CheckResult` with deadline-based early termination;
- bitset SBO (small-buffer-optimised up to 256 operations);
- deferred-clone cache probing (`hashWithBit` + `eqlWithBit`);
- thread-pooled parallel partition dispatch with cooperative cancellation
  (one worker thread per partition, sequential fast path for small workloads
  under a tunable `SEQUENTIAL_THRESHOLD`).

Out of scope for this port: verbose (visualization-producing) entry points,
Quint MBT integration, S2 stream / Jepsen-etcd / KV bench fixtures.

## License

MIT.
