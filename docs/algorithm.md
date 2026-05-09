# The linearizability checker

## What it's checking

Given a concurrent history — a list of operations each tagged with a `call` time and `return_time` (`src/types.zig:24`) — the checker decides whether there exists *some* sequential ordering of those operations that

1. respects real-time order: if A returned before B was called, A must come before B in the order, and
2. is accepted by the user-supplied `Model` (`src/model.zig`) — the sequential specification of the data structure under test (e.g., a register-Model accepts a `Read → v` only when the most recent `Write` wrote `v`).

That's the definition of **linearizability**, and the checker returns `ok` / `illegal` / `unknown` (`CheckResult` in `src/types.zig:11`).

## The core idea

Wing-and-Gong style search: walk a list of pending calls in time order; greedily try to "commit" (linearize) each call against the model; if you get stuck, undo the last commit and try a different one. To "commit" a call here means: pick it as the next operation in the linearization order, advance the model by feeding `step` its input/output pair, and remove both its call and return events from the pending list — equivalent to saying "this call happened next, and the model accepted it." Two ingredients turn this from exponential into tractable:

1. A **memo cache** keyed by *which set of operations is already committed* plus *current model state*. Equivalent search states are pruned.

   A "search state" here is the pair `(linearized_set, model_state)` — *which* operations have been committed plus the model state that committing them produced. The DFS can reach the same pair via different orderings of the same prefix; those are **equivalent** because the future of the search depends only on what's pending and where the model is, not on the order the prefix was chosen in. Concretely, three things determine what the search will do from a given pair:

   - The remaining pending ops — exactly `all_ops \ linearized_set`.
   - The current `model_state`, which is what `step` will be called against next.
   - The real-time constraints — encoded in the live linked list, which depends only on *which* nodes have been lifted, not the order they were lifted in.

   All three are functions of the pair alone. So if path A commits `Op0` then `Op1` and reaches `({0,1}, state=1)`, and path B commits `Op1` then `Op0` and also reaches `({0,1}, state=1)`, the entire subtree below is identical — whatever answer the search would find from B is the same one it already found from A. "Pruned" means: when the cache says we've seen this pair before, we skip exploring the subtree a second time and just advance the cursor. The pruning is combinatorial — with *k* overlapping pending ops, the unmemoized search re-expands up to *k!* orderings of the same prefix; the cache collapses each `(set, state)` equivalence class to a single subtree exploration. The worked example below shows it at Iter 8.

2. A **partition split** so independent parts of the history are checked in isolation, possibly in parallel.

## Stage 1 — flatten into entries

`makeEntries` (`src/checker.zig:86`) turns each `Operation` into two `Entry` records (a `.call` carrying the input, a `.return` carrying the output) and sorts them by time, with calls breaking ties before returns (`sortEntriesByTime`, `src/checker.zig:142`). Result: a sorted `[]Entry` of length `2n`.

## Stage 2 — build a doubly-linked list

`NodeArenaOf(M).fromEntries` (`src/checker.zig:310`) lays out one flat `[]Node` (`src/checker.zig:262`):

- Slot 0 is a sentinel `HEAD`. Real nodes occupy `1..=2n`.
- Each `Node` carries `prev` / `next` as `u32` indices (half the size of pointers — single biggest cache lever, per the comment at line 257).
- Each call node has `match_idx` pointing at its matching return node, set in one pass via a temporary `call_idx[op_id]` lookup array.

Two helpers are the workhorses of search:

- `lift(call_ref)` (`src/checker.zig:375`) splices both the call node *and* its return node out of the live list — committing that operation.
- `unlift(call_ref)` (`src/checker.zig:393`) splices them back in — undoing the commit.

`lift` / `unlift` themselves are narrow — they touch **only the doubly-linked list**. The bullets above conflate `lift` with "committing," which is misleading. **"Committing" is the broader bookkeeping step that wraps the `lift` call**, and it touches every other piece of DFS state. The cache-miss branch in `checkSingle` (`src/checker.zig:644-674`) shows the full set of mutations that happen together when we commit op N at the cursor:

| Data structure | What changes |
|---|---|
| `linearized: Bitset` | clone, then `set(op_id)` — bit N flips on |
| `cache` | append `(new_linearized, cloned_next_state)` under hash `h({linearized ∪ {N}})` |
| `calls` (backtrack stack) | push `{node_ref = cursor, state = old_state}` |
| `state: M.State` | replaced by `next_state` returned by `model.step` |
| linked list | `arena.lift(cursor)` splices out call + return nodes |
| `cursor` | reset to `HEAD.next` so we restart from the time-minimal pending node |

#### Explaining the calls stack

