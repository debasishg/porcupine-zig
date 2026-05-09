# `EntryOf` / `NodeOf` refactor — flat struct → tagged union

This note documents a structural change to the internal entry / node
representation in `src/checker.zig`. Public API is unaffected.

## Motivation

This note works through a generic question that comes up when porting Rust to
Zig: how to translate a Rust `enum` whose variants carry payload. Rust's
tagged enum has a direct Zig analogue in `union(enum)`, but a flat struct
with a `bool` (or other) discriminant and per-variant "shadow" payload fields
is also tempting on the grounds that a uniform layout is simpler or more
cache-friendly. This case study shows that intuition is wrong on both counts.

The Rust source being ported defined the entry / node representation as
follows:

```rust
enum EntryValue<I, O> {
    Call(I),
    Return(O),
}

struct Entry<I, O> {
    id: usize, // operation id (0-indexed); call and return share the same id
    time: u64, // u64 to avoid silent overflow when timestamps are near u64::MAX
    value: EntryValue<I, O>,
}

// Sentinel HEAD is always at index 0; real nodes occupy indices 1..=2n.
// `value` is `None` only for the sentinel; always `Some` for real nodes.
struct Node<I, O> {
    value: Option<EntryValue<I, O>>,
    id: u32,
    match_idx: u32,   // u32::MAX if absent
    prev: u32,
    next: u32,        // u32::MAX if absent
}
```

