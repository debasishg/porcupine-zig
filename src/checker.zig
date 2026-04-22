//! Core linearizability checking logic.
//!
//! Algorithm (mirrors porcupine/checker.go and porcupine-rust/src/checker.rs):
//!
//!  1. Assert INV-HIST-01 (well-formed) on entry.
//!  2. Optionally split into independent partitions (INV-LIN-03).
//!  3. For each partition, flatten operations into a sorted array of `Entry`s
//!     (one Call + one Return per operation, sorted by time; calls precede
//!     returns at equal timestamps).
//!  4. Build an index-based doubly-linked list (`NodeArena`) from the entries.
//!  5. Run DFS with backtracking (`checkSingle`):
//!     - Walk the live list; call nodes have a `match_idx` pointing at their
//!       matching return node.
//!     - For each call node: attempt `model.step`; on success push the old
//!       state onto the `calls` backtrack stack, cache `(bitset, state)`, and
//!       "lift" the call/return pair out of the live list.
//!     - For each return node with no linearized call preceding it, backtrack
//!       by popping the calls stack.
//!     - Cache prunes duplicate `(bitset, state)` branches (INV-LIN-04).
//!  6. Return Ok / Illegal (or Unknown if the kill flag fired).
//!
//! Parallel partitions are dispatched across up to CPU-count worker threads.
//! Workers pull from a shared atomic index, so having more partitions than
//! cores doesn't oversubscribe. No separate timer thread — each worker folds
//! a deadline check into its periodic kill-flag poll.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const bitset_mod = @import("bitset.zig");
const model_mod = @import("model.zig");

/// Monotonic nanoseconds. Chosen over `std.time.Instant` because 0.16 moved
/// that API under `std.Io.Clock`, which requires a live Io instance — heavy
/// machinery for what amounts to a deadline comparison. Raw `clock_gettime`
/// costs ~20 ns on Apple Silicon and is called at most once per 4096 DFS
/// iterations, so the overhead is invisible.
pub inline fn nowNs() u64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
            return @intCast(@as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec));
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            return @intCast(@as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec));
        },
    }
}

const Bitset = bitset_mod.Bitset;
const CheckResult = types.CheckResult;
const Operation = types.Operation;
const Event = types.Event;
const EventKind = types.EventKind;

// ---------------------------------------------------------------------------
// Internal entry representation
// ---------------------------------------------------------------------------

/// Variant payload: a call carries the `Input`, a return carries the `Output`.
/// Mirrors `EntryValue<I, O>` in porcupine-rust/src/checker.rs.
fn EntryValueOf(comptime I: type, comptime O: type) type {
    return union(enum) {
        call: I,
        @"return": O,
    };
}

fn EntryOf(comptime I: type, comptime O: type) type {
    return struct {
        id: u32, // operation id (0-indexed); call and return share the same id
        time: u64, // u64 to avoid silent overflow when timestamps are near u64::MAX
        value: EntryValueOf(I, O),
    };
}

/// Flatten a slice of `Operation`s into a sorted array of `Entry` pairs.
/// Calls precede returns at equal timestamps (mirrors Go `byTime` sort).
///
/// Entries alias the caller's input/output values (shallow copy by `I`/`O`);
/// the caller must keep `ops` live for the checker's lifetime. The DFS never
/// mutates them.
fn makeEntries(
    comptime M: type,
    allocator: std.mem.Allocator,
    ops: []const Operation(M.Input, M.Output),
) std.mem.Allocator.Error![]EntryOf(M.Input, M.Output) {
    // Node arena indices are u32, so at most (maxInt(u32) - 1) / 2 operations.
    std.debug.assert(ops.len <= (std.math.maxInt(u32) - 1) / 2);
    const Entry = EntryOf(M.Input, M.Output);
    const entries = try allocator.alloc(Entry, ops.len * 2);
    for (ops, 0..) |op, i| {
        entries[2 * i] = .{
            .id = @intCast(i),
            .time = op.call,
            .value = .{ .call = op.input },
        };
        entries[2 * i + 1] = .{
            .id = @intCast(i),
            .time = op.return_time,
            .value = .{ .@"return" = op.output },
        };
    }
    sortEntriesByTime(M, entries);
    return entries;
}

/// Build entries for a partition directly from the full history and an
/// index list, assigning dense 0-based ids within the partition. Avoids
/// cloning a sub-history into an intermediate `[]Operation`.
fn makeEntriesFromIndices(
    comptime M: type,
    allocator: std.mem.Allocator,
    history: []const Operation(M.Input, M.Output),
    indices: []const usize,
) std.mem.Allocator.Error![]EntryOf(M.Input, M.Output) {
    std.debug.assert(indices.len <= (std.math.maxInt(u32) - 1) / 2);
    const Entry = EntryOf(M.Input, M.Output);
    const entries = try allocator.alloc(Entry, indices.len * 2);
    for (indices, 0..) |global_idx, local_id| {
        const op = history[global_idx];
        entries[2 * local_id] = .{
            .id = @intCast(local_id),
            .time = op.call,
            .value = .{ .call = op.input },
        };
        entries[2 * local_id + 1] = .{
            .id = @intCast(local_id),
            .time = op.return_time,
            .value = .{ .@"return" = op.output },
        };
    }
    sortEntriesByTime(M, entries);
    return entries;
}