The third row above — push `{node_ref, old_state}` onto `calls` — is the only one that needs explaining. The other rows are forward edits with obvious inverses; this one exists because **`model.step` is a forward transformation with no required inverse**. When we commit op N we do `state := next_state` — the old state is overwritten in place, and once it's gone we have no way to reconstruct it from `next_state` alone. The model isn't required to expose an "undo" or even be deterministic in reverse; for a register Model the old value is genuinely lost the moment a new write lands.

That's the whole reason `calls` exists. It's the DFS recursion stack made explicit, holding exactly the information that can't be recovered any other way. Compare each piece of state we mutated at commit:

| State | How backtrack restores it | Why we *don't* need to stash a copy |
|---|---|---|
| `linearized` bit N | `linearized.clear(call_op_id)` | We know which `op_id` we set, so we can flip it back. The bitset is structurally reversible. |
| Linked-list links | `arena.unlift(frame.node_ref)` | The lifted node's *own* `prev` / `next` were never overwritten — only its neighbors' links were. Reading them back tells us exactly where to splice in. |
| `cursor` | `cursor = arena.nextOf(frame.node_ref)` | Derivable from the un-lifted node. |
| `state: M.State` | **Replaced from `frame.state`** | Opaque value. `step` consumed the old state to produce `next_state`; once we set `state := next_state` the old one only survives if we kept a reference. |

Only the model state has no structural way to be reversed, so it's the only thing that has to be carried across the commit. The `node_ref` in the same frame is bookkeeping for the other rows — it's how `unlift` knows which two nodes to splice back, which `op_id` to clear from the bitset, and where to advance the cursor.

Two related observations:

- **The recursion-stack analogy is exact.** A recursive formulation of this DFS would have `old_state` as a local variable on the C stack, automatically saved across the recursive call and restored on return. The iterative version uses an explicit `ArrayList(CallFrame)` instead, partly because Zig's default stack is small and the DFS depth can reach `n`, and partly because explicit frames make the "abort every 4096 iters" cooperative-cancellation pattern easier.
- **Why save the old state and not the new one.** We're moving forward into `next_state`, so that's the value `state` should hold during further descent. The frame stashes the *pre-commit* state because that's what we want back if this branch fails — we're returning to the choice point at op N, not to op N's child.

There's a quiet correctness invariant here too: `state` always holds the model state corresponding to "everything in `linearized` has been committed in *some* order." Backtrack must preserve that invariant, which means the bit clear and the state restore have to happen as a pair. The `calls` frame is what lets the pair be atomic.

#### The Actual cost of the calls stack

The `calls` stack is pure backtrack insurance. On a path that succeeds end-to-end with no dead ends, every frame pushed is also never popped, and the saved `old_state` is never read — so it's tempting to call those pushes wasted work.

The actual cost in the lucky case is much smaller than that framing suggests, for two reasons:

- **The state is moved, not cloned.** The commit branch does `calls.appendAssumeCapacity(.{ .node_ref = cursor, .state = state })` then `state = ns`. The `old_state` value is just relocated from the local `state` variable into the calls array — same heap-allocated payload (for models where state is heap-allocated), no `cloneState` call. The expensive copy on the commit path is the *cache* entry's `cloneState` (`src/checker.zig:648`), not the `calls` push. So the calls push is a `u32` plus a state-handle move per commit, with no per-push allocation (capacity is reserved upfront via `ensureUnusedCapacity`).
- **You can't speculate your way out of it.** Skipping the push would require knowing *in advance* whether the current commit leads to a valid linearization, which is precisely the question the DFS is answering. Any speculative engine that delayed the save would still have to keep `old_state` reachable somewhere — same cost in a different shape.

The right way to think of it: the cache push is the expensive insurance (full bitset + state clone, one per unique `(set, state)` pair encountered), and the cache is what *prevents* most backtracks by short-circuiting equivalent-state subtrees. The `calls` push is the cheap insurance that handles the backtracks the cache couldn't avoid. They're complementary — the cache reduces how often `calls` is exercised, but doesn't eliminate the need for it, because real model rejections (Iter 3 in the worked example: register holds 1, can't read 0) still produce dead ends that no caching can sidestep.

One concrete consequence: for histories the cache prunes aggressively, the `calls` ArrayList grows to roughly the eventual linearization depth and stays there — capacity reserved once, frames pushed and rarely popped. The per-worker arena (`src/checker.zig:741`) reclaims the whole stack in one `arena.deinit()` at the end of the partition, so even the "wasted" pushes don't pay a per-frame free. That's part of why the design tolerates being insurance-heavy.

So "committing op N" means: the model has accepted N as the next operation in the linearization (`step` returned non-null), we've recorded that fact in the bitset, snapshotted the resulting `(set, state)` pair into the cache, pushed enough info onto `calls` to undo it, advanced the live model state, and finally hidden N's two events from future traversal by lifting them.

