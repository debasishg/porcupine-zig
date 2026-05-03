//! Micro-benchmark for the linearizability checker.
//!
//! Two modes:
//!
//!   register (default) — synthetic "contested register" history, exercises
//!                        the DFS hot loop. State is `i32`, no per-state
//!                        allocations; `arena_friendly` has no effect here.
//!
//!   hashmap            — `HashMapKvModel` with `AutoHashMapUnmanaged(u8, i64)`
//!                        state. Long sequential history; the cache grows
//!                        proportionally to `ops` and each cached state is a
//!                        real multi-key HashMap. Runs the workload twice —
//!                        once with `arena_friendly = false` (per-entry deinit
//!                        walk fires) and once with `arena_friendly = true`
//!                        (cleanup walk skipped) — and reports the delta.
//!
//! Run with:
//!
//!   zig build bench -Doptimize=ReleaseFast -- [iterations=100] [ops=170] [mode=register]
//!   zig build bench -Doptimize=ReleaseFast -- 50 500 hashmap

const std = @import("std");
const porcupine = @import("porcupine");

// ---------------------------------------------------------------------------
// Register model — the existing bench workload.
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
    pub fn step(_: *const Reg, _: std.mem.Allocator, state: *const State, input: *const Input, output: *const Output) !?State {
        if (input.is_write) return input.value;
        if (output.* == state.*) return state.*;
        return null;
    }
    pub fn cloneState(_: *const Reg, _: std.mem.Allocator, s: *const State) !State {
        return s.*;
    }
    pub fn deinitState(_: *const Reg, _: std.mem.Allocator, _: *State) void {}
    pub fn statesEqual(_: *const Reg, a: *const State, b: *const State) bool {
        return a.* == b.*;
    }
};

fn buildRegisterHistory(allocator: std.mem.Allocator, ops: usize) ![]porcupine.Operation(RegInput, i32) {
    // Alternating concurrent writes and reads — produces non-trivial DFS
    // branching without being actually illegal.
    const history = try allocator.alloc(porcupine.Operation(RegInput, i32), ops);
    var rng_state = std.Random.DefaultPrng.init(42);
    const rng = rng_state.random();
    var last_write: i32 = 0;
    for (history, 0..) |*op, i| {
        const is_write = (i % 3 != 2);
        const call: u64 = @intCast(i * 10);
        const ret: u64 = call + 5 + @as(u64, rng.intRangeAtMost(u32, 0, 20));
        if (is_write) {
            last_write = @intCast(i);
            op.* = .{
                .client_id = @intCast(i % 4),
                .input = .{ .is_write = true, .value = last_write },
                .call = call,
                .output = 0,
                .return_time = ret,
            };
        } else {
            op.* = .{
                .client_id = @intCast(i % 4),
                .input = .{ .is_write = false, .value = 0 },
                .call = call,
                .output = last_write,
                .return_time = ret,
            };
        }
    }
    return history;
}

// ---------------------------------------------------------------------------
// HashMap KV model — exercises the arena_friendly cleanup-skip path.
// Mirrors the test fixture in tests/integration.zig but kept separate so the
// bench binary doesn't depend on the test module.
// ---------------------------------------------------------------------------

const HashMapKvInput = struct {
    key: u8,
    is_write: bool,
    value: i64,
};

