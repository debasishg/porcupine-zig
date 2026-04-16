//! porcupine-zig: a fast linearizability checker.
//!
//! Port of <https://github.com/debasishg/porcupine-rust>, which itself is a
//! port of <https://github.com/anishathalye/porcupine>.
//!
//! # Quick start
//!
//! Define a model (any struct matching the comptime shape documented in
//! `model.zig`), then call `checker.checkOperations` or `checker.checkEvents`.
//!
//! ```zig
//! const porcupine = @import("porcupine");
//! const res = try porcupine.checker.checkOperations(MyModel, allocator, &m, history, null);
//! std.debug.assert(res == .ok);
//! ```

const std = @import("std");

pub const types = @import("types.zig");
pub const bitset = @import("bitset.zig");
pub const model = @import("model.zig");
pub const checker = @import("checker.zig");

pub const CheckResult = types.CheckResult;
pub const Operation = types.Operation;
pub const Event = types.Event;
pub const EventKind = types.EventKind;
pub const LinearizationInfo = types.LinearizationInfo;
pub const PowerSetModel = model.PowerSetModel;
pub const checkOperations = checker.checkOperations;
pub const checkEvents = checker.checkEvents;

test {
    std.testing.refAllDecls(@This());
}
