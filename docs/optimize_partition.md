# Partition-invariant checks — Zig and Rust optimizations

This note covers improvements to the debug-only invariant checks that validate
what a model's `partition` / `partitionEvents` (Rust: `partition_ops` /
`partition_events`) returns. The Zig change has been applied; the Rust section
is a proposal.

## Context

`INV-LIN-03` (P-Compositionality) says the index sets returned by the model's
partitioner must satisfy three conditions:

- **(a) disjoint** — no index appears in two partitions
- **(b) complete** — every index in `[0, history.len)` appears in exactly one partition
- **(c) in-bounds** — every index is `< history.len`

A partitioner that violates (a) double-counts work. A partitioner that violates
(b) silently drops events, making the per-partition DFS skip them — the checker
can then return `Ok` on an unlinearizable history. A partitioner that violates
(c) indexes out of the history slice.

## Zig: applied change

### Before

`src/checker.zig` had:

```zig
fn assertPartitionIndependent(parts: []const []const usize) void {
    if (builtin.mode != .Debug) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var seen: std.AutoHashMap(usize, void) = .init(arena.allocator());
    for (parts) |p| {
        for (p) |idx| {
            const gop = seen.getOrPut(idx) catch return;
            std.debug.assert(!gop.found_existing);
        }
    }
}
```

This only enforced (a). A partitioner that silently dropped events (violating
(b)) or returned `idx >= history.len` (violating (c)) would pass.

### After

```zig
fn assertPartitionIndependent(parts: []const []const usize, expected_total: usize) void {
    if (builtin.mode != .Debug) return;
    var bits = std.DynamicBitSet.initEmpty(std.heap.smp_allocator, expected_total) catch
        @panic("OOM in assertPartitionIndependent");
    defer bits.deinit();
    var count: usize = 0;
    for (parts) |p| {
        for (p) |idx| {
            std.debug.assert(idx < expected_total);   // (c)
            std.debug.assert(!bits.isSet(idx));       // (a)
            bits.set(idx);
            count += 1;
        }
    }
    std.debug.assert(count == expected_total);        // (b)
}
```

Call sites pass `history.len` as `expected_total` at `checker.zig:967`
(`checkOperations`) and `:1014` (`checkEvents`).

### Why a bitset beats hashmap+arena

| Aspect             | `AutoHashMap(usize, void)` + arena       | `DynamicBitSet(N)`             |
| ------------------ | ---------------------------------------- | ------------------------------ |
| Allocations        | Page-sized arena blocks + table re-grows | Single allocation              |
| Memory             | ~24 bytes/entry + load-factor slack      | `N/8` bytes                    |
| Work per index     | Hash + probe + maybe grow                | One bit store + one bit load   |
| Bounds check for free? | No                                   | Yes (`idx < N`)                |
| Completeness check | Not possible without extra state         | Falls out as `count == N`      |

Indices are a dense range `[0, N)`, so a hashmap is the wrong data structure —
dense data wants dense storage. The bitset version is strictly cheaper *and*
checks two more invariants.

### Status

Applied. `zig build test` passes in Debug and `-Doptimize=ReleaseFast`.

## Rust: proposed changes

Source file: `../porcupine-rust/src/invariants.rs`.

The Rust side is already stronger than the old Zig code — both
`assert_partition_covers_ops!` and `assert_partition_events_paired!` enforce
all three of (a), (b), (c), and the events macro additionally verifies
call/return pair integrity (same partition for each `(Call, Return)` pair).
The improvements below are about *implementation*, not the invariants being
checked.

### 1. Swap `HashSet`/`HashMap` for a dense bitset/Vec

Exactly the same motivation as the Zig change. Indices are a dense range —
use dense storage.

- `assert_partition_covers_ops!` — replace `HashSet<usize>` with
  `vec![false; history_len]` (or `fixedbitset::FixedBitSet` if we want to add
  the dep; `Vec<bool>` is already in std and is ~8× the memory of a true
  bitset but still O(N) and allocation-light). Coverage becomes a simple
  `seen_count == history_len` check.