A review of the Zig port found that it had diverged from this design —
collapsing the enum into a `bool` discriminant with two shadow payload
fields — in a way that was neither more cache-friendly nor idiomatic. The
sections below explain the earlier Zig design, why it was suboptimal, and
what the new design (a faithful translation of the Rust enum into
`union(enum)`, and `Option` into Zig's optional `?T`) improves.

## Earlier design

```zig
fn EntryOf(comptime I: type, comptime O: type) type {
    return struct {
        id: u32,
        time: u64,
        is_call: bool,
        input: I,     // meaningful only when is_call == true
        output: O,    // meaningful only when is_call == false
    };
}

fn NodeOf(comptime I: type, comptime O: type) type {
    return struct {
        is_call: bool,
        input: I,     // meaningful only when is_call == true
        output: O,    // meaningful only when is_call == false
        id: u32,
        match_idx: u32,
        prev: u32,
        next: u32,
    };
}
```

An inline comment in the old code argued that a tagged union would be
"cleaner" but that the flat layout kept `Entry` "down to a single cache line
for most I/O types." Construction sites set the unused field to `undefined`:

```zig
entries[2 * i] = .{
    .id = @intCast(i),
    .time = op.call,
    .is_call = true,
    .input = op.input,
    .output = undefined,     // <- undefined in a call entry
};
entries[2 * i + 1] = .{
    .id = @intCast(i),
    .time = op.return_time,
    .is_call = false,
    .input = undefined,      // <- undefined in a return entry
    .output = op.output,
};
```

The sentinel node at index 0 went even further — every field was `undefined`
except the link pointers.

## Drawbacks of the earlier design

1. **Larger records, not smaller.** Every `Node` allocated `sizeof(I) +
   sizeof(O)` bytes for the payload, even though only one of the two fields
   was ever meaningful. The Rust reference implementation uses
   `Option<EntryValue<I, O>>`, which allocates only `max(sizeof(I), sizeof(O)) + tag` bytes. 
   For `I = O = []const u8` (16 bytes each), Rust's
   node is ~40 bytes; the Zig version was ~56. The stated cache-line
   argument did not hold up: Rust's design is at least as cache-friendly,
   often strictly smaller.

   **Byte-by-byte breakdown.** Both assume 64-bit. A Zig `[]const u8`
   (or Rust `&[u8]`) is **16 bytes** — an 8-byte pointer plus an 8-byte
   length. Alignment requirement: 8 bytes.

   *Zig flat `NodeOf([]const u8, []const u8)` — 56 bytes:*

   | Field       | Size | Notes                          |
   |-------------|-----:|--------------------------------|
   | `is_call`   | 1    | bool                           |
   | *padding*   | 7    | to align next field to 8       |
   | `input`     | 16   | slice (ptr + len)              |
   | `output`    | 16   | slice                          |
   | `id`        | 4    | u32                            |
   | `match_idx` | 4    | u32                            |
   | `prev`      | 4    | u32                            |
   | `next`      | 4    | u32                            |
   | **total**   | **56** | (already 8-byte aligned)     |

   Both `input` and `output` always occupy space, even though only one is
   ever meaningful per node.

   *Rust `Node<&[u8], &[u8]>` — 40 bytes:*

   ```rust
   enum EntryValue<I, O> { Call(I), Return(O) }
   ```

   Rust lays the enum out as
   `max(sizeof(variants)) + discriminant + padding`:

   | Piece                       | Size | Notes                             |
   |-----------------------------|-----:|-----------------------------------|
   | discriminant (Call/Return)  | 1    | padded up to 8 for slice align    |
   | variant payload (one slice) | 16   | `max(16, 16) = 16` — not 16 + 16  |
   | **`EntryValue`**            | **24** |                                 |

   Now `Option<EntryValue>`: Rust's **niche optimisation** reuses an unused
   discriminant value to encode `None`, so `Option<EntryValue>` is the
   same size as `EntryValue` — still **24 bytes**, no extra byte for
   `Some`/`None`.

   ```rust
   struct Node { value: Option<EntryValue>, id, match_idx, prev, next }
   ```

   | Field      | Size |
   |------------|-----:|
   | `value`    | 24   |
   | 4 × `u32`  | 16   |
   | **total**  | **40** |

   *Why it matters:*

   - A 64-byte cache line holds **one** 56-byte Zig node (with 8 bytes
     slack) but holds a 40-byte Rust node plus 24 bytes of the next one.
     Sequential scans bring ~1.6× more useful nodes per line in the Rust
     layout.
   - The Zig saving claim ("keeps Entry down to a single cache line")
     only made sense against a *naive* union where the common fields
     would have been copied into every variant. Against Rust's actual
     design — variant payload in the union, common fields flat — the Zig
     flat struct was strictly bigger.
   - For smaller `I`/`O` (e.g. both `u32`) the two layouts come out
     roughly equal because padding absorbs the difference. The gap opens
     up as payloads grow.

   The key insight: the union only needs space for `max(I, O)`, not
   `I + O`.

2. **Uniform stride, same on both sides.** The claimed advantage of the flat
   struct was predictable stride across `[]Node`. But Rust's
   `Vec<Node<I, O>>` has uniform stride too — `Option<EntryValue>` occupies
   the maximum-variant size in every slot. Stride uniformity was not a
   differentiator between the designs; only per-record size was, and the
   flat struct lost on that axis.

3. **`undefined` used as in-band signalling.** Half the fields of every
   record were `undefined`. This works but:
   - The compiler cannot catch accidental reads of a return entry's `input`
     or a call entry's `output`.
   - A reader has to cross-reference `is_call` before touching a field,
     mentally enforcing a discipline that the type system could enforce for
     free.
   - The sentinel node compounded the problem by setting *every* payload
     field to `undefined`.

4. **Drift from the Rust reference.** Porting changes is easier when the two
   codebases share structure. The Rust side uses an explicit
   `enum EntryValue<I, O> { Call(I), Return(O) }`; the Zig side used a
   `bool` with two shadow fields. Future ports of additional behavior from
   Rust would have to be reshaped at each step.

## New design

```zig
fn EntryValueOf(comptime I: type, comptime O: type) type {
    return union(enum) {
        call: I,
        @"return": O,
    };
}

fn EntryOf(comptime I: type, comptime O: type) type {
    return struct {
        id: u32,
        time: u64,
        value: EntryValueOf(I, O),
    };
}

fn NodeOf(comptime I: type, comptime O: type) type {
    return struct {
        value: ?EntryValueOf(I, O),   // null only for the sentinel
        id: u32,
        match_idx: u32,
        prev: u32,
        next: u32,
    };
}
```

The variant-specific payload lives in a `union(enum)`. Common linked-list
fields (`id`, `match_idx`, `prev`, `next`) stay flat — no switch required
to access them. The sentinel uses `value = null`, a direct port of Rust's
`Option::None`. Construction sites read cleanly:

```zig
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
```

## Improvements

1. **Smaller records for non-trivial `I`/`O`.** `union(enum)` stores at most
   one variant; `max(sizeof(I), sizeof(O)) + tag` replaces
   `sizeof(I) + sizeof(O)`. Savings grow with the size of the payload types.

2. **Type safety.** The compiler rejects reading `.output` on a call node
   and `.call` on a return node. `undefined` no longer appears in the
   entry or node construction; it is confined to the sentinel's
   `value = null`, which is a regular optional.

3. **One source of truth for call-vs-return discrimination.** The tag on
   `value` is authoritative. The previous `is_call: bool` field is gone;
   it was redundant with `match_idx != NONE_REF` on the DFS hot path and
   redundant with the tag everywhere else.

4. **Structural parity with the Rust port.** `EntryValueOf(I, O)` maps
   one-for-one onto Rust's `enum EntryValue<I, O> { Call(I), Return(O) }`,
   and `NodeOf(I, O).value: ?EntryValueOf(I, O)` maps onto Rust's
   `Option<EntryValue<I, O>>`. Future cross-port work is simpler.

## Hot-path impact

The DFS inner loop (`checkSingle`) dispatches call vs. return via
`arena.matchOf(cursor) != NONE_REF`, which reads only the `match_idx`
field — unchanged by the refactor. The tag on `value` is read only on the
successful-linearization branch, at the `model.step` call site, via
`call_node.value.?.call` / `ret_node.value.?.@"return"`. The `.?` is a
single null check; in `ReleaseFast` it compiles away for the non-sentinel
case. No pointer indirection, no extra heap work.

## Verification

- `zig build test` — full unit + integration suite passes.
- `zig build test -Doptimize=ReleaseFast` — passes.
- `zig build bench -Doptimize=ReleaseFast -- 100 170` — median per-call
  latency on the 170-op register history is ~31 µs both before and after
  the refactor (5 samples each, within ±1% noise).

## Files changed

- `src/checker.zig` — `EntryOf`, `NodeOf`, `makeEntries`, `convertEntries`,
  `NodeArenaOf.fromEntries`, and the call/return access sites in
  `checkSingle`. No other file was touched.