Backtracking (the return-node branch, `src/checker.zig:685-696`) inverts each piece: pop `calls`, free the explored `state` and replace it with `frame.state`, `linearized.clear(call_op_id)`, `arena.unlift(frame.node_ref)`, advance `cursor` past the now-restored call node. The cache is *not* rolled back — entries persist across backtracks, which is exactly what makes future symmetric paths cheap.

One subtlety worth naming: the **DFS isn't really "traversing the linked list."** It's searching the tree of possible linearizations. The linked list is just the data structure that represents "which operations are still pending in time order" at the current node of that search tree. Each commit shrinks the live list by two nodes; each backtrack restores them. The list's order never changes — only which nodes are spliced in.

The entire linked-list mutation surface is index manipulation on `prev` / `next`. The nodes live in a flat `[]Node` array (`src/checker.zig:262`) allocated once in Stage 2 and never resized — node 1 is always at `arena.nodes[1]`, node 2 at `arena.nodes[2]`, and so on. What `lift` / `unlift` mutate is purely the `prev: u32` and `next: u32` fields on the **neighbors** of the lifted nodes:

```zig
// lift(call_ref) — the entire mutation set:
self.nodes[call_prev].next = call_next;
self.nodes[call_next].prev = call_prev;   // (guarded if call_next != none_ref)
self.nodes[ret_prev].next  = ret_next;
self.nodes[ret_next].prev  = ret_prev;    // (guarded)
```

Visualised on the worked example's initial layout, with `lift(1)` (commit Op0):

```
Before lift(1):

  HEAD ──► [n1] ──► [n2] ──► [n3] ──► [n4] ──► [n5] ──► [n6] ──► nil
           call     call     call     ret      ret      ret
           Op0      Op1      Op2      Op2      Op0      Op1
            │                                   ▲
            └──────── match_idx = 5 ────────────┘

After lift(1) — splices out n1 (call) AND its match n5 (return) together:

  HEAD ──► [n2] ──► [n3] ──► [n4] ──► [n6] ──► nil

  n1 still has: prev=0 (HEAD), next=2, match_idx=5   ← untouched by lift
  n5 still has: prev=4,        next=6                ← untouched by lift
```

The four mutated fields are all on the **neighbors**: `n0.next`, `n2.prev`, `n4.next`, `n6.prev`. Both lifted nodes keep their own `prev` / `next` / `match_idx` exactly as they were — that's what `unlift` reads back to splice them in.

Four `u32` writes, no allocation, no movement, no copying of node payloads. The lifted nodes themselves keep their own `prev` / `next` fields untouched — that's the trick that makes `unlift` cheap. When backtrack re-inserts them, it reads `self.nodes[call_ref].prev` and `.next` (which still point at the *old* neighbors from before the lift) and uses those to patch the neighbors' links back. Nothing in the lifted node had to be saved separately.

A few consequences worth knowing:

- **No allocation in the hot path.** Lift / unlift never touch the heap; they're four indexed writes that the compiler inlines (`inline fn`).
- **`u32` over pointers.** Index links are half the size of pointers on 64-bit, which is the single biggest cache lever the comment at line 257 calls out — more nodes per cache line during the DFS walk.
- **Order is structural, not stored.** The "time-sorted" invariant of the live list isn't enforced by any field; it's a consequence of how `fromEntries` initially built the links and the fact that lift / unlift only ever splice along existing links. You can't accidentally reorder by lifting and unlifting.
- **Sentinel HEAD at slot 0.** `arena.headNext()` returns `arena.nodes[0].next`, so "restart from the time-minimal pending node" after a commit is also a single index read.

## Stage 3 — DFS with backtracking (`checkSingle`, `src/checker.zig:525`)

Three pieces of state evolve together:

| Structure | Role |
|---|---|
| `state: M.State` | current model state along the partial linearization |
| `linearized: Bitset` (`src/bitset.zig`) | which op-ids are committed; SBO inline up to 256 bits |
| `calls: ArrayList(CallFrame)` (`src/checker.zig:488`) | backtrack stack — each frame holds the `node_ref` we lifted and the model state *before* the lift |
| `cache: HashMapUnmanaged(u64, ArrayList(CacheEntry))` | dedup of `(linearized, state)` pairs (`CacheOf`, `src/checker.zig:435`) |

The loop walks `cursor` along the live list starting at `HEAD.next`. `cursor` is a `u32` index into `NodeArena.nodes` — the doubly-linked list built in Stage 2 — and is advanced by following `node.next` links. "Live" means *not yet lifted*: as operations get committed their two nodes are spliced out, so `cursor` only ever visits pending entries.

**At a call node** (`match_idx != none_ref`, line 608):