- `assert_partition_events_paired!` — replace `HashMap<usize, usize>`
  (event index → partition index) with `Vec<Option<u32>>` of length
  `history_len`. Direct indexed store/load, no hashing, no rehash-on-grow.
- Leave `call_indices` / `return_indices` as `HashMap<u64, usize>`. Those are
  keyed by `ev.id: u64`, which is sparse — a hashmap is correct there.

### 2. Turn the partition macros into functions

None of these three macros take generic types — they operate on
`&[Vec<usize>]` (and for the events one, `&[Event<I, O>]`). Macro form forces
every call site to re-expand ~30 lines of debug-only code, inflating debug
binaries with no corresponding gain.

`if cfg!(debug_assertions) { return; }` at the top of a function compiles out
identically to a `cfg!(debug_assertions)`-gated macro body. Functions also:

- unit-test cleanly,
- don't need to fully-qualify `std::collections::HashMap` for hygiene,
- only compile once instead of once per call site.

`assert_well_formed!` / `assert_well_formed_events!` / `assert_minimal_call!`
have a better argument for staying macros (richer format-string call sites,
`$op.client_id` interpolation). The partition macros don't — their error
messages reference local loop variables that are equally accessible in a
function.

### 3. Factor out the shared scan

The first half of `assert_partition_events_paired!` is a near-verbatim copy of
`assert_partition_covers_ops!` with different panic-message wording. If both
become functions, extract a shared helper:

```rust
fn assert_partition_covers(
    partitions: &[Vec<usize>],
    history_len: usize,
) -> Vec<Option<u32>> {
    // returns idx_to_part for reuse
}
```

`assert_partition_covers_ops` throws away the return. The events version keeps
it and layers the call/return pair check on top.

### 4. Delete `assert_partition_independent!`

It's already `#[allow(unused_macros)]`; its own docstring says it's subsumed by
the two stronger macros. The "kept for spec traceability" rationale is weak —
both stronger macros carry `# INV-LIN-03` in their doc block, so the spec
mapping is preserved by docs, not by keeping a dead macro.

### 5. One-pass the events check

Today `assert_partition_events_paired!` does three passes:

1. build `idx_to_part: HashMap<usize, usize>`,
2. build `call_indices` and `return_indices` by walking the full history,
3. walk call ids, look up both positions in `idx_to_part`.

After change 1, pass 1 produces a `Vec<Option<u32>>` keyed by event index.
Pass 2 can then look each event's partition up directly during a single
history walk, folding (2) and (3) into one loop. Saves one pass and two
HashMap allocations.

### Sketch of the resulting function

```rust
#[inline]
pub(crate) fn assert_partition_events_paired<I, O>(
    partitions: &[Vec<usize>],
    history: &[Event<I, O>],
) {
    if !cfg!(debug_assertions) { return; }

    let n = history.len();
    let idx_to_part = assert_partition_covers(partitions, n);

    // Per-id partition of the Call we saw; on Return, compare.
    let mut call_part: HashMap<u64, u32> = HashMap::new();
    for (pos, ev) in history.iter().enumerate() {
        let part = idx_to_part[pos].expect("covers guarantees Some");
        match ev.kind {
            EventKind::Call => {
                call_part.insert(ev.id, part);
            }
            EventKind::Return => {
                if let Some(&cpart) = call_part.get(&ev.id) {
                    assert!(
                        cpart == part,
                        "INV-LIN-03: event id={} Call in partition {}, Return in partition {}",
                        ev.id, cpart, part
                    );
                }
            }
        }
    }
}
```

### Status

Proposed, not applied. User wants to think through the macro-to-function
migration before landing.

## Open item

The Zig `assertPartitionIndependent` does **not** yet check call/return pair
integrity on the events path (what Rust's `assert_partition_events_paired!`
does). If a model's `partitionEvents` split a `(Call, Return)` pair across
partitions, the per-partition DFS would see a malformed sub-history. Worth
porting that check back across as a follow-up.
