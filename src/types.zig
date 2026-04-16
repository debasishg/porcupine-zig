//! Public value types: `CheckResult`, `Operation`, `Event`, `EventKind`,
//! `LinearizationInfo`.
//!
//! Mirrors `src/types.rs` in the Rust port. Kept as plain structs so users can
//! allocate them on the stack, in arrays, or in any other container without
//! paying for hidden allocations.

const std = @import("std");

/// The outcome of a linearizability check.
pub const CheckResult = enum {
    /// The history is linearizable.
    ok,
    /// The history is not linearizable.
    illegal,
    /// The check timed out before a definitive answer was reached.
    unknown,
};

/// A completed concurrent operation with call/return timestamps.
///
/// Generic over `I` (input) and `O` (output). Timestamps are `u64` nanoseconds
/// (same as the Go and Rust originals).
pub fn Operation(comptime I: type, comptime O: type) type {
    return struct {
        /// Identifier for the client that issued this operation.
        client_id: u64,
        /// Input to the operation.
        input: I,
        /// Timestamp when the operation was invoked.
        call: u64,
        /// Output returned by the operation.
        output: O,
        /// Timestamp when the operation returned. Must satisfy `call <= return_time`.
        return_time: u64,

        pub const InputType = I;
        pub const OutputType = O;
    };
}

/// Whether an event is a call or a return.
pub const EventKind = enum(u8) {
    call,
    @"return",
};

/// A single call or return event in a history.
///
/// For `kind = .call`, `input` must be non-null and `output` must be null.
/// For `kind = .@"return"`, `output` must be non-null and `input` must be null.
pub fn Event(comptime I: type, comptime O: type) type {
    return struct {
        /// Identifier for the client that issued this event.
        client_id: u64,
        /// Whether this is a call or a return.
        kind: EventKind,
        /// For a call event: the input value. For a return event: `null`.
        input: ?I,
        /// For a return event: the output value. For a call event: `null`.
        output: ?O,
        /// Unique identifier linking a call event to its matching return event.
        id: u64,

        pub const InputType = I;
        pub const OutputType = O;
    };
}

/// Diagnostic information about a (partial) linearization, used for visualization.
///
/// Not yet populated by the checker — reserved for a future
/// `checkOperationsVerbose` / `checkEventsVerbose` entry point, mirroring the
/// Go original.
pub const LinearizationInfo = struct {
    /// For each partition, the sequence of operation indices in linearization order.
    partitions: std.ArrayList(std.ArrayList(std.ArrayList(usize))) = .empty,

    pub fn deinit(self: *LinearizationInfo, allocator: std.mem.Allocator) void {
        for (self.partitions.items) |*p| {
            for (p.items) |*inner| inner.deinit(allocator);
            p.deinit(allocator);
        }
        self.partitions.deinit(allocator);
    }
};

test "Operation struct layout" {
    const Op = Operation(u32, i64);
    const op: Op = .{
        .client_id = 1,
        .input = 10,
        .call = 100,
        .output = -5,
        .return_time = 200,
    };
    try std.testing.expectEqual(@as(u64, 1), op.client_id);
    try std.testing.expectEqual(@as(u32, 10), op.input);
    try std.testing.expectEqual(@as(i64, -5), op.output);
}

test "Event with null fields" {
    const Ev = Event(u32, u32);
    const call: Ev = .{
        .client_id = 1,
        .kind = .call,
        .input = 42,
        .output = null,
        .id = 7,
    };
    const ret: Ev = .{
        .client_id = 1,
        .kind = .@"return",
        .input = null,
        .output = 99,
        .id = 7,
    };
    try std.testing.expectEqual(@as(?u32, 42), call.input);
    try std.testing.expectEqual(@as(?u32, null), call.output);
    try std.testing.expectEqual(@as(?u32, null), ret.input);
    try std.testing.expectEqual(@as(?u32, 99), ret.output);
}
