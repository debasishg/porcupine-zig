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

## Features

- Check linearizability of concurrent operation histories against a sequential
  model.
- Support for both timestamped `Operation` and raw `Event` (call / return)
  history formats.
- Optional timeout-based checking with a tri-state `CheckResult`
  (`.ok`, `.illegal`, `.unknown`).
- P-compositional checking for partitionable models (e.g. key-value stores
  partitioned by key).
- Efficient DFS with backtracking, bitset-based state tracking, and a
  hash-chained cache keyed by the bitset hash.
- `PowerSetModel` wrapper for nondeterministic sequential specifications
  (models with branching step semantics — lossy writes, replica reads,
  internal non-observable choices).

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
    const history = [_]porcupine.Operation(RegInput, i32){
        .{ .client_id = 1, .input = .{ .is_write = true, .value = 42 },
           .call = 0, .output = 0, .return_time = 10 },
        .{ .client_id = 2, .input = .{ .is_write = false, .value = 0 },
           .call = 20, .output = 42, .return_time = 30 },
    };

    const res = try porcupine.checkOperations(Reg, alloc, &m, &history, null);
    std.debug.assert(res == .ok);
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

## Status

Core features of the Rust port are ported:

- operation-based checking (`checkOperations`) and event-based checking
  (`checkEvents`);
- partitioning via `partition` / `partitionEvents` hooks;
- `PowerSetModel` wrapper for nondeterministic specifications;
- tri-state `CheckResult` with deadline-based early termination;
- bitset SBO (small-buffer-optimised up to 256 operations);
- deferred-clone cache probing (`hashWithBit` + `eqlWithBit`);
- work-stealing-free parallel partition dispatch (one worker thread per
  partition, sequential fast path for small workloads under a tunable
  `SEQUENTIAL_THRESHOLD`).

Not yet ported: verbose (visualization-producing) entry points, Quint MBT
integration, the S2 stream / Jepsen-etcd / KV bench fixtures.

## License

MIT.