1. Ask the model: `step(state, input, output)`. If `null`, the model rejects this commit — advance cursor to the next live node.
2. If accepted, probe the cache *without cloning the bitset yet*: `cacheContainsWithBit` (`src/checker.zig:457`) computes `linearized.hashWithBit(op_id)` and tests equality with `eqlWithBit`
   — both XOR / OR a single word on the fly. This is the **deferred-clone** trick (line 450); cache hits stay in registers.
3. **Cache hit** → the cursor's node is itself still pending (not yet committed on this path), but committing it *would* produce a `(linearized_set, model_state)` pair that some earlier ordering of already-committed ops already reached. The whole subtree below that pair was explored from there and yielded nothing new for this path either, so we drop the freshly-stepped state and advance cursor (line 676). What gets pruned is the equivalence class of search states, not the node.
4. **Cache miss** → clone bitset, set the bit, clone state, append to cache, push the old `state` onto `calls`, replace `state := next_state`, `lift(cursor)`, and **restart from `HEAD.next`** (line 673). The restart is what guarantees we always linearize the time-minimal candidate next.

**At a return node** (`match_idx == none_ref`, line 685):

The return appears in the live list with no committed call preceding it — this branch of the search is dead. If `calls` is empty, return `false` (illegal). Otherwise pop the last frame, restore its state, `clear` the bit, `unlift` the call, and resume from `frame.node_ref.next`. This is the backtrack.

When `cursor == none_ref` (line 589), every operation has been linearized → the partition is `ok`.

The cache is what makes this affordable. The key observation: from a given `(linearized_set, model_state)` pair, the rest of the search depends only on (a) which operations remain pending — exactly `all_ops \ linearized_set` — and (b) the current model state. *How* we arrived at that pair is irrelevant. So if we ever revisit the same pair via a different ordering of the same prefix, exploring its subtree again is guaranteed to yield the same answer.

What the cache prunes on a hit, concretely:

- The recursive descent from that pair downward — every attempt to commit the remaining pending operations in any order, every model `step` call along the way, every nested cache probe, every backtrack underneath.
- The size of the pruned subtree is combinatorial in the remaining ops. With *k* pending operations whose interleavings overlap, the unmemoized search re-expands up to *k!* orderings of them; the cache collapses each `(set, state)` equivalence class to a single visit.
- For the worked example below, the Iter 8 hit prunes the `(Op0, Op1, Op2)` re-exploration that would otherwise re-run Iters 3–4 verbatim under the symmetric `(Op1, Op0, …)` order. Tiny here; the same mechanism is what keeps a 100-op partition with heavy overlap from blowing up.

What the cache does *not* prune:

- The current cursor itself — we still advance past this node and try other pending calls at this level. Only the subtree *below the would-be commit* is skipped.
- Anything above the current frame — committed operations in the current path stay committed; the backtrack stack is untouched.
- Pairs that differ in either coordinate. Two orderings that reach the same set but different states are kept separately, because their futures diverge; same goes for two paths reaching the same state with different sets (different remaining work).

## Stage 4 — partitioning and parallelism

If the model exports `partition` / `partitionEvents`, the history is split first (`checkParallel`, `src/checker.zig:779`):

- **1 partition** → caller's thread runs `checkSingle` directly.
- **< 2000 total entries** (`sequential_threshold`, line 711) → run partitions in-thread, smallest first, so a small partition with the violation kills the rest fast.
- **Otherwise** → up to `cpu_count` worker threads pull partitions off a shared atomic `next_idx`. Sorted largest-first so the longest pole starts immediately.

A shared `kill: Atomic(bool)` lets siblings abort within microseconds when one finds an `illegal`. Each worker polls `kill` (and the optional `Deadline`) every 4096 DFS iterations (line 595). `definitive_illegal` distinguishes "found a real violation" from "stopped because a sibling or deadline aborted us mid-search" — the latter promotes to `unknown` rather than `illegal` (line 767).

Each worker owns its own `ArenaAllocator` (line 741): every bitset clone, cache bucket, and state copy goes through it, and `arena.deinit()` reclaims the lot in one call between partitions.

## Invariants checked in debug builds

The algorithm has a handful of load-bearing invariants. In debug builds they are pinned with `std.debug.assert`; under `ReleaseFast` / `ReleaseSafe` the heavier checks are gated behind `if (builtin.mode == .Debug)` and the lightweight ones erase to nothing once the optimizer sees their conditions.

### The central DFS coupling

```
linearized.popcnt() == calls.items.len
```

Holds at every iteration of the `checkSingle` loop. Each commit sets exactly one bit in `linearized` *and* pushes exactly one frame onto `calls`; each backtrack clears one bit *and* pops one frame. Divergence means a commit or backtrack failed to update one side, and the algorithm has lost track of how the bitset and the backtrack stack relate.

Pinned at three points (`src/checker.zig`):

