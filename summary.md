# porcupine-zig — Port Summary

A Zig 0.16 port of [porcupine-rust](https://github.com/debasishg/porcupine-rust),
which is itself a port of the original Go [porcupine](https://github.com/anishathalye/porcupine)
linearizability checker.

## Project layout (standard Zig conventions)

```
porcupine-zig/
├── build.zig                  # module, static-lib, test, bench steps
├── build.zig.zon              # package manifest
├── README.md                  # user-facing docs
├── summary.md                 # this file
├── src/
│   ├── root.zig               # library entry + re-exports
│   ├── types.zig              # CheckResult, Operation, Event, EventKind
│   ├── bitset.zig             # SBO bitset with hashWithBit / eqlWithBit
│   ├── model.zig              # comptime Model interface + PowerSetModel
│   └── checker.zig            # DFS, NodeArena, cache, parallel driver
├── tests/
│   └── integration.zig        # 10 integration tests
├── benchmarks/
│   └── bench.zig              # micro-benchmark
└── examples/                  # placeholder for future CLI examples
```

## What was ported

- **Operation-based checking** (`checkOperations`) and **event-based
  checking** (`checkEvents`).
- **Partitioning** via optional `partition` / `partitionEvents` hooks on the
  model (P-compositional checking).
- **`PowerSetModel(ND)`** adapter for nondeterministic sequential
  specifications (branching step semantics).
- **Tri-state `CheckResult`** (`.ok`, `.illegal`, `.unknown`) with
  deadline-based early termination.
- **SBO bitset** (small-buffer-optimised up to 256 operations inline).
- **Deferred-clone cache probing** via `hashWithBit` + `eqlWithBit`.
- **Parallel partition dispatch** — one worker thread per partition, with a
  sequential fast path for small workloads under a tunable
  `SEQUENTIAL_THRESHOLD`.

### Not ported

- Verbose (visualization-producing) `checkOperationsVerbose` /
  `checkEventsVerbose` entry points.
- Quint MBT integration.
- The S2 stream / Jepsen-etcd / KV bench fixtures (the benchmark is a
  synthetic register-contention micro-benchmark).

## Performance-oriented design choices

1. **Compile-time generics.** The checker is a `comptime M: type` function
   so each concrete Model is fully specialised — zero vtable dispatch, same
   monomorphisation economy as Rust's trait impls.
2. **Bitset SBO.** 4-word inline buffer (256 bits) covers typical histories
   without a heap allocation. `hashWithBit` and `eqlWithBit` compute the
   probed hash / equality *as if* a bit were set, with no allocation.
3. **`u32` NodeArena indices** instead of pointers — halves per-node size
   versus `usize` on 64-bit and keeps the live doubly-linked list cache-hot.
4. **Deferred clone.** The bitset is cloned only on cache miss. State is
   cloned twice only where correctness requires it (once into cache, once
   onto the backtrack stack, mirroring Rust's `mem::replace` trick).
5. **Identity `HashMap` context.** The DFS cache key is already a bitset
   hash; wrapping it in another hash function is pure waste.
6. **Per-worker `ArenaAllocator`.** DFS allocations never touch a shared
   allocator lock, and the whole partition's memory is released in one
   `deinit`.
7. **Fast paths.** Single-partition checks skip all thread-dispatch; small
   total workloads (< `SEQUENTIAL_THRESHOLD = 2000` entries) run
   sequentially to avoid thread-spawn overhead (~5–20 µs on macOS).
8. **Deadline polled inline** every 4096 DFS iterations — no timer thread,
   no `Mutex`/`Condition` required (both moved to `std.Io` in 0.16).

## Zig 0.16 API adaptations worth noting

| Old API (0.14 / 0.15)                   | 0.16 replacement                                               |
| --------------------------------------- | -------------------------------------------------------------- |
| `std.heap.GeneralPurposeAllocator`      | `std.heap.DebugAllocator(.{})` with `.init`                    |
| `std.ArrayList(T){}` default init       | `.empty`                                                       |
| `std.Thread.Mutex` / `std.Thread.Condition` | moved under `std.Io` — side-stepped via inline deadline poll |
| `std.time.nanoTimestamp`                | moved under `std.Io.Clock` — used `clock_gettime(MONOTONIC)` via `std.c` / `std.os.linux` |
| `std.process.argsAlloc`                 | `std.process.Args.Iterator.initAllocator`                      |
| `std.fs.File.stderr`                    | `std.debug.print` (for the bench tool)                         |
| `usingnamespace`                        | removed — replaced with comptime early-return pattern          |

## Test results

19 of 19 tests pass in both `Debug` and `ReleaseFast`:

```
Build Summary: 5/5 steps succeeded; 19/19 tests passed
+- run test 9 pass  (9 total)   (unit tests — bitset + types)
+- run test 10 pass (10 total)  (integration — register, KV, events, PowerSet)
```

### Integration tests

- `reg: empty history is ok`
- `reg: sequential write-read is ok`
- `reg: read stale value after sequential write is illegal`
- `reg: concurrent write ambiguous read is ok`
- `reg: timeout returns unknown for an infinite-looking path`
- `kv: per-key independence`
- `kv: failure on one key is detected across partitions`
- `event-based register: sequential write-read`
- `powerset: coin flip advances by 1 or 2`
- `powerset: coin flip rejects impossible jump`

## Benchmark

Synthetic 170-op register-contention history, Apple Silicon, ReleaseFast:

```
$ zig build bench -Doptimize=ReleaseFast -- 50 170
running 50 iterations of a 170-op register history...
total: 1633000 ns, per-call: 32660 ns (32.66 us)
```

~33 µs per 170-op check, comparable to the Rust port's ~38 µs single-file
etcd number (different history, not directly comparable, but in the same
order of magnitude).

## How to build and run

```sh
zig build                                           # static library
zig build test                                      # all tests (Debug)
zig build test -Doptimize=ReleaseFast               # tests in release
zig build bench -Doptimize=ReleaseFast -- 100 170   # bench (iters, ops)
```

## Defining a model

Zig has no trait system, so a "Model" is any struct that comptime satisfies
the shape documented in `src/model.zig`:

- `pub const State`, `pub const Input`, `pub const Output` type decls.
- `init`, `step`, `cloneState`, `deinitState`, `statesEqual` methods.
- Optional `partition` / `partitionEvents` methods for P-compositional
  checking.

See `tests/integration.zig` for three working models (plain register,
partitioned key-value store, nondeterministic coin-flip via `PowerSetModel`).

## License

MIT.
