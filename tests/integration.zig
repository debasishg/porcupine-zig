//! Integration tests for porcupine-zig. Mirrors the high-level tests in
//! porcupine-rust (`src/checker.rs` test module + `tests/property_tests.rs`).
//!
//! Three models exercised here:
//!   1. **Reg** — minimal read/write register (positive + negative + partition).
//!   2. **KVModel** — partitioned key-value store (exercises `partition`).
//!   3. **CoinFlip** — nondeterministic model (exercises `PowerSetModel`).

const std = @import("std");
const porcupine = @import("porcupine");
const CheckResult = porcupine.CheckResult;
const Operation = porcupine.Operation;
const Event = porcupine.Event;
const EventKind = porcupine.EventKind;

// ---------------------------------------------------------------------------
// Reg: single-value register model
// ---------------------------------------------------------------------------

const RegInput = struct {
    is_write: bool,
    value: i32,
};

const Reg = struct {
    pub const State = i32;
    pub const Input = RegInput;
    pub const Output = i32;

    pub fn init(_: *const Reg, _: std.mem.Allocator) !State {
        return 0;
    }
    pub fn step(
        _: *const Reg,
        _: std.mem.Allocator,
        state: *const State,
        input: *const Input,
        output: *const Output,
    ) !?State {
        if (input.is_write) return input.value;
        if (output.* == state.*) return state.*;
        return null;
    }
    pub fn cloneState(_: *const Reg, _: std.mem.Allocator, state: *const State) !State {
        return state.*;
    }
    pub fn deinitState(_: *const Reg, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const Reg, a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
};

fn w(client_id: u64, value: i32, call: u64, ret: u64) Operation(RegInput, i32) {
    return .{
        .client_id = client_id,
        .input = .{ .is_write = true, .value = value },
        .call = call,
        .output = 0,
        .return_time = ret,
    };
}

fn r(client_id: u64, observed: i32, call: u64, ret: u64) Operation(RegInput, i32) {
    return .{
        .client_id = client_id,
        .input = .{ .is_write = false, .value = 0 },
        .call = call,
        .output = observed,
        .return_time = ret,
    };
}

test "reg: empty history is ok" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history: []const Operation(RegInput, i32) = &.{};
    const res = try porcupine.checkOperations(Reg, alloc, &m, history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "reg: sequential write-read is ok" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history = [_]Operation(RegInput, i32){
        w(1, 42, 0, 10),
        r(2, 42, 20, 30),
    };
    const res = try porcupine.checkOperations(Reg, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "reg: read stale value after sequential write is illegal" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history = [_]Operation(RegInput, i32){
        w(1, 42, 0, 10),
        r(2, 0, 20, 30), // reads 0 after write of 42 completed
    };
    const res = try porcupine.checkOperations(Reg, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

test "reg: concurrent write ambiguous read is ok" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    // Two concurrent writes; a later read sees either value.
    const history = [_]Operation(RegInput, i32){
        w(1, 7, 0, 100),
        w(2, 9, 0, 100),
        r(3, 9, 101, 200),
    };
    const res = try porcupine.checkOperations(Reg, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "reg: timeout returns unknown for an infinite-looking path" {
    // Use an absurdly small timeout on a non-trivial history. Since DFS is
    // fast, we may still finish — but we at least verify the timeout code
    // path is wired up correctly by passing 1 ns and accepting either
    // Unknown or Ok (whichever finishes first).
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history = [_]Operation(RegInput, i32){
        w(1, 1, 0, 10),
        r(2, 1, 20, 30),
    };
    const res = try porcupine.checkOperations(Reg, alloc, &m, &history, 1);
    try std.testing.expect(res == .ok or res == .unknown);
}

// ---------------------------------------------------------------------------
// KV model: partitioned key-value store (per-key linearizability)
// ---------------------------------------------------------------------------

const KVInput = struct {
    is_write: bool,
    key: u32,
    value: i32,
};

const KVModel = struct {
    pub const State = i32;
    pub const Input = KVInput;
    pub const Output = i32;

    pub fn init(_: *const KVModel, _: std.mem.Allocator) !State {
        return 0;
    }
    pub fn step(
        _: *const KVModel,
        _: std.mem.Allocator,
        state: *const State,
        input: *const Input,
        output: *const Output,
    ) !?State {
        if (input.is_write) return input.value;
        if (output.* == state.*) return state.*;
        return null;
    }
    pub fn cloneState(_: *const KVModel, _: std.mem.Allocator, s: *const State) !State {
        return s.*;
    }
    pub fn deinitState(_: *const KVModel, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const KVModel, a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
    /// Partition by key. Returns null when history is empty.
    pub fn partition(
        _: *const KVModel,
        allocator: std.mem.Allocator,
        history: []const Operation(Input, Output),
    ) !?[][]usize {
        if (history.len == 0) return null;
        var groups: std.AutoHashMap(u32, std.ArrayList(usize)) = .init(allocator);
        defer {
            var it = groups.valueIterator();
            while (it.next()) |v| v.deinit(allocator);
            groups.deinit();
        }
        for (history, 0..) |op, i| {
            const gop = try groups.getOrPut(op.input.key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, i);
        }
        const out = try allocator.alloc([]usize, groups.count());
        var written: usize = 0;
        errdefer {
            for (out[0..written]) |sl| allocator.free(sl);
            allocator.free(out);
        }
        var it2 = groups.valueIterator();
        while (it2.next()) |v| {
            out[written] = try allocator.dupe(usize, v.items);
            written += 1;
        }
        return out;
    }
};

fn kvw(cid: u64, key: u32, value: i32, call: u64, ret: u64) Operation(KVInput, i32) {
    return .{
        .client_id = cid,
        .input = .{ .is_write = true, .key = key, .value = value },
        .call = call,
        .output = 0,
        .return_time = ret,
    };
}
fn kvr(cid: u64, key: u32, observed: i32, call: u64, ret: u64) Operation(KVInput, i32) {
    return .{
        .client_id = cid,
        .input = .{ .is_write = false, .key = key, .value = 0 },
        .call = call,
        .output = observed,
        .return_time = ret,
    };
}

test "kv: per-key independence" {
    const alloc = std.testing.allocator;
    const m = KVModel{};
    // Two keys with independent histories — a failure on key A shouldn't
    // be hidden by valid ops on key B, and vice versa.
    const history = [_]Operation(KVInput, i32){
        kvw(1, 1, 10, 0, 10),
        kvw(2, 2, 20, 0, 10),
        kvr(3, 1, 10, 20, 30),
        kvr(4, 2, 20, 20, 30),
    };
    const res = try porcupine.checkOperations(KVModel, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "kv: failure on one key is detected across partitions" {
    const alloc = std.testing.allocator;
    const m = KVModel{};
    const history = [_]Operation(KVInput, i32){
        kvw(1, 1, 10, 0, 10),
        kvw(2, 2, 20, 0, 10),
        kvr(3, 1, 10, 20, 30),
        kvr(4, 2, 99, 20, 30), // wrong value for key=2
    };
    const res = try porcupine.checkOperations(KVModel, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

// ---------------------------------------------------------------------------
// Events API: minimal smoke test
// ---------------------------------------------------------------------------

test "event-based register: sequential write-read" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history = [_]Event(RegInput, i32){
        .{ .client_id = 1, .kind = .call, .input = .{ .is_write = true, .value = 5 }, .output = null, .id = 0 },
        .{ .client_id = 1, .kind = .@"return", .input = null, .output = 0, .id = 0 },
        .{ .client_id = 2, .kind = .call, .input = .{ .is_write = false, .value = 0 }, .output = null, .id = 1 },
        .{ .client_id = 2, .kind = .@"return", .input = null, .output = 5, .id = 1 },
    };
    const res = try porcupine.checkEvents(Reg, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

// ---------------------------------------------------------------------------
// Nondeterministic model via PowerSetModel
// ---------------------------------------------------------------------------

const CoinFlip = struct {
    pub const State = u32;
    pub const Input = void;
    pub const Output = u32;

    pub fn initStates(_: *const CoinFlip, allocator: std.mem.Allocator) ![]State {
        const out = try allocator.alloc(State, 1);
        out[0] = 0;
        return out;
    }
    /// Each step non-deterministically advances the counter by 1 or 2.
    pub fn step(
        _: *const CoinFlip,
        allocator: std.mem.Allocator,
        state: *const State,
        _: *const Input,
        output: *const Output,
    ) ![]State {
        // Output must match one of the two possible next states.
        if (output.* == state.* + 1 or output.* == state.* + 2) {
            const out = try allocator.alloc(State, 1);
            out[0] = output.*;
            return out;
        }
        return try allocator.alloc(State, 0);
    }
    pub fn cloneState(_: *const CoinFlip, _: std.mem.Allocator, s: *const State) !State {
        return s.*;
    }
    pub fn deinitState(_: *const CoinFlip, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const CoinFlip, a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
};

test "powerset: coin flip advances by 1 or 2" {
    const alloc = std.testing.allocator;
    const PS = porcupine.PowerSetModel(CoinFlip);
    const m = PS{ .inner = .{} };
    const history = [_]Operation(void, u32){
        .{ .client_id = 1, .input = {}, .call = 0, .output = 1, .return_time = 10 },
        .{ .client_id = 1, .input = {}, .call = 20, .output = 3, .return_time = 30 }, // 1 -> 3 is +2, valid
    };
    const res = try porcupine.checkOperations(PS, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "powerset: coin flip rejects impossible jump" {
    const alloc = std.testing.allocator;
    const PS = porcupine.PowerSetModel(CoinFlip);
    const m = PS{ .inner = .{} };
    const history = [_]Operation(void, u32){
        .{ .client_id = 1, .input = {}, .call = 0, .output = 5, .return_time = 10 }, // 0 -> 5 impossible
    };
    const res = try porcupine.checkOperations(PS, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

// ---------------------------------------------------------------------------
// Parallel-path and timeout coverage
// ---------------------------------------------------------------------------

test "kv: parallel path runs many partitions past the sequential threshold" {
    // sequential_threshold in checker.zig is 2000 total entries. Build a
    // history that clears it so checkParallel's multi-threaded branch runs.
    const alloc = std.testing.allocator;
    const n_keys: u32 = 10;
    const per_key: usize = 200; // 10 keys * 200 ops * 2 entries = 4000 entries
    var history: std.ArrayList(Operation(KVInput, i32)) = .empty;
    defer history.deinit(alloc);
    try history.ensureTotalCapacity(alloc, n_keys * per_key);
    var t: u64 = 0;
    for (0..n_keys) |k_usize| {
        const key: u32 = @intCast(k_usize);
        var last: i32 = 0;
        for (0..per_key) |i| {
            const is_write = (i % 2 == 0);
            if (is_write) {
                last = @intCast(i + 1);
                history.appendAssumeCapacity(kvw(key, key, last, t, t + 1));
            } else {
                history.appendAssumeCapacity(kvr(key, key, last, t, t + 1));
            }
            t += 2;
        }
    }
    const m = KVModel{};
    const res = try porcupine.checkOperations(KVModel, alloc, &m, history.items, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "timeout on a branching history returns ok or unknown, never illegal" {
    // The unit tests for makeDeadline / Deadline.hasFired cover the
    // deadline math deterministically. Here we only verify the integration
    // wiring: a 1 ns timeout on a branching register history must produce
    // one of the non-.illegal outcomes — never a false positive.
    const alloc = std.testing.allocator;
    const n_pairs: usize = 80;
    var history: std.ArrayList(Operation(RegInput, i32)) = .empty;
    defer history.deinit(alloc);
    try history.ensureTotalCapacity(alloc, n_pairs * 2);
    // Alternating concurrent writes and reads whose observed values
    // match one of the writes — forces real DFS exploration.
    for (0..n_pairs) |i| {
        const v: i32 = @intCast(i + 1);
        history.appendAssumeCapacity(w(@intCast(i), v, 0, 1_000_000));
        history.appendAssumeCapacity(r(@intCast(i + n_pairs), v, 0, 1_000_000));
    }
    const m = Reg{};
    const res = try porcupine.checkOperations(Reg, alloc, &m, history.items, 1);
    try std.testing.expect(res == .ok or res == .unknown);
}

// ---------------------------------------------------------------------------
// Event-path partitioning and illegal events
// ---------------------------------------------------------------------------

test "event-based register: illegal history returns illegal" {
    const alloc = std.testing.allocator;
    const m = Reg{};
    const history = [_]Event(RegInput, i32){
        .{ .client_id = 1, .kind = .call, .input = .{ .is_write = true, .value = 42 }, .output = null, .id = 0 },
        .{ .client_id = 1, .kind = .@"return", .input = null, .output = 0, .id = 0 },
        .{ .client_id = 2, .kind = .call, .input = .{ .is_write = false, .value = 0 }, .output = null, .id = 1 },
        .{ .client_id = 2, .kind = .@"return", .input = null, .output = 0, .id = 1 }, // read 0 after write 42
    };
    const res = try porcupine.checkEvents(Reg, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

// KV model variant with a partitionEvents hook — exercises the event-side
// partition path that previously had no coverage.
const KVModelEvents = struct {
    pub const State = i32;
    pub const Input = KVInput;
    pub const Output = i32;

    pub fn init(_: *const @This(), _: std.mem.Allocator) !State {
        return 0;
    }
    pub fn step(_: *const @This(), _: std.mem.Allocator, state: *const State, input: *const Input, output: *const Output) !?State {
        if (input.is_write) return input.value;
        if (output.* == state.*) return state.*;
        return null;
    }
    pub fn cloneState(_: *const @This(), _: std.mem.Allocator, s: *const State) !State {
        return s.*;
    }
    pub fn deinitState(_: *const @This(), _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const @This(), a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
    pub fn partitionEvents(
        _: *const @This(),
        allocator: std.mem.Allocator,
        history: []const Event(Input, Output),
    ) !?[][]usize {
        if (history.len == 0) return null;
        var groups: std.AutoHashMap(u32, std.ArrayList(usize)) = .init(allocator);
        defer {
            var it = groups.valueIterator();
            while (it.next()) |v| v.deinit(allocator);
            groups.deinit();
        }
        // Key lives on the .call event; we remember it per event-id so the
        // matching .@"return" lands in the same partition.
        var id_to_key: std.AutoHashMap(u64, u32) = .init(allocator);
        defer id_to_key.deinit();
        for (history, 0..) |ev, i| {
            const key: u32 = switch (ev.kind) {
                .call => blk: {
                    try id_to_key.put(ev.id, ev.input.?.key);
                    break :blk ev.input.?.key;
                },
                .@"return" => id_to_key.get(ev.id) orelse return null,
            };
            const gop = try groups.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, i);
        }
        const out = try allocator.alloc([]usize, groups.count());
        var written: usize = 0;
        errdefer {
            for (out[0..written]) |sl| allocator.free(sl);
            allocator.free(out);
        }
        var it2 = groups.valueIterator();
        while (it2.next()) |v| {
            out[written] = try allocator.dupe(usize, v.items);
            written += 1;
        }
        return out;
    }
};

test "events: partitioned per-key check catches illegal on one key" {
    const alloc = std.testing.allocator;
    const m = KVModelEvents{};
    // Key 1: legal write/read. Key 2: write 20 then read 99 (illegal).
    const events = [_]Event(KVInput, i32){
        .{ .client_id = 1, .kind = .call, .input = .{ .is_write = true, .key = 1, .value = 10 }, .output = null, .id = 0 },
        .{ .client_id = 1, .kind = .@"return", .input = null, .output = 0, .id = 0 },
        .{ .client_id = 2, .kind = .call, .input = .{ .is_write = true, .key = 2, .value = 20 }, .output = null, .id = 1 },
        .{ .client_id = 2, .kind = .@"return", .input = null, .output = 0, .id = 1 },
        .{ .client_id = 3, .kind = .call, .input = .{ .is_write = false, .key = 1, .value = 0 }, .output = null, .id = 2 },
        .{ .client_id = 3, .kind = .@"return", .input = null, .output = 10, .id = 2 },
        .{ .client_id = 4, .kind = .call, .input = .{ .is_write = false, .key = 2, .value = 0 }, .output = null, .id = 3 },
        .{ .client_id = 4, .kind = .@"return", .input = null, .output = 99, .id = 3 },
    };
    const res = try porcupine.checkEvents(KVModelEvents, alloc, &m, &events, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

// ---------------------------------------------------------------------------
// HashMap-state KV model — the first allocating model in the test suite.
//
// Ports `porcupine-rust/tests/common/mod.rs:67-98`. State is a real
// `AutoHashMapUnmanaged(u8, i64)` cloned on every `step` and freed on every
// `deinitState`. Without this fixture the per-entry deinit walk in
// checker.zig has nothing to free; with it, `std.testing.allocator` can
// catch leaks across the cache, calls-stack, and live-state paths.
//
// Parametrised on `arena_friendly` (Phase 4 opt-in) and `partitioned`
// (per-key partitioning that exercises the parallel path) so the same body
// produces all four variants.
// ---------------------------------------------------------------------------

const HashMapKvInput = struct {
    key: u8,
    is_write: bool,
    value: i64,
};

fn HashMapKvModel(comptime config: struct {
    arena_friendly: bool = false,
    partitioned: bool = false,
}) type {
    return struct {
        const Self = @This();

        pub const State = std.AutoHashMapUnmanaged(u8, i64);
        pub const Input = HashMapKvInput;
        pub const Output = i64;

        pub const arena_friendly: bool = config.arena_friendly;

        pub fn init(_: *const Self, _: std.mem.Allocator) !State {
            return .empty;
        }

        pub fn step(
            _: *const Self,
            allocator: std.mem.Allocator,
            state: *const State,
            input: *const Input,
            output: *const Output,
        ) !?State {
            // Clone-then-mutate matches the Rust `KvModel.step`. Allocator
            // is the per-worker arena; the clone is reclaimed in bulk at
            // partition exit (when arena_friendly) or via the per-entry
            // deinitState walk otherwise.
            var next = try state.clone(allocator);
            errdefer next.deinit(allocator);

            if (input.is_write) {
                try next.put(allocator, input.key, input.value);
                return next;
            }
            const stored = state.get(input.key) orelse 0;
            if (output.* == stored) return next;
            next.deinit(allocator);
            return null;
        }

        pub fn cloneState(
            _: *const Self,
            allocator: std.mem.Allocator,
            state: *const State,
        ) !State {
            return state.clone(allocator);
        }

        pub fn deinitState(
            _: *const Self,
            allocator: std.mem.Allocator,
            state: *State,
        ) void {
            state.deinit(allocator);
        }

        pub fn statesEqual(_: *const Self, a: *const State, b: *const State) bool {
            if (a.count() != b.count()) return false;
            var it = a.iterator();
            while (it.next()) |kv| {
                const other_v = b.get(kv.key_ptr.*) orelse return false;
                if (other_v != kv.value_ptr.*) return false;
            }
            return true;
        }

        /// Group operation indices by key. Always defined; returns null
        /// when the variant is non-partitioned (the checker treats null
        /// the same as no `partition` decl).
        pub fn partition(
            _: *const Self,
            allocator: std.mem.Allocator,
            history: []const Operation(Input, Output),
        ) !?[][]usize {
            if (comptime !config.partitioned) return null;
            if (history.len == 0) return null;

            var groups: std.AutoHashMap(u8, std.ArrayList(usize)) = .init(allocator);
            defer {
                var it = groups.valueIterator();
                while (it.next()) |v| v.deinit(allocator);
                groups.deinit();
            }
            for (history, 0..) |op, i| {
                const gop = try groups.getOrPut(op.input.key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, i);
            }
            const out = try allocator.alloc([]usize, groups.count());
            var written: usize = 0;
            errdefer {
                for (out[0..written]) |sl| allocator.free(sl);
                allocator.free(out);
            }
            var it2 = groups.valueIterator();
            while (it2.next()) |v| {
                out[written] = try allocator.dupe(usize, v.items);
                written += 1;
            }
            return out;
        }
    };
}

fn hkw(cid: u64, key: u8, value: i64, call: u64, ret: u64) Operation(HashMapKvInput, i64) {
    return .{
        .client_id = cid,
        .input = .{ .key = key, .is_write = true, .value = value },
        .call = call,
        .output = 0,
        .return_time = ret,
    };
}
fn hkr(cid: u64, key: u8, observed: i64, call: u64, ret: u64) Operation(HashMapKvInput, i64) {
    return .{
        .client_id = cid,
        .input = .{ .key = key, .is_write = false, .value = 0 },
        .call = call,
        .output = observed,
        .return_time = ret,
    };
}

test "hashmap-kv: write-then-read sequential is linearizable" {
    const alloc = std.testing.allocator;
    const M = HashMapKvModel(.{});
    const m = M{};
    const history = [_]Operation(HashMapKvInput, i64){
        hkw(1, 0, 42, 0, 10),
        hkr(2, 0, 42, 20, 30),
    };
    const res = try porcupine.checkOperations(M, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "hashmap-kv: read of unwritten key returning non-zero is illegal" {
    const alloc = std.testing.allocator;
    const M = HashMapKvModel(.{});
    const m = M{};
    const history = [_]Operation(HashMapKvInput, i64){
        hkr(1, 7, 99, 0, 10), // never wrote 99 to key 7
    };
    const res = try porcupine.checkOperations(M, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.illegal, res);
}

test "hashmap-kv: partitioned per-key, sequential threshold (small)" {
    // Stays under sequential_threshold (2000 entries). Goes through the
    // sequential-fallback branch of checkParallel; per-partition state is
    // a tiny AutoHashMap, and per-entry deinit walks fire if not arena_friendly.
    const alloc = std.testing.allocator;
    const M = HashMapKvModel(.{ .partitioned = true });
    const m = M{};
    const history = [_]Operation(HashMapKvInput, i64){
        hkw(1, 1, 10, 0, 10),
        hkw(2, 2, 20, 0, 10),
        hkr(3, 1, 10, 20, 30),
        hkr(4, 2, 20, 20, 30),
    };
    const res = try porcupine.checkOperations(M, alloc, &m, &history, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "hashmap-kv: partitioned per-key, parallel path (>2000 entries)" {
    // Exceeds checker.zig's sequential_threshold so the multi-threaded
    // branch dispatches workers — exercises Phase 3's caller-allocator
    // routing under testing.allocator across multiple threads.
    const alloc = std.testing.allocator;
    const M = HashMapKvModel(.{ .partitioned = true });
    const m = M{};
    const n_keys: u8 = 10;
    const per_key: usize = 200; // 10 * 200 * 2 = 4000 entries
    var history: std.ArrayList(Operation(HashMapKvInput, i64)) = .empty;
    defer history.deinit(alloc);
    try history.ensureTotalCapacity(alloc, n_keys * per_key);

    var t: u64 = 0;
    var k: u8 = 0;
    while (k < n_keys) : (k += 1) {
        var i: usize = 0;
        var last: i64 = 0;
        while (i < per_key) : (i += 1) {
            if (i % 2 == 0) {
                last = @as(i64, @intCast(k)) * 1000 + @as(i64, @intCast(i));
                history.appendAssumeCapacity(hkw(1, k, last, t, t + 1));
            } else {
                history.appendAssumeCapacity(hkr(1, k, last, t, t + 1));
            }
            t += 2;
        }
    }
    const res = try porcupine.checkOperations(M, alloc, &m, history.items, null);
    try std.testing.expectEqual(CheckResult.ok, res);
}

test "hashmap-kv: arena_friendly equivalence on illegal history" {
    // Same illegal history, two model variants. Must agree on the result
    // and neither must leak under testing.allocator. This is the guard
    // that the comptime arena_friendly branches don't silently diverge.
    const alloc = std.testing.allocator;
    const Slow = HashMapKvModel(.{ .arena_friendly = false });
    const Fast = HashMapKvModel(.{ .arena_friendly = true });
    const slow = Slow{};
    const fast = Fast{};
    // Two writes to the same key, then a read returning a value that no
    // single-point linearization could produce: the read overlaps both
    // writes and observes 1 even though write(2) finished first.
    const history = [_]Operation(HashMapKvInput, i64){
        hkw(1, 0, 1, 0, 10),
        hkw(2, 0, 2, 5, 15),
        hkr(3, 0, 99, 20, 30),
    };
    const res_slow = try porcupine.checkOperations(Slow, alloc, &slow, &history, null);
    const res_fast = try porcupine.checkOperations(Fast, alloc, &fast, &history, null);
    try std.testing.expectEqual(res_slow, res_fast);
    try std.testing.expectEqual(CheckResult.illegal, res_slow);
}

// OOM fault-injection regression test for the Phase 2 guard-flag refactor
// (see commit 16f76ab). The previous version of checkSingle had a latent
// ordering bug: `try calls.append` ran *after* `cache.append` had transferred
// ownership of `new_linearized` and `cache_state`, but the corresponding
// errdefers were still armed — so under a non-arena allocator that path would
// double-free. The bug was invisible under the per-worker ArenaAllocator (free
// is a no-op there). This test pumps a real allocating model through every
// possible OOM point and asserts no leak from the failing-allocator harness.
//
// The non-partitioned variant is used so only the caller thread runs DFS:
// avoids thread-safety questions about FailingAllocator under workers.
test "hashmap-kv: OOM at every allocation point does not leak" {
    const M = HashMapKvModel(.{});
    const m = M{};
    const history = [_]Operation(HashMapKvInput, i64){
        hkw(1, 0, 1, 0, 10),
        hkw(2, 1, 2, 5, 15),
        hkr(3, 0, 1, 20, 30),
        hkr(4, 1, 2, 25, 35),
    };

    const Runner = struct {
        fn run(
            allocator: std.mem.Allocator,
            model_ptr: *const M,
            hist: []const Operation(HashMapKvInput, i64),
        ) !void {
            // Either CheckResult or error.OutOfMemory; both are acceptable —
            // checkAllAllocationFailures is verifying that no path leaks.
            _ = porcupine.checkOperations(M, allocator, model_ptr, hist, null) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return e,
            };
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Runner.run,
        .{ &m, history[0..] },
    );
}

// ---------------------------------------------------------------------------
// CountingModel — direct gate on Phase 4's cleanup-defer skip.
//
// The bench measures the optimization empirically (~2-3% wall-clock at 2k
// ops). This test pins it at the unit level: a model whose `deinitState`
// bumps a shared atomic counter, run on a straight-line history that has no
// in-DFS deinit calls (no cache hits, no pop-stack branches). Under
// arena_friendly = false the cleanup defers walk the cache + calls + final
// state and produce a positive count; under arena_friendly = true those
// walks are comptime-skipped and the count must be exactly zero.
//
// If a future change re-introduces a per-entry walk under arena_friendly
// (or drops the conservative walk under !arena_friendly), this test fires
// before any other signal.
// ---------------------------------------------------------------------------

fn CountingModel(comptime is_arena_friendly: bool) type {
    return struct {
        const Self = @This();
        pub const State = []u8;
        pub const Input = u32;
        pub const Output = u32;

        pub const arena_friendly: bool = is_arena_friendly;

        // Pointer field: model is passed as `*const Self`, so a counter has
        // to live outside the struct and be reached through indirection.
        deinit_count: *std.atomic.Value(usize),

        pub fn init(_: *const Self, allocator: std.mem.Allocator) !State {
            return try allocator.alloc(u8, 0);
        }
        pub fn step(
            _: *const Self,
            allocator: std.mem.Allocator,
            state: *const State,
            input: *const Input,
            output: *const Output,
        ) !?State {
            if (output.* != input.*) return null;
            const next = try allocator.alloc(u8, state.len + 1);
            @memcpy(next[0..state.len], state.*);
            next[state.len] = @truncate(input.*);
            return next;
        }
        pub fn cloneState(_: *const Self, allocator: std.mem.Allocator, s: *const State) !State {
            return try allocator.dupe(u8, s.*);
        }
        pub fn deinitState(self: *const Self, allocator: std.mem.Allocator, s: *State) void {
            allocator.free(s.*);
            _ = self.deinit_count.fetchAdd(1, .monotonic);
        }
        pub fn statesEqual(_: *const Self, a: *const State, b: *const State) bool {
            return std.mem.eql(u8, a.*, b.*);
        }
    };
}

test "arena_friendly comptime-skips cleanup defers (deinitState count gates)" {
    const alloc = std.testing.allocator;

    const Slow = CountingModel(false);
    const Fast = CountingModel(true);

    var slow_count: std.atomic.Value(usize) = .init(0);
    var fast_count: std.atomic.Value(usize) = .init(0);
    const slow = Slow{ .deinit_count = &slow_count };
    const fast = Fast{ .deinit_count = &fast_count };

    // Straight-line history: each call is the unique candidate at its
    // position. DFS marches forward without branching, so neither the
    // cache-hit `model.deinitState(&ns)` nor the pop-stack
    // `model.deinitState(&state)` ever runs. Every deinitState we observe
    // therefore comes from a cleanup defer.
    const history = [_]Operation(u32, u32){
        .{ .client_id = 0, .input = 1, .output = 1, .call = 0, .return_time = 1 },
        .{ .client_id = 0, .input = 2, .output = 2, .call = 2, .return_time = 3 },
        .{ .client_id = 0, .input = 3, .output = 3, .call = 4, .return_time = 5 },
    };

    const slow_res = try porcupine.checkOperations(Slow, alloc, &slow, &history, null);
    const fast_res = try porcupine.checkOperations(Fast, alloc, &fast, &history, null);

    try std.testing.expectEqual(CheckResult.ok, slow_res);
    try std.testing.expectEqual(CheckResult.ok, fast_res);

    const slow_n = slow_count.load(.monotonic);
    const fast_n = fast_count.load(.monotonic);

    // Conservative path: 1 (final state) + 3 (calls frames) + 3 (cache
    // entries) = 7 expected. Asserting `> 0` keeps the test resilient to
    // future cleanup-shape changes; the exact value isn't load-bearing.
    try std.testing.expect(slow_n > 0);
    // Fast path: zero in-DFS deinit calls + zero cleanup-defer deinit
    // calls = 0. This is the strict assertion.
    try std.testing.expectEqual(@as(usize, 0), fast_n);
}

test "hashmap-kv: cache-pressure stress, both arena_friendly variants" {
    // Pure leak-detection workload at scale: a 500-op sequential history
    // across 4 keys, run under both `arena_friendly = false` (per-entry
    // deinitState walk fires) and `arena_friendly = true` (cleanup walks
    // skipped, arena reclaims). Both must agree on the result and neither
    // must leak under testing.allocator. With multi-key state, each cached
    // HashMap holds 4 entries — non-trivial work for the deinit walk in
    // the conservative path.
    const alloc = std.testing.allocator;
    const Slow = HashMapKvModel(.{ .arena_friendly = false });
    const Fast = HashMapKvModel(.{ .arena_friendly = true });
    const slow = Slow{};
    const fast = Fast{};

    const n_ops: usize = 500;
    const n_keys: u8 = 4;
    var history: std.ArrayList(Operation(HashMapKvInput, i64)) = .empty;
    defer history.deinit(alloc);
    try history.ensureTotalCapacity(alloc, n_ops);

    // Ops come in (write, read) pairs cycling through keys: (w0,r0,w1,r1,
    // w2,r2,w3,r3,w0,r0,…). Reads observe the value the immediately-prior
    // write to the same key set, so the history is straight-line
    // linearizable; the cache grows to ~n_ops entries with multi-key
    // HashMap states.
    var t: u64 = 0;
    var last: [n_keys]i64 = @splat(0);
    var i: usize = 0;
    while (i < n_ops) : (i += 1) {
        const k: u8 = @intCast((i / 2) % n_keys);
        if (i % 2 == 0) {
            const v: i64 = @intCast(i + 1);
            history.appendAssumeCapacity(hkw(1, k, v, t, t + 1));
            last[k] = v;
        } else {
            history.appendAssumeCapacity(hkr(1, k, last[k], t, t + 1));
        }
        t += 2;
    }

    const res_slow = try porcupine.checkOperations(Slow, alloc, &slow, history.items, null);
    const res_fast = try porcupine.checkOperations(Fast, alloc, &fast, history.items, null);
    try std.testing.expectEqual(res_slow, res_fast);
    try std.testing.expectEqual(CheckResult.ok, res_slow);
}