/// Sort entries by `(time, call-before-return)`. Stability is not required —
/// the comparator resolves ties explicitly.
fn sortEntriesByTime(comptime M: type, entries: []EntryOf(M.Input, M.Output)) void {
    const Entry = EntryOf(M.Input, M.Output);
    const Cmp = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.time != b.time) return a.time < b.time;
            // calls (.call) < returns (.@"return") at equal times
            return a.value == .call and b.value == .@"return";
        }
    };
    std.sort.pdq(Entry, entries, {}, Cmp.lessThan);
}

/// Renumber event ids to be contiguous starting at 0.
/// Caller owns the returned slice.
fn renumberEvents(
    comptime M: type,
    allocator: std.mem.Allocator,
    events: []const Event(M.Input, M.Output),
) ![]Event(M.Input, M.Output) {
    const Ev = Event(M.Input, M.Output);
    const out = try allocator.alloc(Ev, events.len);
    errdefer allocator.free(out);

    var map: std.AutoHashMap(u64, u64) = .init(allocator);
    defer map.deinit();
    var next_id: u64 = 0;
    for (events, 0..) |ev, i| {
        const gop = try map.getOrPut(ev.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = next_id;
            next_id += 1;
        }
        out[i] = ev;
        out[i].id = gop.value_ptr.*;
    }
    return out;
}

/// Convert a renumbered slice of events into `Entry`s (index used as `time`).
fn convertEntries(
    comptime M: type,
    allocator: std.mem.Allocator,
    events: []const Event(M.Input, M.Output),
) ![]EntryOf(M.Input, M.Output) {
    const Entry = EntryOf(M.Input, M.Output);
    const entries = try allocator.alloc(Entry, events.len);
    for (events, 0..) |ev, i| {
        entries[i] = switch (ev.kind) {
            .call => .{
                .id = @intCast(ev.id),
                .time = @intCast(i),
                .value = .{ .call = ev.input.? },
            },
            .@"return" => .{
                .id = @intCast(ev.id),
                .time = @intCast(i),
                .value = .{ .@"return" = ev.output.? },
            },
        };
    }
    return entries;
}

/// Build entries for a partition directly from the full event history and
/// an index list, renumbering ids and converting in a single pass. Avoids
/// the `[]Event` + `[]Event` intermediates the naive chain needs.
fn convertEntriesFromIndices(
    comptime M: type,
    allocator: std.mem.Allocator,
    history: []const Event(M.Input, M.Output),
    indices: []const usize,
) ![]EntryOf(M.Input, M.Output) {
    const Entry = EntryOf(M.Input, M.Output);
    const entries = try allocator.alloc(Entry, indices.len);
    errdefer allocator.free(entries);

    var id_map: std.AutoHashMap(u64, u64) = .init(allocator);
    defer id_map.deinit();
    var next_id: u64 = 0;

    for (indices, 0..) |global_idx, local_time| {
        const ev = history[global_idx];
        const gop = try id_map.getOrPut(ev.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = next_id;
            next_id += 1;
        }
        const new_id: u32 = @intCast(gop.value_ptr.*);
        entries[local_time] = switch (ev.kind) {
            .call => .{
                .id = new_id,
                .time = @intCast(local_time),
                .value = .{ .call = ev.input.? },
            },
            .@"return" => .{
                .id = new_id,
                .time = @intCast(local_time),
                .value = .{ .@"return" = ev.output.? },
            },
        };
    }
    return entries;
}

// ---------------------------------------------------------------------------
// Index-based doubly-linked list (NodeArena)
//
// Sentinel HEAD is always at index 0. All real nodes occupy 1..=2n.
// Using `u32` indices halves the per-node pointer size versus `usize` on
// 64-bit and is the single biggest cache-efficiency lever.
// ---------------------------------------------------------------------------

const none_ref: u32 = std.math.maxInt(u32);

fn NodeOf(comptime I: type, comptime O: type) type {
    return struct {
        /// `null` only for the sentinel at index 0; all real nodes carry a
        /// payload. Mirrors `Option<EntryValue<I, O>>` in the Rust port.
        value: ?EntryValueOf(I, O),
        id: u32,
        match_idx: u32, // none_ref if not a call node
        prev: u32,
        next: u32, // none_ref if at end
    };
}

