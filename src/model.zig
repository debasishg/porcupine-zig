//! Sequential-specification "models" against which concurrent histories are
//! checked.
//!
//! Zig has no trait system, so a "Model" is any struct that comptime satisfies
//! the shape documented below — duck-typed at compile time. The checker is a
//! comptime-generic function that specialises to each concrete model, yielding
//! the same zero-overhead dispatch as Rust's monomorphised trait impls.
//!
//! # Required shape
//!
//! Every model type `M` used with `checker.checkOperations` / `checkEvents`
//! must declare:
//!
//!   pub const State  = ...;
//!   pub const Input  = ...;
//!   pub const Output = ...;
//!
//!   /// Initial state.
//!   pub fn init(self: *const M, allocator: std.mem.Allocator) !State;
//!
//!   /// Attempt to apply `input` / `output`. Return null if the transition
//!   /// is invalid; otherwise return the next state.
//!   ///
//!   /// The checker will *own* and eventually free/clone the returned state.
//!   /// `state.clone` (below) is how the checker makes copies; `state.deinit`
//!   /// is how it releases them.
//!   pub fn step(
//!       self: *const M,
//!       allocator: std.mem.Allocator,
//!       state: *const State,
//!       input: *const Input,
//!       output: *const Output,
//!   ) !?State;
//!
//!   /// Clone a state. Always allowed to fail with Allocator.Error.
//!   pub fn cloneState(self: *const M, allocator: std.mem.Allocator, state: *const State) !State;
//!
//!   /// Release any owned memory in a state. Called for every state the
//!   /// checker pushes onto its backtrack stack or cache.
//!   pub fn deinitState(self: *const M, allocator: std.mem.Allocator, state: *State) void;
//!
//!   /// Value equality over states. Used to deduplicate DFS cache entries
//!   /// and (when the PowerSetModel wrapper is used) to dedupe branches.
//!   pub fn statesEqual(self: *const M, a: *const State, b: *const State) bool;
//!
//! The following are *optional*; omit them for the default behaviour:
//!
//!   /// Split the history into independent sub-histories. Returning null
//!   /// (the default) disables partitioning. Indices are into the original
//!   /// slice; ownership of the returned slices is transferred to the caller.
//!   pub fn partition(
//!       self: *const M,
//!       allocator: std.mem.Allocator,
//!       history: []const Operation(Input, Output),
//!   ) !?[][]usize;
//!
//!   pub fn partitionEvents(
//!       self: *const M,
//!       allocator: std.mem.Allocator,
//!       history: []const Event(Input, Output),
//!   ) !?[][]usize;
//!
//! The `checker` module exposes `hasDecl(M, "partition")` helpers that test
//! for these optional hooks; models without them are treated as a single
//! partition.
//!
//! # Optional opt-in: `arena_friendly`
//!
//!   pub const arena_friendly: bool = true;
//!
//! Asserts that `deinitState` is purely memory-cleanup with no other
//! resources to release (no file handles, sockets, locks, etc.). When set,
//! the checker skips per-entry `deinitState` walks at partition shutdown,
//! relying on the per-worker `ArenaAllocator` to reclaim everything in one
//! call. This is a measurable win when the DFS cache grows large.
//!
//! Default (marker absent or false): the checker conservatively walks every
//! cached / stacked state and calls `deinitState` on it, in case the model
//! holds resources beyond memory.

const std = @import("std");
const types = @import("types.zig");
const Operation = types.Operation;
const Event = types.Event;

/// Compile-time assertion: reject model types that omit required declarations
/// with a clear error at the call site rather than a confusing "no member"
/// error deep inside the checker.
pub fn assertModel(comptime M: type) void {
    comptime {
        if (!@hasDecl(M, "State")) @compileError(@typeName(M) ++ " missing pub const State");
        if (!@hasDecl(M, "Input")) @compileError(@typeName(M) ++ " missing pub const Input");
        if (!@hasDecl(M, "Output")) @compileError(@typeName(M) ++ " missing pub const Output");
        if (!@hasDecl(M, "init")) @compileError(@typeName(M) ++ " missing pub fn init");
        if (!@hasDecl(M, "step")) @compileError(@typeName(M) ++ " missing pub fn step");
        if (!@hasDecl(M, "cloneState")) @compileError(@typeName(M) ++ " missing pub fn cloneState");
        if (!@hasDecl(M, "deinitState")) @compileError(@typeName(M) ++ " missing pub fn deinitState");
        if (!@hasDecl(M, "statesEqual")) @compileError(@typeName(M) ++ " missing pub fn statesEqual");
    }
}

