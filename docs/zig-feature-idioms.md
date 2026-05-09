# Zig idioms by feature

Companion to [`zig-idioms.md`](zig-idioms.md), which catalogues general Zig
craft (const-correctness, error sets, casts, comptime generics). This doc is
**feature-organised**: it walks the seven bullets of the README's "Status"
section and pulls out the Zig-specific implementation patterns each feature
relies on, with pointers into the source.

Read the two together: `zig-idioms.md` answers "how does Zig do X?"; this doc
answers "why did porcupine-zig pick that idiom for *this* feature?"

Sections:

1. [`checkOperations` / `checkEvents`](#1-checkoperations--checkevents)
2. [Partitioning via optional hooks](#2-partitioning-via-optional-hooks)
3. [`PowerSetModel`](#3-powersetmodel--wrapper-as-comptime-type-function)
4. [Tri-state `CheckResult` + deadline](#4-tri-state-checkresult--deadline)
5. [SBO bitset](#5-sbo-bitset)
6. [Deferred-clone cache probe](#6-deferred-clone-cache-probe)
7. [Parallel dispatch with cooperative cancellation](#7-parallel-dispatch-with-cooperative-cancellation)

---

## 1. `checkOperations` / `checkEvents`

> operation-based checking (`checkOperations`) and event-based checking (`checkEvents`).

### Comptime-generic entry points

The two public functions take the model **as a comptime type parameter**, not
as a runtime trait object:

```zig
pub fn checkOperations(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    history: []const Operation(M.Input, M.Output),
    timeout_ns: ?u64,
) !CheckResult {
    model_mod.assertModel(M);
    ...
}
```
(`src/checker.zig:1111`)

Because `M` is comptime, every call site monomorphises a fresh specialisation
— `step`, `cloneState`, `statesEqual` are direct calls, no vtable. This is
the Zig analogue of Rust's `fn check<M: Model>(...)`, but expressed without a
trait declaration: any struct with the right shape works. Zig's name for the
mechanism is "comptime duck-typing."

### Comptime shape assertion at the boundary

To catch a missing method early with a clean error rather than a confusing
"no member named ..." inside the DFS, the public entry calls
`model_mod.assertModel(M)`:

```zig
pub fn assertModel(comptime M: type) void {
    comptime {
        if (!@hasDecl(M, "State")) @compileError(@typeName(M) ++ " missing pub const State");
        if (!@hasDecl(M, "step"))  @compileError(@typeName(M) ++ " missing pub fn step");
        ...
    }
}
```
(`src/model.zig:89`)

`@compileError` runs at compile time inside a `comptime { ... }` block.
`@typeName(M) ++ " ..."` is also comptime — Zig evaluates `++` on
`[]const u8` at comptime when both operands are.

### History parameterised by the model's I/O types

The `history` parameter's element type is `Operation(M.Input, M.Output)` —
pulled out of the model itself rather than threaded as a separate generic.
`Operation` is a function from types to types (see `zig-idioms.md` §7), so
this is a single comptime application that reuses what the model already
declared.

---

## 2. Partitioning via optional hooks

> partitioning via `partition` / `partitionEvents` hooks.

### `@hasDecl` for optional duck-typed methods

Zig has no traits, so optional methods are detected with `@hasDecl` at
comptime:

```zig
if (comptime @hasDecl(M, "partition")) {
    if (try model.partition(allocator, history)) |parts| { ... }
} else {
    // single-partition fast path
}
```
(`src/checker.zig:1130`)

`comptime @hasDecl(M, "partition")` is folded at compile time, so for models
without partitioning the entire branch is dead-stripped — no runtime cost
for the absence of the hook. This is the Zig pattern for what Rust would
express with a default-method on a trait or a separate trait + blanket impl.

### `usingnamespace` is gone — use comptime fall-through

Zig 0.16 removed `usingnamespace`, so `PowerSetModel` can't splat the inner
model's hooks conditionally. The idiom is to define the wrapper method
unconditionally and gate the body on `@hasDecl`:

```zig
pub fn partition(
    self: *const Self,
    allocator: std.mem.Allocator,
    history: []const Operation(Input, Output),
) !?[][]usize {
    if (comptime !@hasDecl(ND, "partition")) return null;
    return self.inner.partition(allocator, history);
}
```
(`src/model.zig:250`)

The `comptime` keyword on the `if` guarantees the dead branch is folded; for
an inner model without `partition`, the wrapper's `partition` reduces to a
one-liner returning `null`.

---

## 3. `PowerSetModel` — wrapper as comptime type function

> `PowerSetModel` wrapper for nondeterministic specifications.

### `fn(comptime ND: type) type` returning a struct

`PowerSetModel(ND)` is the canonical Zig generic: a function from a type to a
type. The returned struct closes over `ND` and exposes `Input`, `Output`,
`State` derived from the inner model:

```zig
pub fn PowerSetModel(comptime ND: type) type {
    return struct {
        inner: ND,
        const Self = @This();

        pub const Input  = ND.Input;
        pub const Output = ND.Output;
        pub const State  = []ND.State;   // power-state = set of inner states
        ...
    };
}
```
(`src/model.zig:139`)

`@This()` inside the returned struct refers to the freshly-minted type for
*this* invocation of `PowerSetModel` — different `ND`s yield different
`Self`s. That's how the wrapper is statically typed to its inner model
without runtime dispatch.

### Conditional `arena_friendly` forwarding

Whether the wrapper can skip per-entry `deinitState` walks depends on whether
the *inner* model can. The check is purely comptime:

```zig
pub const arena_friendly: bool =
    @hasDecl(ND, "arena_friendly") and ND.arena_friendly;
```
(`src/model.zig:154`)

A `pub const` whose initialiser is comptime-evaluable. The checker reads it
via the same `@hasDecl` + value test on the wrapper.

### `errdefer` for partial allocations in `cloneState`

`cloneState` allocates a slice of `ND.State`, then fills each element. If
allocation of element `i` fails, only `[0..i]` are populated — `errdefer`
with an explicit `filled` counter keeps cleanup precise:

```zig
const out = try allocator.alloc(ND.State, state.len);
var filled: usize = 0;
errdefer {
    for (out[0..filled]) |*s| self.inner.deinitState(allocator, s);
    allocator.free(out);
}
for (state.*, 0..) |*src, i| {
    out[i] = try self.inner.cloneState(allocator, src);
    filled = i + 1;
}
```
(`src/model.zig:206`)

`errdefer` runs only on the error return path; the explicit `filled` counter
keeps the cleanup window correct. Use this any time you allocate a slice of
`T` where each element itself owns memory.

### `defer` cleanup that handles both success and error paths

`step` accumulates successors then deduplicates. On the success path
ownership transfers to `dedupe`'s output; on the error path `acc` may still
hold owned states. A single `defer` covers both:

```zig
var acc: std.ArrayList(ND.State) = .empty;
defer {
    // On success `acc` is empty (drained into dedupe). Only the error path
    // leaves items behind — free them.
    for (acc.items) |*s| self.inner.deinitState(allocator, s);
    acc.deinit(allocator);
}
```
(`src/model.zig:177`)

The success branch later does `acc.clearRetainingCapacity()`, which makes
the deferred drain a no-op rather than a double-free.

---

## 4. Tri-state `CheckResult` + deadline

> tri-state `CheckResult` with deadline-based early termination.

### Plain enum, not error union

`.unknown` is a *result*, not an error. A history that times out before
being decided is still a valid outcome — the caller may re-run with a longer
budget. Modelling it as an enum variant keeps the function signature
`!CheckResult`, where the `!` is reserved for genuine allocator/IO failures:

```zig
pub const CheckResult = enum {
    ok,
    illegal,
    unknown,
};
```
(`src/types.zig:11`)

### `?u64` timeout, lifted into a `?Deadline`

The public API takes a relative timeout in nanoseconds; internally that
becomes an absolute monotonic instant computed once and shared across
workers:

```zig
inline fn makeDeadline(timeout_ns: ?u64) ?Deadline { ... }
```
(`src/checker.zig:983`)

`null` propagates through the optional all the way to the worker fast-path
check, which short-circuits when there's no deadline.

### `?Deadline` passed by value, not behind another atomic

The deadline is read-only from worker threads, so it doesn't need
synchronisation:

```zig
pub const Deadline = struct {
    deadline_ns: u64,
    inline fn hasFired(self: Deadline, now: u64) bool {
        return now >= self.deadline_ns;
    }
};
```
(`src/checker.zig:576`)

When a worker checks its deadline and finds it fired, it folds the result
into the *shared* `kill: Atomic(bool)` flag. So there's one shared atomic
for cancellation, not two — the `Deadline` itself stays a plain struct.

---

## 5. SBO bitset

> bitset SBO (small-buffer-optimised up to 256 operations).

### Inline + heap, dispatched by a `chunks` count

The bitset has *both* fields always; which one is live is decided by `chunks`:

```zig
pub const Bitset = struct {
    inline_buf: [inline_cap]u64,    // always present
    heap: []u64,                     // empty slice when unused
    chunks: usize,
    ...
};
```
(`src/bitset.zig:27`)

Const and mut accessors return the right slice from the same condition (the
duplicated bodies are intentional — see `zig-idioms.md` §1):

```zig
pub inline fn data(self: *const Bitset) []const u64 {
    return if (self.chunks > inline_cap)
        self.heap[0..self.chunks]
    else
        self.inline_buf[0..self.chunks];
}
```
(`src/bitset.zig:73`)

`inline` keeps the slice construction cheap regardless of whether the
compiler can fold the branch.

### Empty slice as the "no heap" sentinel

`heap` is `&.{}` when unused, not `null`. `allocator.free(empty_slice)` is a
documented no-op, which makes `deinit` unconditional:

```zig
pub fn deinit(self: *Bitset, allocator: std.mem.Allocator) void {
    // `allocator.free` on an empty slice is a no-op; no guard needed.
    allocator.free(self.heap);
    self.heap = &.{};
    self.chunks = 0;
}
```
(`src/bitset.zig:52`)

Setting `chunks = 0` after free makes the deinit idempotent — a property
the test at `src/bitset.zig:319` pins.

### Allocator-aware, not allocator-owning

The bitset takes the allocator on every operation that touches the heap
(`init`, `clone`, `deinit`) instead of stashing it in the struct. That's
what lets the checker route all bitset memory through a per-worker arena
and reclaim everything in one `arena.deinit()` call when the partition
finishes. A bitset cloned from arena A and freed against arena B would be
a use-after-free; the checker pairs them by construction.

### `@splat` for zero-init of fixed arrays

```zig
.inline_buf = @splat(0),
```
(`src/bitset.zig:41`)

`@splat` is the comptime-aware way to broadcast a scalar to a fixed-length
array — equivalent to `[_]u64{0} ** inline_cap` but inferred from the
destination type, so adjusting `inline_cap` doesn't require updating the
literal.

### Asserts on every mutation

The DFS depends on bit positions being in-range and (for `hashWithBit` /
`eqlWithBit`) currently clear. Both are pinned with `std.debug.assert`:

```zig
pub inline fn set(self: *Bitset, pos: usize) void {
    std.debug.assert(pos < self.chunks * 64);
    ...
}
```
(`src/bitset.zig:101`)

Asserts are checked under Debug / ReleaseSafe, no-ops under ReleaseFast —
exactly what you want for invariants whose violation would corrupt cache
keys silently.

---

## 6. Deferred-clone cache probe

> deferred-clone cache probing (`hashWithBit` + `eqlWithBit`).

### Synthesise the would-be hash without mutating

Setting a bit changes the hash by exactly one `u64`-XOR plus the `1` for
popcnt. The function returns that value without touching the bitset:

```zig
pub inline fn hashWithBit(self: *const Bitset, pos: usize) u64 {
    std.debug.assert(pos < self.chunks * 64);
    const ix = index(pos);
    const old_word = self.data()[ix.major];
    std.debug.assert((old_word >> ix.minor) & 1 == 0); // bit must be clear
    const new_word = old_word | (@as(u64, 1) << ix.minor);
    return self.hash() ^ old_word ^ new_word ^ 1;
}
```
(`src/bitset.zig:141`)

`inline fn` matters here: the function is called once per cursor visit on
the hot path, and inlining lets the compiler fuse the hash computation with
the surrounding `cacheContainsWithBit` probe.

### `eqlWithBit` fabricates the differing word during the compare loop

Equality is the same trick: instead of materialising a clone, OR the
would-be set bit into the relevant word *during the comparison*:

```zig
const set_mask = @as(u64, 1) << ix.minor;
for (a, b, 0..) |x, y, i| {
    const adj = if (i == ix.major) x | set_mask else x;
    if (adj != y) return false;
}
```
(`src/bitset.zig:181`)

Zig's multi-iterable `for` (`for (a, b, 0..) |x, y, i|`) walks both slices
in lockstep without an explicit index variable — the `0..` produces a range
whose elements are the implicit indices. Same shape as Rust's
`iter().zip().enumerate()`, but built into the syntax.

### Identity hash on a pre-mixed `u64`

The cache stores `(bitset, state)` keyed by `bitset.hash()`. Since `hash()`
is already well-mixed, the hash map shouldn't re-hash it. The custom context
is a comptime parameter to `std.HashMapUnmanaged`:

```zig
const U64IdentityCtx = struct {
    pub fn hash(_: U64IdentityCtx, k: u64) u64 { return k; }
    pub fn eql(_: U64IdentityCtx, a: u64, b: u64) bool { return a == b; }
};
```
(`src/checker.zig:419`)

Because the context is comptime, the calls to `hash` and `eql` inline to
register moves — identity hashing has zero runtime overhead.

---

## 7. Parallel dispatch with cooperative cancellation

> thread-pooled parallel partition dispatch with cooperative cancellation
> (one worker thread per partition, sequential fast path for small workloads
> under a tunable `SEQUENTIAL_THRESHOLD`).

### `std.atomic.Value(bool)` for the kill flag

A single shared atomic carries the cancellation signal. Workers poll it on
a 4096-iteration cadence:

```zig
const kill_poll_mask: usize = 4095;
...
if ((iter_count & kill_poll_mask) == 0) {
    if (kill.load(.monotonic)) return false;
    ...
}
```
(`src/checker.zig:659`)

`.monotonic` is the weakest ordering — sufficient because the kill flag is
truly monotonic (only flips false→true once) and the exact iteration where
each worker observes it doesn't matter. Stronger orderings would buy nothing
here, just slow down the poll.

### Three atomics, one final result

`kill`, `timed_out`, and `definitive_illegal` are separate. The split exists
because **the difference between "found a real violation" and "stopped
because a sibling/deadline aborted us" matters for the result**:

```zig
if (!self.kill.load(.monotonic) and !self.timed_out.load(.monotonic)) {
    self.definitive_illegal.store(true, .monotonic);
}
self.result_ok.store(false, .monotonic);
self.kill.store(true, .monotonic);
```
(`src/checker.zig:855`)

Translating to the public `CheckResult`: `definitive_illegal && !ok` →
`.illegal`; `!ok && !definitive_illegal` → `.unknown`; `ok` → `.ok`. All
three states reachable, all from atomic loads — no lock anywhere.

### Atomic counter for partition pickup

Workers pull the next partition off `next_idx` with `fetchAdd`, so threads
aren't pre-bound to partition indices:

```zig
const idx = self.next_idx.fetchAdd(1, .monotonic);
if (idx >= self.partitions.len) return;
```
(`src/checker.zig:835`)

Combined with the largest-first sort earlier, the longest-running partition
starts on the first worker that wakes up, and the remaining workers drain
shorter ones in whatever order they finish. No work-stealing queue needed —
the atomic counter is the queue.

### Per-worker arena allocator, reset between partitions

Each worker owns one arena, reset between partitions:

```zig
var arena = std.heap.ArenaAllocator.init(self.allocator);
defer arena.deinit();
const alloc = arena.allocator();

while (true) {
    if (self.kill.load(.monotonic)) return;
    const idx = self.next_idx.fetchAdd(1, .monotonic);
    if (idx >= self.partitions.len) return;
    _ = arena.reset(.retain_capacity);
    ...
}
```
(`src/checker.zig:823`)

`reset(.retain_capacity)` keeps the underlying pages so subsequent partitions
run against an already-warm allocator. Bulk reclamation is what makes the
model's `cloneState` cheap — under `arena_friendly` the per-entry `deinit`
walk is skipped entirely.

### `std.Thread.spawn` directly, no thread pool

Workers are spawned per-run, not pulled from a long-lived pool:

```zig
th.* = try std.Thread.spawn(.{}, Ctx.run, .{ctx});
...
for (threads) |th| th.join();
```
(`src/checker.zig:958`)

For partitioned histories, partition count is bounded by problem size and
threads are bounded by `cpu_count`, so spawning per-run is fine. The
`sequential_threshold` (2000 entries) skips even that:

```zig
if (total_entries < sequential_threshold) {
    // sequential, smallest-first
}
```
(`src/checker.zig:899`)

On macOS thread spawn is ~5–20 µs; for small workloads (KV c10 ≈ 700 total
entries) the spawn overhead would dominate the actual DFS, so the sequential
path wins.

### Comptime function-as-callback for sort

Sorting partitions largest-first uses an inline anonymous struct holding the
comparator:

```zig
std.mem.sort([]const EntryOf(M.Input, M.Output), partitions, {}, struct {
    fn lessThan(_: void, a: ..., b: ...) bool { return a.len > b.len; }
}.lessThan);
```
(`src/checker.zig:928`)

`struct { fn ... }.lessThan` is the Zig idiom for "lambda with no captures":
the function is a member of a one-off type, and `.lessThan` is a
comptime-known function pointer the compiler can inline through. Avoids the
ergonomic noise of a top-level named comparator function for what is
genuinely a one-line lambda.

### `WorkerCtx` as a generic struct, kept allocator-aware

The shared per-run state is itself a comptime-generic struct, so each
specialisation knows the model's `Entry` type at compile time:

```zig
fn WorkerCtx(comptime M: type) type {
    return struct {
        allocator: std.mem.Allocator,
        model: *const M,
        partitions: [][]const EntryOf(M.Input, M.Output),
        next_idx: *std.atomic.Value(usize),
        kill: *std.atomic.Value(bool),
        ...
        const Self = @This();
        fn run(self: *Self) void { ... }
    };
}
```
(`src/checker.zig:809`)

The doc comment above this struct calls out that the embedded `allocator`
must be **thread-safe** because `WorkerCtx.run` is called concurrently from
multiple threads — that contract belongs to the caller of `checkOperations`
and is documented at `src/checker.zig:1102`. This is a recurring Zig
pattern: don't bake thread-safety into a struct, name the requirement on
the allocator parameter and let the caller satisfy it however they prefer
(`std.heap.smp_allocator`, `std.testing.allocator`, etc.).
