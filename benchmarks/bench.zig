//! Micro-benchmark for the linearizability checker.
//!
//! Constructs a synthetic "contested register" history big enough to exercise
//! the DFS cache, then measures steady-state throughput by running the check
//! `iterations` times. Run with:
//!
//!   zig build bench -Doptimize=ReleaseFast -- [iterations=100] [ops=170]
//!
//! This is not a substitute for the real Jepsen / KV benchmark data the Rust
//! port uses — it exists purely so `zig build bench` wires through and so
//! developers have a fast-iteration sanity check when changing the DFS.

const std = @import("std");
const porcupine = @import("porcupine");

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

fn buildHistory(allocator: std.mem.Allocator, ops: usize) ![]porcupine.Operation(RegInput, i32) {
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

pub fn main(init: std.process.Init.Minimal) !void {
    // Zig 0.16's main takes an `Init.Minimal` (preferred over the removed
    // `argsAlloc` helper). Args are already parsed into a `[]const []const u8`.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // `Args.Iterator.initAllocator` is the 0.16 cross-platform entry point.
    var args_it = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer args_it.deinit();
    _ = args_it.next(); // skip program name
    const iterations: usize = if (args_it.next()) |s| try std.fmt.parseInt(usize, s, 10) else 100;
    const ops: usize = if (args_it.next()) |s| try std.fmt.parseInt(usize, s, 10) else 170;

    const history = try buildHistory(alloc, ops);
    defer alloc.free(history);

    // `std.debug.print` is the last holdout of the old synchronous I/O API
    // in 0.16 — everything else moved under `std.Io`. For a dev-only bench
    // tool it's plenty.
    std.debug.print("running {d} iterations of a {d}-op register history...\n", .{ iterations, ops });

    const model = Reg{};

    // Warm-up.
    for (0..3) |_| _ = try porcupine.checkOperations(Reg, alloc, &model, history, null);

    // Use the checker's monotonic clock helper rather than inlining
    // clock_gettime again — `std.time.nanoTimestamp` is gone in Zig 0.16.
    const start_ns = porcupine.checker.nowNs();
    for (0..iterations) |_| {
        const res = try porcupine.checkOperations(Reg, alloc, &model, history, null);
        std.debug.assert(res == .ok);
    }
    const end_ns = porcupine.checker.nowNs();
    const total_ns = end_ns - start_ns;
    const per_call_ns = total_ns / iterations;
    std.debug.print("total: {d} ns, per-call: {d} ns ({d:.2} us)\n", .{
        total_ns,
        per_call_ns,
        @as(f64, @floatFromInt(per_call_ns)) / 1000.0,
    });
}