- top of the `while (cursor != none_ref)` loop — the steady-state check
- final-state check at successful exit: `popcnt() == n_ops` and `calls.items.len == n_ops`
- immediately before the backtrack clear: `linearized.isSet(call_op_id)` — the bit we are about to clear must currently be set, which together with the popcnt equality proves the bit-and-frame coupling is exact

### Bitset deferred-clone preconditions

`hashWithBit(pos)` and `eqlWithBit(pos, other)` synthesise the would-be value of `bitset ∪ {pos}` on the fly (`src/bitset.zig`). Two preconditions make that math correct:

- `pos < chunks * 64` — the bit position is within the bitset's logical range. A `pos` between `n` and `chunks*64` (slack inside the last chunk) would silently flip a phantom bit and corrupt the cache key. Asserted on `set` / `clear` / `hashWithBit` / `eqlWithBit` / `isSet`.
- `bit pos is currently clear` — if the bit were already set, `old_word == new_word` and the hash transform would collapse to a bare popcnt XOR; `eqlWithBit`'s on-the-fly OR would be a no-op. The cache key would no longer agree with what a follow-up `set(pos); hash()` actually produces, so probes would silently miss real hits and store duplicates. Asserted in `hashWithBit`, `eqlWithBit`, and at the entry to `cacheContainsWithBit` (where the DFS calls them).

### NodeArena structural integrity

- `lift` / `unlift` reject the sentinel and out-of-bounds refs: `call_ref != 0`, `call_ref < nodes.len`, `nodes[call_ref].value != null`. The sentinel has `match_idx = none_ref` and is never a valid cursor — asserting this turns a silent corruption into an immediate panic.
- `lift` runs a debug-scoped link-consistency check before any unlinks: `nodes[X.prev].next == X` and `nodes[X.next].prev == X` for both the call node and its matched return node. The intent is to catch double-lift — the second lift would see the prior splice and these checks fail. The actual splice deliberately re-reads the return-side links *after* the call-unlink so the adjacent-pair case (call.next == match_idx) keeps working.
- `fromEntries` (`src/checker.zig:310`) asserts entries are even-length (each operation contributes one call + one return) and time-sorted with calls preceding returns at equal times. The single-pass `match_idx` resolution depends on calls being seen before their matching returns.

### renumberEvents postcondition

Output ids must be dense `[0, next_id)` (`src/checker.zig:184`). `NodeArena` sizes its `call_idx[op_id]` lookup array by op count, so a sparse id would index out of bounds. The check asserts the maximum observed id equals `next_id - 1`.

### What is *not* asserted

- Walking the live list to verify chain integrity end-to-end. Would catch any link corruption but is O(n) per call — excessive even in debug.
- That every `(linearized, state)` pair stored in the cache is actually unique. The construction proves it; re-running the equality logic would just duplicate work.
- Per-partition `Operation.call <= return_time` inside the DFS. Already covered by `assertWellFormed` on the public path.

The asserts have **no measurable bench impact** under `ReleaseFast` (the `100 170` register bench stays at ~33 µs/call, the hashmap bench stays at ~46 µs/call) — they pay their way only when something goes wrong.

## Why this is fast

- Index-based linked list → flat allocation, `u32` links, cache-friendly walks.
- SBO bitset → no heap traffic for ≤256-op partitions.
- Deferred-clone cache probe → cache hits never touch the heap.
- Per-worker arena + `arena_friendly` opt-in (`src/checker.zig:480`) → state cleanup is bulk, not per-entry.
- Identity hash on the bitset's pre-mixed `u64` → no rehashing the key.

---

## A worked example

Use a single-register model: `State = u64`, `Input = .{Write: u64} | .Read`, `Output = .{Ack} | .{Value: u64}`. `step` accepts a write unconditionally and accepts a read iff the output equals the current register value.

### History

Three operations, all overlapping each other:

| Op | Action | call | return |
|----|--------|------|--------|
| 0  | Write(1) | 0  | 20 |
| 1  | Write(1) | 5  | 30 |
| 2  | Read → 0 | 10 | 15 |

All three intervals overlap pairwise, so real-time order constrains nothing — all `3! = 6` orderings are candidates and the DFS has to find a legal one:

```
time:    0    5   10   15   20             30
         |    |    |    |    |              |
Op0:     [==========W1=========]
Op1:          [================W1==================]
Op2:               [===R→0===]
```

Sorted into entries (calls before returns at equal times):

| node idx | t  | kind   | op |
|----------|----|--------|----|
| 1        | 0  | call   | 0  |
| 2        | 5  | call   | 1  |
| 3        | 10 | call   | 2  |
| 4        | 15 | return | 2  |
| 5        | 20 | return | 0  |
| 6        | 30 | return | 1  |