fn NodeArenaOf(comptime M: type) type {
    const Entry = EntryOf(M.Input, M.Output);
    const Node = NodeOf(M.Input, M.Output);
    return struct {
        nodes: []Node,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Build the arena from a sorted entry slice.
        ///
        /// Operation ids are dense (0..n_ops), so the call→return mapping
        /// lives in a plain `[]u32` indexed by id rather than a hashmap.
        /// For a 170-op history that's one 680-byte allocation instead of
        /// a hashmap rebuild with per-entry hashing.
        fn fromEntries(
            allocator: std.mem.Allocator,
            entries: []const Entry,
        ) !Self {
            const n = entries.len;
            const n_ops = n / 2;
            const nodes = try allocator.alloc(Node, n + 1);
            errdefer allocator.free(nodes);

            // Sentinel — value is null, never dereferenced by DFS.
            nodes[0] = .{
                .value = null,
                .id = 0,
                .match_idx = none_ref,
                .prev = 0,
                .next = if (n > 0) 1 else none_ref,
            };

            // `return_idx[op_id]` = node index of that op's return entry.
            const return_idx = try allocator.alloc(u32, n_ops);
            defer allocator.free(return_idx);
            @memset(return_idx, none_ref);

            // Allocate a slot for each entry and record return-node positions.
            for (entries, 0..) |entry, i| {
                const idx: u32 = @intCast(i + 1);
                if (entry.value == .@"return") return_idx[entry.id] = idx;
                nodes[idx] = .{
                    .value = entry.value,
                    .id = entry.id,
                    .match_idx = none_ref, // filled below
                    .prev = @intCast(i), // previous index = i (since we're at i+1)
                    .next = if (i + 1 < n) @intCast(i + 2) else none_ref,
                };
            }

            // Fill match_idx for call nodes in a second pass.
            for (nodes[1..]) |*node| {
                if (node.value.? == .call) {
                    node.match_idx = return_idx[node.id];
                }
            }

            return .{ .nodes = nodes, .allocator = allocator };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
            self.nodes = &.{};
        }

        /// Index of the first live node after sentinel HEAD.
        inline fn headNext(self: *const Self) u32 {
            return self.nodes[0].next;
        }

        inline fn nextOf(self: *const Self, r: u32) u32 {
            return self.nodes[r].next;
        }

        inline fn matchOf(self: *const Self, r: u32) u32 {
            return self.nodes[r].match_idx;
        }

        /// Remove `call_ref` and its matched return node from the live list.
        inline fn lift(self: *Self, call_ref: u32) void {
            const match_idx = self.nodes[call_ref].match_idx;
            std.debug.assert(match_idx != none_ref);

            // Unlink call node.
            const call_prev = self.nodes[call_ref].prev;
            const call_next = self.nodes[call_ref].next;
            self.nodes[call_prev].next = call_next;
            if (call_next != none_ref) self.nodes[call_next].prev = call_prev;

            // Unlink return node.
            const ret_prev = self.nodes[match_idx].prev;
            const ret_next = self.nodes[match_idx].next;
            self.nodes[ret_prev].next = ret_next;
            if (ret_next != none_ref) self.nodes[ret_next].prev = ret_prev;
        }

        /// Re-insert `call_ref` and its matched return node into the live list.
        inline fn unlift(self: *Self, call_ref: u32) void {
            const match_idx = self.nodes[call_ref].match_idx;
            std.debug.assert(match_idx != none_ref);

            // Re-link return node.
            const ret_prev = self.nodes[match_idx].prev;
            const ret_next = self.nodes[match_idx].next;
            self.nodes[ret_prev].next = match_idx;
            if (ret_next != none_ref) self.nodes[ret_next].prev = match_idx;

            // Re-link call node.
            const call_prev = self.nodes[call_ref].prev;
            const call_next = self.nodes[call_ref].next;
            self.nodes[call_prev].next = call_ref;
            if (call_next != none_ref) self.nodes[call_next].prev = call_ref;
        }
    };
}

// ---------------------------------------------------------------------------
// DFS cache
// ---------------------------------------------------------------------------

/// Identity hash context — the key is already a u64 hash computed by the
/// bitset, so we must NOT hash it again. Rust used `FxHashMap`; we use a
/// noop context which is strictly better for this key distribution.
const U64IdentityCtx = struct {
    pub fn hash(_: U64IdentityCtx, key: u64) u64 {
        return key;
    }
    pub fn eql(_: U64IdentityCtx, a: u64, b: u64) bool {
        return a == b;
    }
};

fn CacheEntryOf(comptime State: type) type {
    return struct {
        linearized: Bitset,
        state: State,
    };
}

fn CacheOf(comptime State: type) type {
    // Collision chain lives in an ArrayList. In the common path (one or two
    // entries per bucket) this stays tiny; we start with capacity=0 and let
    // it grow lazily, matching the Rust `SmallVec<[_; 2]>` economy.
    return std.HashMapUnmanaged(
        u64,
        std.ArrayList(CacheEntryOf(State)),
        U64IdentityCtx,
        std.hash_map.default_max_load_percentage,
    );
}

