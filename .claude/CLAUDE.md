# porcupine-zig

A Zig 0.16 port of [porcupine-rust](https://github.com/debasishg/porcupine-rust),
itself a port of [anishathalye/porcupine](https://github.com/anishathalye/porcupine).
Fast linearizability checker for concurrent / distributed system histories.

The Rust source of truth lives at `../porcupine-rust`. When porting or cross-
checking behavior, read the Rust code first, then translate idiomatically — do
not mirror Rust idioms where Zig has a better way.

## Toolchain

- **Zig**: 0.16 (minimum 0.15 per `build.zig.zon`). Assume the user is on a
  recent dev build; do not downgrade syntax to pre-0.15.
- Build system: pure `build.zig` + `build.zig.zon`, no external dependencies.

## Layout

```
src/
  root.zig        public module entry (re-exports the API surface)
  types.zig       Operation / Event / CheckResult / LinearizationInfo
  model.zig       Model shape contract + PowerSetModel wrapper
  bitset.zig      SBO bitset (inline up to 256 ops, heap above)
  checker.zig     DFS linearizability engine + parallel partition dispatch
tests/
  integration.zig end-to-end tests against example models
benchmarks/
  bench.zig       micro-benchmark entry point
docs/             design notes (internal, not shipped)
                  └── algorithm.md — canonical reference for the checker:
                      DFS, deferred-clone cache, calls stack, debug invariants.
                      Read first when touching checker.zig or bitset.zig.
examples/         currently empty; reserve for user-facing examples
```

`root.zig` is the single public entry. New public symbols must be re-exported
there; do not ask consumers to reach into submodules.

## Build / test / bench

```
zig build                                          # static lib
zig build test                                     # unit + integration tests
zig build test -Doptimize=ReleaseFast              # tests with optimisations
zig build bench -Doptimize=ReleaseFast -- 100 170  # micro-benchmark
```

Always run `zig build test` before declaring a change done. For perf-sensitive
changes in `checker.zig` or `bitset.zig`, also run the bench with
`-Doptimize=ReleaseFast` and compare against the prior number.

## Model contract (comptime duck-typing)

Zig has no traits. A "Model" is any struct that satisfies the shape in
`src/model.zig`:

- `pub const State`, `pub const Input`, `pub const Output`
- `init(self, allocator) !State`
- `step(self, allocator, *const State, *const Input, *const Output) !?State`
  returning `null` for an illegal transition
- `cloneState`, `deinitState`, `statesEqual`
- Optional: `partition` / `partitionEvents` for P-compositional checking

When adding a new model method, update the contract comment in `model.zig` and
mention any new callers in `checker.zig`.

## Coding conventions

- **Allocation**: every function that allocates takes an explicit
  `std.mem.Allocator`. No hidden global allocators. Pair each allocation with
  a clear owner; prefer `defer` / `errdefer` immediately after the allocation.
- **Errors**: return `!T` with specific error sets. Don't swallow errors into
  `anyerror` unless crossing an FFI or test boundary.
- **Naming**: `camelCase` for functions, `PascalCase` for types,
  `snake_case` for fields and locals — match the existing code.
- **Tests**: colocate unit tests in the same file under `test "name" { ... }`.
  Integration-level tests go in `tests/integration.zig`. `root.zig` uses
  `std.testing.refAllDecls(@This())` to pull unit tests into `zig build test`.
- **Comments**: only when the *why* is non-obvious. Don't restate what the
  code does. Doc comments (`///`) on public items are encouraged.
- **No backwards-compat shims** for internal refactors — this is a 0.x library,
  break things when it simplifies the code.

## Performance notes

- The hot path is `checker.zig`'s DFS: bitset hashing, cache probing
  (`hashWithBit` / `eqlWithBit`), and `step` invocations. Avoid heap
  allocation inside the inner loop; reuse buffers.
- `bitset.zig` is SBO up to 256 operations — keep the inline path
  branch-free and avoid bounds checks in release builds.
- Parallel partition dispatch has a `SEQUENTIAL_THRESHOLD` fast path; new
  work added to the parallel path should respect it.

## When porting from porcupine-rust

1. Locate the Rust function in `../porcupine-rust/src/`.
2. Translate the algorithm, not the syntax. Rust traits → Zig comptime
   duck-typing; `Box<dyn Trait>` → function-pointer struct or comptime
   generic; `Arc<Mutex<T>>` → revisit whether shared mutation is actually
   needed.
3. Add an integration test in `tests/integration.zig` matching the Rust
   test coverage for that function.
4. Cross-check behavior on a non-trivial input before claiming parity.

## Status (see README.md for the full list)

Ported: `checkOperations`, `checkEvents`, partitioning, `PowerSetModel`,
tri-state `CheckResult`, SBO bitset, deferred-clone cache probing, parallel
partition dispatch.

Not yet ported: verbose / visualization entry points, Quint MBT integration,
S2 stream / Jepsen-etcd / KV bench fixtures.
