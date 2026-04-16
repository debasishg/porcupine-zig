//! Compact bitset with small-buffer optimization (SBO).
//!
//! Bit layout: bits 0–63 in `data[0]`, bits 64–127 in `data[1]`, etc.
//! Mirrors `bitset.go` and `bitset.rs` from the Go and Rust originals.
//!
//! Inline capacity of 4 `u64`s (256 bits) covers up to 256 operations without
//! a heap allocation. Typical histories (etcd ~170 ops → 3 chunks, KV
//! per-partition ≤ 50 ops → 1 chunk) fit entirely inline, eliminating a heap
//! allocation on every `clone()`.
//!
//! The bitset is allocator-aware rather than owning: callers pass an allocator
//! on creation and the same allocator on `deinit` / `clone`. This lets the DFS
//! route all bitset memory through an arena allocator that can be reset in
//! one call when the partition finishes.

const std = @import("std");

/// Number of u64 chunks stored inline before spilling to the heap.
/// 4 * 64 = 256 bits. Keep this at a power of two so `div_ceil(n, 64)` is cheap.
pub const inline_cap: usize = 4;

pub const Bitset = struct {
    /// Inline storage for up to `inline_cap * 64` bits.
    inline_buf: [inline_cap]u64,
    /// Heap storage used only when `chunks > inline_cap`. Owned by the allocator
    /// passed to `init` / `clone` / `deinit`. Empty slice when unused.
    heap: []u64,
    /// Logical size in u64 chunks. Active storage is `inline_buf[0..chunks]`
    /// when `chunks <= inline_cap`, otherwise `heap[0..chunks]`.
    chunks: usize,

    /// Allocate a bitset large enough to hold `n` bits, all initially zero.
    pub fn init(allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Bitset {
        const c = std.math.divCeil(usize, n, 64) catch unreachable;
        var self: Bitset = .{
            .inline_buf = @splat(0),
            .heap = &.{},
            .chunks = c,
        };
        if (c > inline_cap) {
            self.heap = try allocator.alloc(u64, c);
            @memset(self.heap, 0);
        }
        return self;
    }

    pub fn deinit(self: *Bitset, allocator: std.mem.Allocator) void {
        if (self.heap.len > 0) allocator.free(self.heap);
        self.heap = &.{};
        self.chunks = 0;
    }

    /// Deep clone. Touches the heap only when spilling beyond `inline_cap`.
    pub fn clone(self: *const Bitset, allocator: std.mem.Allocator) std.mem.Allocator.Error!Bitset {
        var out: Bitset = .{
            .inline_buf = self.inline_buf,
            .heap = &.{},
            .chunks = self.chunks,
        };
        if (self.chunks > inline_cap) {
            out.heap = try allocator.dupe(u64, self.heap[0..self.chunks]);
        }
        return out;
    }

    /// Immutable view of the active chunk storage.
    pub inline fn data(self: *const Bitset) []const u64 {
        return if (self.chunks > inline_cap)
            self.heap[0..self.chunks]
        else
            self.inline_buf[0..self.chunks];
    }

    /// Mutable view of the active chunk storage.
    pub inline fn dataMut(self: *Bitset) []u64 {
        return if (self.chunks > inline_cap)
            self.heap[0..self.chunks]
        else
            self.inline_buf[0..self.chunks];
    }

    const Ix = struct { major: usize, minor: u6 };
    inline fn index(pos: usize) Ix {
        return .{ .major = pos / 64, .minor = @intCast(pos % 64) };
    }

    /// Set bit at `pos`.
    pub inline fn set(self: *Bitset, pos: usize) void {
        const ix = index(pos);
        self.dataMut()[ix.major] |= (@as(u64, 1) << ix.minor);
    }

    /// Clear bit at `pos`.
    pub inline fn clear(self: *Bitset, pos: usize) void {
        const ix = index(pos);
        self.dataMut()[ix.major] &= ~(@as(u64, 1) << ix.minor);
    }

    /// Count the number of set bits.
    pub fn popcnt(self: *const Bitset) usize {
        var total: usize = 0;
        for (self.data()) |v| total += @popCount(v);
        return total;
    }

    /// Hash of the bitset. Matches the Go / Rust implementations:
    /// `hash = popcnt; for each chunk: hash ^= chunk`.
    pub fn hash(self: *const Bitset) u64 {
        var h: u64 = @intCast(self.popcnt());
        for (self.data()) |v| h ^= v;
        return h;
    }

    /// Compute the hash that `self` would have if bit `pos` were also set.
    /// Does not mutate `self`. The caller must guarantee `pos` is currently clear.
    ///
    /// # Deferred-clone optimisation
    ///
    /// Setting a bit changes exactly two terms in the hash definition:
    ///   - popcnt increases by 1 (XOR in 1 into the low bit of `h`).
    ///   - chunk `major` changes from `old_word` to `new_word`, i.e. XORs in
    ///     `(old_word ^ new_word)` into `h`.
    /// So the new hash is `hash ^ old_word ^ new_word ^ 1` — O(1) arithmetic
    /// and no allocation. The Rust port calls this `hash_with_bit`; Go has no
    /// equivalent and pays for the clone on every probe.
    pub inline fn hashWithBit(self: *const Bitset, pos: usize) u64 {
        const ix = index(pos);
        const words = self.data();
        const old_word = words[ix.major];
        const new_word = old_word | (@as(u64, 1) << ix.minor);
        return self.hash() ^ old_word ^ new_word ^ 1;
    }

    /// Structural equality.
    pub fn eql(self: *const Bitset, other: *const Bitset) bool {
        if (self.chunks != other.chunks) return false;
        const a = self.data();
        const b = other.data();
        for (a, b) |x, y| if (x != y) return false;
        return true;
    }

    /// Check equality as if bit `pos` were set in `self`.
    /// Does not mutate `self`. The caller must guarantee `pos` is currently clear.
    ///
    /// Used together with `hashWithBit` so cache probes in the DFS never need
    /// to materialize the mutated bitset — we fabricate the single differing
    /// word on the fly during the comparison loop.
    pub inline fn eqlWithBit(self: *const Bitset, pos: usize, other: *const Bitset) bool {
        if (self.chunks != other.chunks) return false;
        const ix = index(pos);
        const a = self.data();
        const b = other.data();
        const set_mask = @as(u64, 1) << ix.minor;
        for (a, b, 0..) |x, y, i| {
            const adj = if (i == ix.major) x | set_mask else x;
            if (adj != y) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "set / clear / popcnt" {
    const allocator = std.testing.allocator;
    var b = try Bitset.init(allocator, 128);
    defer b.deinit(allocator);
    b.set(0);
    b.set(63);
    b.set(64);
    b.set(127);
    try std.testing.expectEqual(@as(usize, 4), b.popcnt());
    b.clear(63);
    try std.testing.expectEqual(@as(usize, 3), b.popcnt());
}

test "hash is deterministic" {
    const allocator = std.testing.allocator;
    var b1 = try Bitset.init(allocator, 64);
    defer b1.deinit(allocator);
    var b2 = try Bitset.init(allocator, 64);
    defer b2.deinit(allocator);
    b1.set(3);
    b1.set(7);
    b2.set(3);
    b2.set(7);
    try std.testing.expectEqual(b1.hash(), b2.hash());
    try std.testing.expect(b1.eql(&b2));
}

test "clone is independent" {
    const allocator = std.testing.allocator;
    var b1 = try Bitset.init(allocator, 64);
    defer b1.deinit(allocator);
    b1.set(5);
    var b2 = try b1.clone(allocator);
    defer b2.deinit(allocator);
    b2.set(10);
    try std.testing.expectEqual(@as(usize, 1), b1.popcnt());
    try std.testing.expectEqual(@as(usize, 2), b2.popcnt());
}

test "hash_with_bit matches hash after set" {
    const allocator = std.testing.allocator;
    var b1 = try Bitset.init(allocator, 300); // 5 chunks -> heap spill
    defer b1.deinit(allocator);
    b1.set(1);
    b1.set(200);
    const h_with = b1.hashWithBit(150);

    var b2 = try b1.clone(allocator);
    defer b2.deinit(allocator);
    b2.set(150);
    try std.testing.expectEqual(b2.hash(), h_with);
}

test "eql_with_bit matches eql after set" {
    const allocator = std.testing.allocator;
    var b1 = try Bitset.init(allocator, 64);
    defer b1.deinit(allocator);
    var b2 = try Bitset.init(allocator, 64);
    defer b2.deinit(allocator);
    b2.set(10);
    try std.testing.expect(b1.eqlWithBit(10, &b2));
    b2.set(20);
    try std.testing.expect(!b1.eqlWithBit(10, &b2));
}

test "heap spill at 5 chunks" {
    const allocator = std.testing.allocator;
    var b = try Bitset.init(allocator, 320); // 5 chunks
    defer b.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), b.chunks);
    try std.testing.expect(b.heap.len == 5);
    b.set(300);
    try std.testing.expectEqual(@as(usize, 1), b.popcnt());

    var cloned = try b.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(cloned.heap.ptr != b.heap.ptr);
    try std.testing.expect(cloned.eql(&b));
}