/// Probe the DFS cache as if `bit_pos` were already set in `bitset`,
/// without cloning or mutating the bitset.
///
/// Rationale (deferred-clone optimisation):
///   - `hash` is computed via `bitset.hashWithBit`, a handful of XOR / OR ops.
///   - Equality is checked via `bitset.eqlWithBit`, which OR-adjusts the
///     relevant word on the fly during the comparison loop.
/// The result: cache hits (often >80% of probes mid-search) cost only
/// register arithmetic. The `Bitset.clone` is deferred to the cache-miss
/// branch in `checkSingle`, where it is actually needed.
inline fn cacheContainsWithBit(
    comptime M: type,
    cache: *const CacheOf(M.State),
    model: *const M,
    h: u64,
    bs: *const Bitset,
    bit_pos: usize,
    state: *const M.State,
) bool {
    const entries = cache.getPtr(h) orelse return false;
    for (entries.items) |*e| {
        if (bs.eqlWithBit(bit_pos, &e.linearized) and
            model.statesEqual(&e.state, state))
        {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// DFS call-stack frame
// ---------------------------------------------------------------------------

fn CallFrameOf(comptime State: type) type {
    return struct {
        node_ref: u32, // the call node that was linearized
        state: State, // model state *before* this linearization step
    };
}

// ---------------------------------------------------------------------------
// checkSingle — the core DFS
// ---------------------------------------------------------------------------

/// Deadline in `std.time.Instant` absolute time, or `null` for no timeout.
/// Passed by pointer to avoid having a second atomic: the deadline is read-only
/// for workers, and the result of comparing against it is "has the deadline
/// passed yet?" — which workers fold into the shared `kill` atomic.
pub const Deadline = struct {
    /// Absolute monotonic deadline (nanoseconds since an unspecified epoch).
    deadline_ns: u64,

    /// Return true if `now >= deadline`.
    inline fn hasFired(self: Deadline, now: u64) bool {
        return now >= self.deadline_ns;
    }
};

/// DFS over one partition. Returns:
///   - true  if the partition is linearizable,
///   - false if it is not (or if `kill` is set externally).
///
/// `arena_alloc` should be a fast allocator (typically an ArenaAllocator); it
/// is responsible for every intermediate bitset clone and cache entry. The
/// caller is expected to reset / deinit the arena once the partition is done.
///
/// `deadline`, if non-null, lets the worker bail out early when wall-clock
/// time exceeds the budget. No separate timer thread is used — checking a
/// monotonic clock is roughly the cost of a single cache-line read and is
/// amortised over a 4096-iteration poll interval.
fn checkSingle(
    comptime M: type,
    arena_alloc: std.mem.Allocator,
    model: *const M,
    entries: []const EntryOf(M.Input, M.Output),
    kill: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    deadline: ?Deadline,
) !bool {
    if (entries.len == 0) return true;

    const State = M.State;
    const NodeArena = NodeArenaOf(M);
    const Cache = CacheOf(State);
    const CallFrame = CallFrameOf(State);

    const n_ops = entries.len / 2;
    var arena = try NodeArena.fromEntries(arena_alloc, entries);
    defer arena.deinit();

    var linearized = try Bitset.init(arena_alloc, n_ops);
    defer linearized.deinit(arena_alloc);

    var cache: Cache = .empty;
    defer {
        var it = cache.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |*e| {
                var bs_mut = e.linearized;
                bs_mut.deinit(arena_alloc);
                model.deinitState(arena_alloc, &e.state);
            }
            kv.value_ptr.deinit(arena_alloc);
        }
        cache.deinit(arena_alloc);
    }

    var calls: std.ArrayList(CallFrame) = .empty;
    defer {
        for (calls.items) |*frame| model.deinitState(arena_alloc, &frame.state);
        calls.deinit(arena_alloc);
    }

    var state = try model.init(arena_alloc);
    // `state` is replaced in place as we descend; on every path (success,
    // failure, or error) we free the *final* live state. Replaced states are
    // either moved onto the backtrack stack (freed with the stack) or
    // dropped in place (this frees them).
    defer model.deinitState(arena_alloc, &state);

    var cursor: u32 = arena.headNext();
    const kill_poll_mask: usize = 4095;
    var iter_count: usize = 0;

    while (cursor != none_ref) {
        // Poll the kill flag (and, if any, the deadline) every 4096 iterations.
        // Frequent enough that parallel siblings abort within microseconds of
        // a peer finding an illegal history, rare enough that the poll never
        // shows up in hot-path profiles.
        iter_count +%= 1;
        if ((iter_count & kill_poll_mask) == 0) {
            if (kill.load(.monotonic)) return false;
            if (deadline) |d| {
                const now_ns: u64 = nowNs();
                if (d.hasFired(now_ns)) {
                    timed_out.store(true, .monotonic);
                    kill.store(true, .monotonic);
                    return false;
                }
            }
        }

        const match_raw = arena.matchOf(cursor);
        if (match_raw != none_ref) {
            // Call node — candidate for linearization.
            //
            // INV-HIST-03: the live list is always time-sorted, and we
            // restart from headNext() after each lift, so the first call
            // node we visit is always the minimal one.
            const call_node = &arena.nodes[cursor];
            const ret_node = &arena.nodes[match_raw];
            const op_id: usize = @intCast(call_node.id);
            const input = &call_node.value.?.call;
            const output = &ret_node.value.?.@"return";

            const next_state_opt = try model.step(arena_alloc, &state, input, output);
            if (next_state_opt) |ns_local| {
                var ns = ns_local;
                // Deferred-clone cache probe — no bitset clone unless we're
                // about to actually store a new entry.
                const h = linearized.hashWithBit(op_id);
                if (!cacheContainsWithBit(M, &cache, model, h, &linearized, op_id, &ns)) {
                    // New `(bitset, state)` pair — commit.
                    //
                    // Order of operations matters for correctness under OOM:
                    //   1. clone bitset (may fail) → if it fails, free `ns`.
                    //   2. clone state   (may fail) → if it fails, free the
                    //      cloned bitset and `ns`.
                    //   3. ensure bucket capacity (may fail) → if it fails,
                    //      free both clones and `ns`.
                    //   4. push into cache — infallible from here on.
                    //   5. push calls frame and swap state — also infallible.
                    var new_linearized = linearized.clone(arena_alloc) catch |e| {
                        model.deinitState(arena_alloc, &ns);
                        return e;
                    };
                    errdefer new_linearized.deinit(arena_alloc);
                    new_linearized.set(op_id);

                    var cache_state = model.cloneState(arena_alloc, &ns) catch |e| {
                        model.deinitState(arena_alloc, &ns);
                        return e;
                    };
                    errdefer model.deinitState(arena_alloc, &cache_state);

                    const gop = cache.getOrPut(arena_alloc, h) catch |e| {
                        model.deinitState(arena_alloc, &ns);
                        return e;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                        // Most buckets hold 1–2 entries — matches Rust's
                        // `SmallVec<[_;2]>`. Skips the default ArrayList
                        // first-growth jump of 0 → 8.
                        gop.value_ptr.ensureTotalCapacity(arena_alloc, 2) catch |e| {
                            model.deinitState(arena_alloc, &ns);
                            return e;
                        };
                    }
                    gop.value_ptr.append(arena_alloc, .{
                        .linearized = new_linearized,
                        .state = cache_state,
                    }) catch |e| {
                        model.deinitState(arena_alloc, &ns);
                        return e;
                    };

                    try calls.append(arena_alloc, .{
                        .node_ref = cursor,
                        .state = state, // move old state onto backtrack stack
                    });
                    // `state` has been moved — replace it with `ns`.
                    state = ns;
                    linearized.set(op_id);
                    arena.lift(cursor);
                    cursor = arena.headNext();
                } else {
                    // Already explored this (bitset, state) — skip.
                    model.deinitState(arena_alloc, &ns);
                    cursor = arena.nextOf(cursor);
                }
            } else {
                // Model rejected — try next candidate.
                cursor = arena.nextOf(cursor);
            }
        } else {
            // Return node with no linearized call preceding it — stuck.
            if (calls.items.len == 0) return false;
            const frame = calls.pop().?;
            const call_op_id: usize = @intCast(arena.nodes[frame.node_ref].id);
            // Restore model state; free the one we were exploring.
            model.deinitState(arena_alloc, &state);
            state = frame.state;
            linearized.clear(call_op_id);
            arena.unlift(frame.node_ref);
            cursor = arena.nextOf(frame.node_ref);
        }
    }

    // Every operation has been linearized.
    return true;
}

// ---------------------------------------------------------------------------
// Parallel partition driver
// ---------------------------------------------------------------------------

/// Threshold: below this total entry count, run partitions sequentially.
/// Rayon-style thread dispatch costs a few microseconds per task; for small
/// histories (KV c10: ~700 entries across 10 partitions) the dispatch
/// overhead dominates the work itself.
const sequential_threshold: usize = 2000;

/// Shared per-run state; each worker thread pulls partitions off a common
/// atomic index. Bounds live-thread count to CPU count regardless of how
/// many partitions the model produced.
fn WorkerCtx(comptime M: type) type {
    return struct {
        model: *const M,
        partitions: [][]const EntryOf(M.Input, M.Output),
        next_idx: *std.atomic.Value(usize),
        kill: *std.atomic.Value(bool),
        timed_out: *std.atomic.Value(bool),
        definitive_illegal: *std.atomic.Value(bool),
        deadline: ?Deadline,
        result_ok: std.atomic.Value(bool),

        const Self = @This();

        fn run(self: *Self) void {
            // Each worker gets its own arena so DFS allocations never touch
            // a shared allocator's lock. The arena is released when the
            // thread function exits.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            while (true) {
                if (self.kill.load(.monotonic)) return;
                const idx = self.next_idx.fetchAdd(1, .monotonic);
                if (idx >= self.partitions.len) return;
                _ = arena.reset(.retain_capacity);

                const ok = checkSingle(
                    M,
                    alloc,
                    self.model,
                    self.partitions[idx],
                    self.kill,
                    self.timed_out,
                    self.deadline,
                ) catch false;
                if (!ok) {
                    // Only claim a definitive finding if the kill flag was
                    // not already set (which would mean a sibling or the
                    // deadline aborted us mid-search). Benign race: the
                    // flag may flip between the DFS returning and this load,
                    // which at worst reports Unknown instead of Illegal —
                    // the safe direction.
                    if (!self.kill.load(.monotonic) and !self.timed_out.load(.monotonic)) {
                        self.definitive_illegal.store(true, .monotonic);
                    }
                    self.result_ok.store(false, .monotonic);
                    self.kill.store(true, .monotonic);
                    return;
                }
            }
        }
    };
}

fn checkParallel(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    partitions: [][]const EntryOf(M.Input, M.Output),
    kill: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    definitive_illegal: *std.atomic.Value(bool),
    deadline: ?Deadline,
) !bool {
    if (partitions.len == 0) return true;

    // ------- Single-partition fast path ------------------------------------
    // Skips all thread-dispatch overhead; the caller's thread does the work.
    // Models without partitioning (e.g. a plain register) always land here.
    if (partitions.len == 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const ok = try checkSingle(M, arena.allocator(), model, partitions[0], kill, timed_out, deadline);
        if (!ok) {
            if (!kill.load(.monotonic) and !timed_out.load(.monotonic))
                definitive_illegal.store(true, .monotonic);
            kill.store(true, .monotonic);
        }
        return ok;
    }

    // ------- Sequential fast path for small workloads ---------------------
    // Thread spawn on macOS costs ~5–20 µs; when the partitions are tiny
    // (KV c10 ≈ 700 total entries), the spawn overhead dominates.
    var total_entries: usize = 0;
    for (partitions) |p| total_entries += p.len;
    if (total_entries < sequential_threshold) {
        // Run smallest partitions first: if a small one contains the
        // violation, it finishes fast and the kill broadcast skips the
        // others.
        std.mem.sort([]const EntryOf(M.Input, M.Output), partitions, {}, struct {
            fn lessThan(_: void, a: []const EntryOf(M.Input, M.Output), b: []const EntryOf(M.Input, M.Output)) bool {
                return a.len < b.len;
            }
        }.lessThan);
        for (partitions) |partition| {
            if (kill.load(.monotonic)) return false;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const ok = try checkSingle(M, arena.allocator(), model, partition, kill, timed_out, deadline);
            if (!ok) {
                if (!kill.load(.monotonic) and !timed_out.load(.monotonic))
                    definitive_illegal.store(true, .monotonic);
                kill.store(true, .monotonic);
                return false;
            }
        }
        return true;
    }

    // ------- Multi-threaded path ------------------------------------------
    // Sort largest-first so the "longest-pole" partition starts immediately
    // and its worker thread can run the whole time. Remaining partitions
    // trickle in via an atomic work counter, so later workers don't block
    // on dispatched-but-idle threads.
    std.mem.sort([]const EntryOf(M.Input, M.Output), partitions, {}, struct {
        fn lessThan(_: void, a: []const EntryOf(M.Input, M.Output), b: []const EntryOf(M.Input, M.Output)) bool {
            return a.len > b.len;
        }
    }.lessThan);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const n_workers = @min(cpu_count, partitions.len);

    const Ctx = WorkerCtx(M);
    const ctxs = try allocator.alloc(Ctx, n_workers);
    defer allocator.free(ctxs);

    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    var next_idx: std.atomic.Value(usize) = .init(0);

    for (ctxs, threads) |*ctx, *th| {
        ctx.* = .{
            .model = model,
            .partitions = partitions,
            .next_idx = &next_idx,
            .kill = kill,
            .timed_out = timed_out,
            .definitive_illegal = definitive_illegal,
            .deadline = deadline,
            .result_ok = .init(true),
        };
        th.* = try std.Thread.spawn(.{}, Ctx.run, .{ctx});
    }
    for (threads) |th| th.join();

    for (ctxs) |*ctx| {
        if (!ctx.result_ok.load(.monotonic)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Deadline helper
// ---------------------------------------------------------------------------
//
// We deliberately avoid a separate timer thread:
//   - Zig 0.16 moved `std.Thread.Mutex` / `Condition` to `std.Io`, which
//     requires passing an Io instance through every call site — heavy
//     machinery for a one-shot cancellation.
//   - `std.Thread.sleep`-based timers would either block shutdown on the
//     full duration or need cooperative polling anyway.
// Instead, each worker folds a "has the deadline passed?" check into the
// periodic kill-flag poll that already happens every 4096 DFS iterations.
// A single `nanoTimestamp` call is ~20ns on Apple Silicon — dwarfed by the
// 4096 iterations of real work around it.

inline fn makeDeadline(timeout_ns: ?u64) ?Deadline {
    if (timeout_ns) |d| {
        const now_ns: u64 = nowNs();
        return .{ .deadline_ns = now_ns +| d };
    }
    return null;
}

/// Priority (matches Go's `checkParallel`):
///   1. definitive_illegal → Illegal
///   2. timed_out          → Unknown
///   3. ok                 → Ok
///   4. otherwise          → Illegal
fn toCheckResult(
    ok: bool,
    timed_out: bool,
    definitive_illegal: bool,
) CheckResult {
    if (!ok and definitive_illegal) return .illegal;
    if (timed_out) return .unknown;
    if (ok) return .ok;
    return .illegal;
}

// ---------------------------------------------------------------------------
// Invariant assertions (debug builds only)
// ---------------------------------------------------------------------------

fn assertWellFormed(comptime M: type, history: []const Operation(M.Input, M.Output)) void {
    if (builtin.mode != .Debug) return;
    for (history) |op| {
        std.debug.assert(op.call <= op.return_time);
    }
}

fn assertWellFormedEvents(comptime M: type, events: []const Event(M.Input, M.Output)) void {
    if (builtin.mode != .Debug) return;
    // Debug-only: if the assert helper itself OOMs on a pathological input,
    // skip the checks silently rather than crashing a release build's debug
    // sibling. Under `std.testing.allocator` this never happens.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var call_pos: std.AutoHashMap(u64, usize) = .init(alloc);
    var return_pos: std.AutoHashMap(u64, usize) = .init(alloc);
    for (events, 0..) |ev, i| {
        switch (ev.kind) {
            .call => {
                std.debug.assert(ev.input != null);
                const gop = call_pos.getOrPut(ev.id) catch return;
                std.debug.assert(!gop.found_existing);
                gop.value_ptr.* = i;
            },
            .@"return" => {
                std.debug.assert(ev.output != null);
                const gop = return_pos.getOrPut(ev.id) catch return;
                std.debug.assert(!gop.found_existing);
                gop.value_ptr.* = i;
            },
        }
    }
    var it = call_pos.iterator();
    while (it.next()) |kv| {
        const r = return_pos.get(kv.key_ptr.*) orelse unreachable;
        std.debug.assert(kv.value_ptr.* < r);
    }
}

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

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Check an operation-based history for linearizability.
///
/// `timeout_ns` bounds the search: if the DFS has not finished within that
/// many nanoseconds the function returns `.unknown`. Pass `null` for an
/// unbounded check (equivalent to `timeout = 0` in the Go original).
///
/// The `allocator` is used for temporary bookkeeping (partition slices,
/// entry arrays) but hot-path DFS state is routed through per-worker arena
/// allocators internally, so this allocator's performance is not critical.
pub fn checkOperations(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    history: []const Operation(M.Input, M.Output),
    timeout_ns: ?u64,
) !CheckResult {
    model_mod.assertModel(M);
    assertWellFormed(M, history);

    const Entry = EntryOf(M.Input, M.Output);

    // Build partition entry arrays.
    var partitions: std.ArrayList([]const Entry) = .empty;
    defer {
        for (partitions.items) |p| allocator.free(p);
        partitions.deinit(allocator);
    }

    if (comptime @hasDecl(M, "partition")) {
        if (try model.partition(allocator, history)) |parts| {
            defer {
                for (parts) |p| allocator.free(p);
                allocator.free(parts);
            }
            assertPartitionIndependent(@ptrCast(parts));
            try partitions.ensureTotalCapacity(allocator, parts.len);
            for (parts) |indices| {
                const entries = try makeEntriesFromIndices(M, allocator, history, indices);
                partitions.appendAssumeCapacity(entries);
            }
        } else {
            const entries = try makeEntries(M, allocator, history);
            try partitions.append(allocator, entries);
        }
    } else {
        const entries = try makeEntries(M, allocator, history);
        try partitions.append(allocator, entries);
    }

    return runCheck(M, allocator, model, partitions.items, timeout_ns);
}

/// Check an event-based history for linearizability.
///
/// Same semantics as `checkOperations`. Each event's `id` links a call to
/// its matching return; ids are renumbered to be contiguous internally so
/// large sparse ids cost nothing.
pub fn checkEvents(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    history: []const Event(M.Input, M.Output),
    timeout_ns: ?u64,
) !CheckResult {
    model_mod.assertModel(M);
    assertWellFormedEvents(M, history);

    const Entry = EntryOf(M.Input, M.Output);

    var partitions: std.ArrayList([]const Entry) = .empty;
    defer {
        for (partitions.items) |p| allocator.free(p);
        partitions.deinit(allocator);
    }

    if (comptime @hasDecl(M, "partitionEvents")) {
        if (try model.partitionEvents(allocator, history)) |parts| {
            defer {
                for (parts) |p| allocator.free(p);
                allocator.free(parts);
            }
            assertPartitionIndependent(@ptrCast(parts));
            try partitions.ensureTotalCapacity(allocator, parts.len);
            for (parts) |indices| {
                const entries = try convertEntriesFromIndices(M, allocator, history, indices);
                partitions.appendAssumeCapacity(entries);
            }
        } else {
            const ren = try renumberEvents(M, allocator, history);
            defer allocator.free(ren);
            const entries = try convertEntries(M, allocator, ren);
            try partitions.append(allocator, entries);
        }
    } else {
        const ren = try renumberEvents(M, allocator, history);
        defer allocator.free(ren);
        const entries = try convertEntries(M, allocator, ren);
        try partitions.append(allocator, entries);
    }

    return runCheck(M, allocator, model, partitions.items, timeout_ns);
}

fn runCheck(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    partitions: [][]const EntryOf(M.Input, M.Output),
    timeout_ns: ?u64,
) !CheckResult {
    var kill: std.atomic.Value(bool) = .init(false);
    var timed_out: std.atomic.Value(bool) = .init(false);
    var definitive_illegal: std.atomic.Value(bool) = .init(false);
    const deadline = makeDeadline(timeout_ns);

    const ok = try checkParallel(
        M,
        allocator,
        model,
        partitions,
        &kill,
        &timed_out,
        &definitive_illegal,
        deadline,
    );
    return toCheckResult(ok, timed_out.load(.monotonic), definitive_illegal.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Unit tests — makeEntries
// ---------------------------------------------------------------------------

const TestModel = struct {
    pub const State = void;
    pub const Input = u32;
    pub const Output = u32;
};

fn tOp(id: u64, input: u32, output: u32, call: u64, ret: u64) Operation(u32, u32) {
    return .{
        .client_id = id,
        .input = input,
        .output = output,
        .call = call,
        .return_time = ret,
    };
}

test "makeEntries empty produces no entries" {
    const allocator = std.testing.allocator;
    const ops: []const Operation(u32, u32) = &.{};
    const entries = try makeEntries(TestModel, allocator, ops);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "makeEntries single op produces two entries" {
    const allocator = std.testing.allocator;
    const ops = [_]Operation(u32, u32){tOp(0, 1, 0, 5, 15)};
    const entries = try makeEntries(TestModel, allocator, &ops);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].value == .call);
    try std.testing.expect(entries[1].value == .@"return");
    try std.testing.expectEqual(@as(u64, 5), entries[0].time);
    try std.testing.expectEqual(@as(u64, 15), entries[1].time);
    try std.testing.expectEqual(@as(u32, 0), entries[0].id);
    try std.testing.expectEqual(@as(u32, 0), entries[1].id);
}

test "makeEntries call before return at equal timestamps" {
    const allocator = std.testing.allocator;
    // Instantaneous op (call == return_time): Call must sort before Return.
    const ops = [_]Operation(u32, u32){tOp(0, 1, 0, 10, 10)};
    const entries = try makeEntries(TestModel, allocator, &ops);
    defer allocator.free(entries);
    try std.testing.expect(entries[0].value == .call);
    try std.testing.expect(entries[1].value == .@"return");
}

test "makeEntries time sorted across two ops" {
    const allocator = std.testing.allocator;
    // op A: call=5, ret=15   op B: call=0, ret=10
    // Expected order: CallB(0), CallA(5), RetB(10), RetA(15)
    const ops = [_]Operation(u32, u32){
        tOp(0, 1, 0, 5, 15),
        tOp(1, 2, 0, 0, 10),
    };
    const entries = try makeEntries(TestModel, allocator, &ops);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(@as(u64, 0), entries[0].time);
    try std.testing.expectEqual(@as(u64, 5), entries[1].time);
    try std.testing.expectEqual(@as(u64, 10), entries[2].time);
    try std.testing.expectEqual(@as(u64, 15), entries[3].time);
    try std.testing.expect(entries[0].value == .call);
    try std.testing.expect(entries[1].value == .call);
    try std.testing.expect(entries[2].value == .@"return");
    try std.testing.expect(entries[3].value == .@"return");
}

test "makeEntries large timestamps do not overflow" {
    const allocator = std.testing.allocator;
    // Pre-fix Rust bug: timestamps near u64 max were cast to i64 and wrapped.
    // Zig port uses u64 end-to-end, so this must sort correctly.
    const t: u64 = std.math.maxInt(u64) - 10;
    const ops = [_]Operation(u32, u32){
        tOp(0, 1, 0, t, t + 5),
        tOp(1, 2, 0, t + 1, t + 6),
    };
    const entries = try makeEntries(TestModel, allocator, &ops);
    defer allocator.free(entries);
    // Expected: CallA(t), CallB(t+1), RetA(t+5), RetB(t+6)
    try std.testing.expectEqual(@as(u32, 0), entries[0].id);
    try std.testing.expectEqual(@as(u32, 1), entries[1].id);
    try std.testing.expect(entries[0].time < entries[1].time);
    try std.testing.expect(entries[1].time < entries[2].time);
    try std.testing.expect(entries[2].time < entries[3].time);
}

test "makeEntriesFromIndices picks subset and renumbers ids" {
    const allocator = std.testing.allocator;
    const history = [_]Operation(u32, u32){
        tOp(0, 10, 0, 0, 5), // global 0
        tOp(1, 20, 0, 1, 6), // global 1
        tOp(2, 30, 0, 2, 7), // global 2
    };
    const indices = [_]usize{ 0, 2 };
    const entries = try makeEntriesFromIndices(TestModel, allocator, &history, &indices);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    // Local ids should be 0 and 1 (not the global 0 and 2).
    // Expected sorted order: Call(g0,t=0), Call(g2,t=2), Ret(g0,t=5), Ret(g2,t=7)
    try std.testing.expectEqual(@as(u32, 0), entries[0].id);
    try std.testing.expectEqual(@as(u32, 1), entries[1].id);
    try std.testing.expectEqual(@as(u32, 0), entries[2].id);
    try std.testing.expectEqual(@as(u32, 1), entries[3].id);
    try std.testing.expectEqual(@as(u64, 0), entries[0].time);
    try std.testing.expectEqual(@as(u64, 2), entries[1].time);
    try std.testing.expectEqual(@as(u64, 5), entries[2].time);
    try std.testing.expectEqual(@as(u64, 7), entries[3].time);
    // Inputs/outputs came from the selected ops.
    try std.testing.expectEqual(@as(u32, 10), entries[0].value.call);
    try std.testing.expectEqual(@as(u32, 30), entries[1].value.call);
}