// ---------------------------------------------------------------------------
// PowerSetModel — adapter for nondeterministic sequential specifications.
//
// A NondeterministicModel's `step` returns *all* valid successor states for a
// given (state, input, output); the empty set means the transition is
// rejected. `PowerSetModel(ND)` turns that into a regular Model whose state
// is the **set** of concrete states the system could currently be in.
//
// This mirrors Rust's `PowerSetModel<M>` and the Go `PowerSetModel` adapter.
// ---------------------------------------------------------------------------

/// Required shape for the `ND` type parameter of `PowerSetModel`:
///
///   pub const State  = ...;   // concrete per-branch state
///   pub const Input  = ...;
///   pub const Output = ...;
///
///   /// All possible initial states.
///   pub fn initStates(self: *const ND, allocator: std.mem.Allocator) ![]State;
///
///   /// All valid successor states. Empty means "invalid transition".
///   /// The returned slice must be allocated with `allocator`.
///   pub fn step(
///       self: *const ND,
///       allocator: std.mem.Allocator,
///       state: *const State,
///       input: *const Input,
///       output: *const Output,
///   ) ![]State;
///
///   pub fn cloneState(self: *const ND, allocator: std.mem.Allocator, state: *const State) !State;
///   pub fn deinitState(self: *const ND, allocator: std.mem.Allocator, state: *State) void;
///   pub fn statesEqual(self: *const ND, a: *const State, b: *const State) bool;
///
///   // Optional — same shape as Model.partition*.
///   pub fn partition(...) !?[][]usize;
///   pub fn partitionEvents(...) !?[][]usize;
pub fn PowerSetModel(comptime ND: type) type {
    return struct {
        inner: ND,

        const Self = @This();

        pub const Input = ND.Input;
        pub const Output = ND.Output;

        /// PowerSetModel's deinitState only frees memory (per-branch states
        /// via `inner.deinitState`, then the slice itself). An arena-backed
        /// allocator reclaims all of it in bulk, so the per-entry walk in
        /// the checker is redundant for this model. The flag is forwarded
        /// only when the inner model also opts in — otherwise the inner
        /// `deinitState` may close real resources.
        pub const arena_friendly: bool =
            @hasDecl(ND, "arena_friendly") and ND.arena_friendly;

        /// Power-state: the set of concrete states reachable so far.
        /// Stored as a simple slice — owned by the allocator passed to
        /// `init` / `step` / `cloneState`. Duplicates are removed by
        /// `statesEqual` before insertion.
        pub const State = []ND.State;

        pub fn init(self: *const Self, allocator: std.mem.Allocator) !State {
            const raw = try self.inner.initStates(allocator);
            defer allocator.free(raw);
            return try dedupe(ND, &self.inner, allocator, raw);
        }

        pub fn step(
            self: *const Self,
            allocator: std.mem.Allocator,
            state: *const State,
            input: *const Input,
            output: *const Output,
        ) !?State {
            // Accumulate successors from every current branch.
            var acc: std.ArrayList(ND.State) = .empty;
            defer {
                // On the normal path `acc` is empty (drained into dedupe result).
                // Only the error path leaves items behind — free them.
                for (acc.items) |*s| self.inner.deinitState(allocator, s);
                acc.deinit(allocator);
            }
            for (state.*) |*s| {
                const successors = try self.inner.step(allocator, s, input, output);
                defer allocator.free(successors);
                try acc.appendSlice(allocator, successors);
            }
            const deduped = try dedupe(ND, &self.inner, allocator, acc.items);
            // Transfer ownership: once dedupe has consumed `acc.items` (cloning
            // the kept elements), drop the accumulator without freeing them.
            for (acc.items) |*s| self.inner.deinitState(allocator, s);
            acc.clearRetainingCapacity();
            if (deduped.len == 0) {
                allocator.free(deduped);
                return null;
            }
            return deduped;
        }

        pub fn cloneState(
            self: *const Self,
            allocator: std.mem.Allocator,
            state: *const State,
        ) !State {
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
            return out;
        }

        pub fn deinitState(
            self: *const Self,
            allocator: std.mem.Allocator,
            state: *State,
        ) void {
            for (state.*) |*s| self.inner.deinitState(allocator, s);
            allocator.free(state.*);
        }

        pub fn statesEqual(self: *const Self, a: *const State, b: *const State) bool {
            if (a.len != b.len) return false;
            // Set equality: both sides have been deduped, so we can check
            // "every element of a is in b" and rely on matching lengths.
            for (a.*) |*x| {
                var found = false;
                for (b.*) |*y| {
                    if (self.inner.statesEqual(x, y)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }

        // Partition hooks — always defined on PowerSetModel; delegate to the
        // inner model only when it declares the matching hook, otherwise fall
        // through to "no partitioning" (return null). `usingnamespace` is gone
        // in Zig 0.16, so this comptime fall-through is the idiomatic pattern.

        pub fn partition(
            self: *const Self,
            allocator: std.mem.Allocator,
            history: []const Operation(Input, Output),
        ) !?[][]usize {
            if (comptime !@hasDecl(ND, "partition")) return null;
            return self.inner.partition(allocator, history);
        }

        pub fn partitionEvents(
            self: *const Self,
            allocator: std.mem.Allocator,
            history: []const Event(Input, Output),
        ) !?[][]usize {
            if (comptime !@hasDecl(ND, "partitionEvents")) return null;
            return self.inner.partitionEvents(allocator, history);
        }
    };
}

/// Remove duplicates from `states`, preserving first-occurrence order.
///
/// Returns a newly-allocated slice whose elements are *clones* of the
/// corresponding originals in `states` — the caller still owns `states` and
/// must deinit its contents. This split makes error paths simpler: on OOM
/// mid-way through, the caller's `states` is still intact and can be freed
/// uniformly.
fn dedupe(
    comptime ND: type,
    inner: *const ND,
    allocator: std.mem.Allocator,
    states: []const ND.State,
) ![]ND.State {
    var out: std.ArrayList(ND.State) = .empty;
    errdefer {
        for (out.items) |*s| inner.deinitState(allocator, s);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, states.len);
    outer: for (states) |*s| {
        for (out.items) |*kept| {
            if (inner.statesEqual(s, kept)) continue :outer;
        }
        const cloned = try inner.cloneState(allocator, s);
        out.appendAssumeCapacity(cloned);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Trivial ND model over u32 state, used to exercise dedupe / PowerSetModel
// without dragging in integration-test fixtures.
const NdU32 = struct {
    pub const State = u32;
    pub const Input = void;
    pub const Output = u32;
    pub fn cloneState(_: *const NdU32, _: std.mem.Allocator, s: *const State) !State {
        return s.*;
    }
    pub fn deinitState(_: *const NdU32, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const NdU32, a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
};

test "dedupe: empty input returns empty slice" {
    const alloc = std.testing.allocator;
    const m = NdU32{};
    const out = try dedupe(NdU32, &m, alloc, &.{});
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "dedupe: removes duplicates and preserves first-occurrence order" {
    const alloc = std.testing.allocator;
    const m = NdU32{};
    const input = [_]u32{ 3, 1, 3, 2, 1, 2 };
    const out = try dedupe(NdU32, &m, alloc, &input);
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, out);
}

test "dedupe: returns a clone independent of the input slice" {
    const alloc = std.testing.allocator;
    const m = NdU32{};
    var input = [_]u32{ 7, 8, 9 };
    const out = try dedupe(NdU32, &m, alloc, &input);
    defer alloc.free(out);
    // Mutating input must not affect the deduped output.
    input[0] = 99;
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, out);
}

test "PowerSetModel.statesEqual treats power-states as sets (order-insensitive)" {
    const PS = PowerSetModel(NdU32);
    const ps = PS{ .inner = .{} };
    var a_buf = [_]u32{ 1, 2, 3 };
    var b_buf = [_]u32{ 3, 1, 2 };
    var c_buf = [_]u32{ 1, 2, 4 };
    const a: PS.State = &a_buf;
    const b: PS.State = &b_buf;
    const c: PS.State = &c_buf;
    try std.testing.expect(ps.statesEqual(&a, &b));
    try std.testing.expect(!ps.statesEqual(&a, &c));
}

test "PowerSetModel.cloneState / deinitState round-trip" {
    const alloc = std.testing.allocator;
    const PS = PowerSetModel(NdU32);
    const ps = PS{ .inner = .{} };
    var src_buf = [_]u32{ 10, 20, 30 };
    const original: PS.State = &src_buf;
    var cloned = try ps.cloneState(alloc, &original);
    defer ps.deinitState(alloc, &cloned);
    try std.testing.expectEqualSlices(u32, original, cloned);
    try std.testing.expect(cloned.ptr != original.ptr);
}