The bitset has 3 bits, one per operation. Notation: `{0,1}` means bits 0 and 1 set; the cache key is the bitset's hash.

Initial: `state = 0`, `linearized = {}`, `calls = []`, `cache = {}`, `cursor = HEAD.next = 1`. Live list: `1 → 2 → 3 → 4 → 5 → 6`.

### The search tree

The DFS is exploring this tree, where each node is a `(linearized_set, model_state)` pair and each edge is "commit op N from this node". Children are visited in cursor order (i.e. time-minimal pending call first):

```
({}, 0)  ← start
│
├── commit Op0 → ({0}, 1)                           [Iter 1]
│   │
│   ├── commit Op1 → ({0,1}, 1)                     [Iter 2]
│   │   └── commit Op2 → REJECT (R→0 vs state=1)    [Iter 3]
│   │       └── backtrack                           [Iter 4]
│   │
│   └── commit Op2 → REJECT (R→0 vs state=1)        [Iter 5]
│       └── backtrack                               [Iter 6]
│
├── commit Op1 → ({1}, 1)                           [Iter 7]
│   │
│   ├── commit Op0 → CACHE HIT on ({0,1}, 1)        [Iter 8] ⚡
│   │   └── (subtree pruned — already explored
│   │        below the ({0}, 1) → Op1 path)
│   │
│   └── commit Op2 → REJECT (R→0 vs state=1)        [Iter 9]
│       └── backtrack                               [Iter 10]
│
└── commit Op2 → ({2}, 0)                           [Iter 11]
    └── commit Op0 → ({0,2}, 1)                     [Iter 12]
        └── commit Op1 → ({0,1,2}, 1) ✓ SUCCESS     [Iter 13]
```

The trace below is a depth-first walk of this tree. The cache hit at Iter 8 is the load-bearing prune: without it, the subtree under `({1}, 1) → Op0` would re-expand the same dead-end work that was just done under `({0}, 1) → Op1`, because both paths reach the same `({0,1}, 1)` pair via different orderings of the same prefix.

### Trace

**Iter 1.** `cursor = 1`, the call node for Op0 (Write(1)) — the time-minimal pending call.

- **`step(0, W1) → 1`**: read this as `step(currentState, input) → newState`. The register currently holds `0`, the input is `Write(1)`. The register-Model accepts writes unconditionally and a write sets the register to the written value, so the new state is `1`. A non-null return means the model accepts this commit. (Reads are the asymmetric case: in Iter 3, `step(1, R, 0) → null` because the register holds `1` but the read claims it returned `0`.)
- **Probe the cache with `hashWithBit(0)` on `{}`**: before paying for clones, ask "would committing Op0 land us in a `(linearized, state)` pair we've already explored?" `hashWithBit(0)` synthesises the hash of `{} ∪ {0} = {0}` on the fly without allocating — the **deferred-clone** trick. The cache is empty, so this is a **miss**.
- **Clone bitset `{}` → `{0}`**: now that we're committing, we need a stable bitset value to use as the cache key and as the live `linearized` going forward.
- **Clone state `1`**: the cache stores `(set, state)` pairs and the model state is opaque, so we copy it.
- **Append `({0}, 1)` to cache** under hash `h({0})`. Future paths that reach this same pair will hit and skip the subtree below.
- **Push frame `{node=1, state=0}` onto `calls`**: backtrack insurance. `state` is about to be overwritten by `1`; the only way to recover the pre-commit `0` is to stash it. `node=1` lets `unlift` know which two nodes to splice back if this branch fails.
- **`state := 1`**: advance the live model state to what `step` produced.
- **`lift(1, 5)`**: splice node 1 (the call) and node 5 (its matching return) out of the live list. This is what "Op0 has been committed" looks like structurally — its events are no longer visible to the cursor walk.
- **`cursor := HEAD.next = 2`**: restart from the time-minimal pending node, because the algorithm always tries to linearize the earliest still-pending call next.

Cache: `{ h({0}) → [({0}, 1)] }`. Live list: `2 → 3 → 4 → 6`.

**Iter 2.** `cursor = 2`, the call node for Op1 (Write(1)).

- **`step(1, W1) → 1`**: register holds `1` from Iter 1; the new write sets it to `1` again. Writes are accepted unconditionally, so the model returns `1` (still non-null = accept).
- **Probe `hashWithBit(1)` on `{0}`**: would-be hash of `{0,1}`. Not in cache. **Miss.**
- **Clone `{0}` → `{0,1}`, clone state `1`, append `({0,1}, 1)` to cache** under `h({0,1})`. This entry is the one that fires the cache hit at Iter 8.
- **Push frame `{node=2, state=1}`**: stash the pre-commit state. (Pre- and post-commit state both happen to be `1` here — the frame just records what `state` was when we entered the iter.)
- **`state := 1`, `lift(2, 6)`**.
- **`cursor := HEAD.next = 3`**.