fn HashMapKv(comptime is_arena_friendly: bool) type {
    return struct {
        const Self = @This();
        pub const State = std.AutoHashMapUnmanaged(u8, i64);
        pub const Input = HashMapKvInput;
        pub const Output = i64;

        pub const arena_friendly: bool = is_arena_friendly;

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

        pub fn cloneState(_: *const Self, allocator: std.mem.Allocator, state: *const State) !State {
            return state.clone(allocator);
        }

        pub fn deinitState(_: *const Self, allocator: std.mem.Allocator, state: *State) void {
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
    };
}

fn buildHashMapHistory(
    allocator: std.mem.Allocator,
    ops: usize,
) ![]porcupine.Operation(HashMapKvInput, i64) {
    // Sequential pairs (write k, read k) cycling through 4 keys. Reads
    // observe the most recent write to that key, so the history is
    // straight-line linearizable — cache grows to ~ops entries with
    // genuinely multi-key HashMap states.
    const n_keys: u8 = 4;
    const history = try allocator.alloc(porcupine.Operation(HashMapKvInput, i64), ops);
    var t: u64 = 0;
    var last: [n_keys]i64 = @splat(0);
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const k: u8 = @intCast((i / 2) % n_keys);
        if (i % 2 == 0) {
            const v: i64 = @intCast(i + 1);
            history[i] = .{
                .client_id = 1,
                .input = .{ .key = k, .is_write = true, .value = v },
                .call = t,
                .output = 0,
                .return_time = t + 1,
            };
            last[k] = v;
        } else {
            history[i] = .{
                .client_id = 1,
                .input = .{ .key = k, .is_write = false, .value = 0 },
                .call = t,
                .output = last[k],
                .return_time = t + 1,
            };
        }
        t += 2;
    }
    return history;
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

const BenchMode = enum { register, hashmap };

fn parseMode(s: []const u8) ?BenchMode {
    if (std.mem.eql(u8, s, "register")) return .register;
    if (std.mem.eql(u8, s, "hashmap")) return .hashmap;
    return null;
}

fn timeOne(
    comptime M: type,
    allocator: std.mem.Allocator,
    model: *const M,
    history: []const porcupine.Operation(M.Input, M.Output),
    iterations: usize,
) !u64 {
    // Warm-up.
    for (0..3) |_| {
        const res = try porcupine.checkOperations(M, allocator, model, history, null);
        std.debug.assert(res == .ok);
    }
    const start_ns = porcupine.checker.nowNs();
    for (0..iterations) |_| {
        const res = try porcupine.checkOperations(M, allocator, model, history, null);
        std.debug.assert(res == .ok);
    }
    return porcupine.checker.nowNs() - start_ns;
}

fn report(label: []const u8, total_ns: u64, iterations: usize) void {
    const per_call_ns = total_ns / iterations;
    std.debug.print("  {s}: total {d} ns, per-call {d} ns ({d:.2} us)\n", .{
        label,
        total_ns,
        per_call_ns,
        @as(f64, @floatFromInt(per_call_ns)) / 1000.0,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_it = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer args_it.deinit();
    _ = args_it.next(); // skip program name
    const iterations: usize = if (args_it.next()) |s| try std.fmt.parseInt(usize, s, 10) else 100;
    const ops: usize = if (args_it.next()) |s| try std.fmt.parseInt(usize, s, 10) else 170;
    const mode: BenchMode = if (args_it.next()) |s|
        parseMode(s) orelse return error.InvalidMode
    else
        .register;

    switch (mode) {
        .register => {
            const history = try buildRegisterHistory(alloc, ops);
            defer alloc.free(history);
            std.debug.print("register: {d} iterations × {d}-op history\n", .{ iterations, ops });
            const model = Reg{};
            const total_ns = try timeOne(Reg, alloc, &model, history, iterations);
            report("Reg", total_ns, iterations);
        },
        .hashmap => {
            const history = try buildHashMapHistory(alloc, ops);
            defer alloc.free(history);
            std.debug.print("hashmap: {d} iterations × {d}-op history (4 keys, sequential write/read pairs)\n", .{ iterations, ops });

            const Slow = HashMapKv(false);
            const Fast = HashMapKv(true);
            const slow = Slow{};
            const fast = Fast{};

            const slow_ns = try timeOne(Slow, alloc, &slow, history, iterations);
            const fast_ns = try timeOne(Fast, alloc, &fast, history, iterations);

            report("arena_friendly=false", slow_ns, iterations);
            report("arena_friendly=true ", fast_ns, iterations);

            // Delta. Negative = fast path is faster (expected); positive =
            // fast path is slower (unexpected — investigate).
            const slow_per: i128 = @intCast(slow_ns / iterations);
            const fast_per: i128 = @intCast(fast_ns / iterations);
            const delta_ns: i128 = fast_per - slow_per;
            const pct: f64 = @as(f64, @floatFromInt(delta_ns)) /
                @as(f64, @floatFromInt(slow_per)) * 100.0;
            std.debug.print("  delta: {d} ns/call ({d:.2} %) — negative means arena_friendly is faster\n", .{ delta_ns, pct });
        },
    }
}
