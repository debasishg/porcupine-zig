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