Cache: `{ h({0}) → [({0}, 1)], h({0,1}) → [({0,1}, 1)] }`. Live list: `3 → 4`.

**Iter 3.** `cursor = 3`, the call node for Op2 (Read claiming output `0`).

- **`step(1, R, 0) → null`**: this is the asymmetric branch. The model checks the read's claimed output against the current register: register holds `1`, output claims `0`, mismatch. The model **rejects** (`null`).
- **No cache probe, no commit**: the model already said no — there's nothing to memoize.
- **`cursor := next(3) = 4`**: advance cursor.

**Iter 4.** `cursor = 4`, a return node (`match_idx = none_ref`).

A return node appears in the live list with no committed call preceding it — Op2's call was never lifted, so this branch is **dead** (you can't "return" without "calling" first in any valid linearization).

- **`calls` non-empty (2 frames)** → backtrack rather than declare illegal.
- **Pop frame `{node=2, state=1}`** — the most recent commit (Iter 2's Op1).
- **Restore `state := 1`** from the popped frame. (Current `state` is also `1`, so the value doesn't change here — but in general this is how the pre-commit state is recovered.)
- **`linearized.clear(1) → {0}`**: clear bit 1 because Op1 is no longer committed.
- **`unlift(2)`**: splice nodes 2 and 6 back into the live list.
- **`cursor := next(2) = 3`**: resume from the node right after the un-lifted call. The cache is **not** rolled back — its entries stay valid forever, which is the entire point of the memoization.

Live list: `2 → 3 → 4 → 6`.

**Iter 5.** `cursor = 3` (Op2 Read again).

- **`step(1, R, 0) → null`** — register still holds `1` from the Iter 1 Op0 commit, so the read still rejects.
- **`cursor := next(3) = 4`**.

Same dead-end as Iter 3, by symmetry.

**Iter 6.** `cursor = 4` (return Op2). Dead-end again. Backtrack.

- **Pop frame `{node=1, state=0}`** — Iter 1's Op0 commit.
- **Restore `state := 0`**: this is the load-bearing restore — `state` was `1`, now it goes back to `0`. The frame is what made this recoverable.
- **`linearized.clear(0) → {}`**.
- **`unlift(1)`**: splice nodes 1 and 5 back.
- **`cursor := next(1) = 2`**.

Live list: `1 → 2 → 3 → 4 → 5 → 6` (back to its initial shape). We've exhausted the "commit Op0 first" branch and are about to try "commit Op1 first".

**Iter 7.** `cursor = 2` (Op1, Write(1)) — top of the search, different starting choice.

- **`step(0, W1) → 1`**: register at `0`, write `1`, accept.
- **Probe `hashWithBit(1)` on `{}`**: would-be `h({1})`. The cache has entries for `{0}` and `{0,1}` from earlier, but not `{1}`. **Miss.**
- **Clone `{} → {1}`, clone state `1`, append `({1}, 1)` to cache.**
- **Push frame `{node=2, state=0}`**.
- **`state := 1`, `lift(2, 6)`**.
- **`cursor := HEAD.next = 1`**.

Cache: `{ h({0}) → [({0}, 1)], h({0,1}) → [({0,1}, 1)], h({1}) → [({1}, 1)] }`. Live list: `1 → 3 → 4 → 5`. The cache hit is now set up: we're about to consider Op0, which would land us at `({0,1}, 1)` — the exact pair Iter 2 already explored.

**Iter 8 — the cache hit.** `cursor = 1` (Op0, Write(1)).

- **`step(1, W1) → 1`**: register holds `1`, write `1`, accept.
- **Probe `cacheContainsWithBit(linearized={1}, op_id=0, ns=1)`**:
  - `hashWithBit(0)` on `{1}` synthesises `h({1} ∪ {0}) = h({0,1})`.
  - The cache **has** a bucket for `h({0,1})` — populated by Iter 2.
  - `eqlWithBit(0)` confirms the candidate set is `{0,1}` (matches the bucket key) and `statesEqual(1, 1)` is true.
  - **Hit.**
- **What the hit means**: the entire subtree below `(linearized={0,1}, state=1)` was already explored — in Iters 3–4 via the `(Op0 then Op1)` order — and led to nothing (Op2's read can't satisfy a register holding `1`). Re-running the same exploration via the symmetric `(Op1 then Op0)` order is guaranteed to produce the same result, so we skip it.
- **Free the freshly-stepped state**: `step` produced a `next_state` we won't be using. Free it. The deferred-clone trick means we never paid for a bitset clone or a state clone in the first place — the hit stayed in registers.
- **`cursor := next(1) = 3`**: advance past Op0 without committing it. The cursor moves on to see if any *other* still-pending call can fit at this level.

State unchanged: `linearized = {1}`, `state = 1`, calls has 1 frame.

**Iter 9.** `cursor = 3` (Op2 Read).

- **`step(1, R, 0) → null`** — register holds `1`, read claims `0`, reject.
- **`cursor := next(3) = 4`**.

**Iter 10.** `cursor = 4` (return Op2). Dead-end. Backtrack.

- **Pop frame `{node=2, state=0}`** (Iter 7's Op1 commit).
- **Restore `state := 0`**, **`linearized.clear(1) → {}`**, **`unlift(2)`**.
- **`cursor := next(2) = 3`**.

Live list: `1 → 2 → 3 → 4 → 5 → 6`. We're back at the top of the search with `linearized = {}` and `state = 0`. The only remaining first-choice is Op2.

**Iter 11.** `cursor = 3` (Op2 Read claiming `0`).

- **`step(0, R, 0) → 0`**: register holds `0`, read claims `0`, **match**. The model accepts and returns the unchanged state `0` (reads don't mutate).
- **Probe `hashWithBit(2)` on `{}`**: would-be `h({2})`. **Miss.**
- **Clone `{} → {2}`, clone state `0`, append `({2}, 0)` to cache.**
- **Push frame `{node=3, state=0}`. `state := 0`. `lift(3, 4)`** — the call node and its matching return lift out together (note: Op2's return is at node 4, immediately adjacent to its call).
- **`cursor := HEAD.next = 1`**.

Live list: `1 → 2 → 5 → 6`. Op2 is committed first; the writes haven't run yet so the register is still `0` — consistent with the read seeing `0`.

**Iter 12.** `cursor = 1` (Op0 Write(1)).

- **`step(0, W1) → 1`**: accept.
- **Probe `hashWithBit(0)` on `{2}` → `h({0,2})`: miss.**
- **Clone `{2} → {0,2}`, clone state `1`, store `({0,2}, 1)`. Push frame `{node=1, state=0}`. `state := 1`. `lift(1, 5)`**.
- **`cursor := HEAD.next = 2`**.

Live list: `2 → 6`.

**Iter 13.** `cursor = 2` (Op1 Write(1)).

- **`step(1, W1) → 1`**: accept.
- **Probe `hashWithBit(1)` on `{0,2}` → `h({0,1,2})`: miss.** Store the entry (it'll never be read again — this is the last commit — but the algorithm doesn't know that until the cursor goes to `none_ref`).
- **Clone, push frame `{node=2, state=1}`, `state := 1`, `lift(2, 6)`**.
- **Live list is now empty. `cursor := HEAD.next = none_ref`. Loop exits.**
- **`linearized.popcnt() == 3 == n_ops`** and **`calls.items.len == 3`** — the final-state debug invariant holds. **Return `true`** — a valid linearization exists.

The discovered linearization is `Op2, Op0, Op1` (read 0, then both writes) — the order in which calls were lifted.

### What the cache bought us

The 13 iters touched only **6 unique `(linearized, state)` pairs** — every cell the search reached gets stored exactly once:

|           | state=0   | state=1                       |
|-----------|-----------|-------------------------------|
| `{}`      | start     |                               |
| `{0}`     |           | stored Iter 1                 |
| `{1}`     |           | stored Iter 7                 |
| `{2}`     | Iter 11   |                               |
| `{0,1}`   |           | Iter 2 — **hit at Iter 8** ⚡ |
| `{0,2}`   |           | Iter 12                       |
| `{0,1,2}` |           | Iter 13 ✓                     |

The Iter 8 cache hit is the `({0,1}, 1)` cell being touched a second time — the only reason the table stays at 6 entries instead of needing a duplicate slot for the `(Op1, Op0)`-prefix re-arrival.

Without the memo at Iter 8 the search would have re-expanded the `(linearized={0,1}, state=1)` subtree along the `(Op1, Op0)` branch — the same dead-end work it already did along `(Op0, Op1)` in Iters 3–4. With two writes that's small change. With ten concurrent identical writes the unmemoized search expands `10!` orderings of the prefix; the cache collapses all of them into a single visit per `(set, state)` pair.

Two implementation details show up here:

- **Deferred clone.** The Iter 8 hit never allocated a new bitset.  `hashWithBit(0)` and `eqlWithBit(0)` synthesise the would-be value of `{1} | {0}` on the fly using a single OR per probed word. Only a *miss* pays for `Bitset.clone` plus `model.cloneState` (Iter 7, before the store).
- **Identity hash.** `U64IdentityCtx` (`src/checker.zig:419`) tells the hash map to treat the bitset's pre-mixed `u64` as the bucket key directly. The map never re-hashes; the bitset's avalanche is the only mixing step.
