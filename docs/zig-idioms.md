# Zig idioms

## 1. Const correctness

Suppose in a struct the 2 functions `data` and `dataMut` that return a view of the underlying chunk, have the same body - can this duplication be optimized ?

```zig
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
```

The bodies look identical but they actually differ in an important way: the **return types** and **self parameter mutability** are different.

- `data` takes `*const Bitset` and returns `[]const u64` (read-only view)
- `dataMut` takes `*Bitset` and returns `[]u64` (mutable view)

This is an intentional Zig pattern for enforcing const-correctness. You could DRY it up by having `data` call `dataMut` via a `@constCast`, but that would actually be worse - it would undermine the const safety guarantees. The current approach is idiomatic Zig.

In Zig there's no `const` generics or method overloading like C++ templates, so providing separate const/mutable accessors with duplicated bodies is the standard way to handle this. The duplication is minimal (3 lines) and keeps the API safe, so it's best left as-is.

## 2. Explicit versus inferred error type

The following function `init` has a return type `std.mem.Allocator.Error!Bitset`, which explicitly states the type of error.

```zig
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
```

> What would be the pros and cons of using this technique versus returning `!Bitset` and using `errdefer allocator.free(..)` after `allocator.alloc` ? I have seen both patterns used.

### Explicit Error Type: `std.mem.Allocator.Error!Bitset`

**Pros:**

- **API clarity**: Callers know exactly which errors can occur without reading implementation
- **Documentation**: Self-documenting interface—the signature tells the full story
- **Compile-time guarantees**: Prevents accidentally leaking unintended errors up the call stack
- **Error subset enforcement**: If your function should only produce allocation errors, the compiler enforces this
- **Stdlib convention**: Matches idiomatic Zig stdlib patterns, making code consistent

**Cons:**

- **Verbosity**: Longer signatures
- **Rigidity**: Adding a new error type later requires signature changes (though this is often desirable)

### Inferred Error Type: `!Bitset`

**Pros:**

- **Flexibility**: Easier to add new error conditions without changing signatures
- **Brevity**: Shorter function signatures
- **Composition**: When calling multiple fallible functions, errors automatically propagate without explicit union

**Cons:**

- **Opaque API**: Callers must read implementation or docs to know possible errors
- **Error leakage**: Easy to accidentally expose internal errors that shouldn't be part of public API
- **Harder to catch at call site**: `catch |err| switch (err)` becomes harder when error set is unknown

### The `errdefer` question

The `errdefer` pattern is orthogonal to explicit vs. inferred error types—you'd use `errdefer` in either case when you need to clean up partial allocations on failure. For example:

```zig
pub fn init(allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Bitset {
    const foo = try allocator.alloc(u64, n);
    errdefer allocator.free(foo);  // cleanup if bar fails
    const bar = try allocator.alloc(u64, n);
    // ...
}
```

### Recommendation

The stdlib prefers explicit error types because **public APIs benefit from explicit contracts**. Use inferred errors (`!T`) mainly in:

- Private/internal functions
- Prototyping
- Functions where the error set genuinely depends on many composed operations

The above `init` with `std.mem.Allocator.Error!Bitset` is idiomatic.

## 3. errdefer after alloc

> Should I need to add `errdefer` after `alloc` (line 41) for safety reasons ?

Looking at the `init` function:

```zig
pub fn init(allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Bitset {
    const c = std.math.divCeil(usize, n, 64) catch unreachable;
    var self: Bitset = .{
        .inline_buf = @splat(0),
        .heap = &.{},
        .chunks = c,
    };
    if (c > inline_cap) {
        self.heap = try allocator.alloc(u64, c);  // line 41
        @memset(self.heap, 0);                    // line 42
    }
    return self;
}
```

**No, `errdefer` is not needed here** for safety reasons because:

1. After the allocation succeeds on line 41, the only remaining operation is `@memset(self.heap, 0)` which **cannot fail**—it's a built-in that does direct memory writes
2. Then you immediately `return self`, transferring ownership to the caller

`errdefer` is needed when there's a **fallible operation after the allocation** that could trigger early error return. Since `@memset` is infallible, there's no error path that could leak the allocation.

**However**, you might add it defensively:

```zig
if (c > inline_cap) {
    self.heap = try allocator.alloc(u64, c);
    errdefer allocator.free(self.heap);  // defensive: protects future changes
    @memset(self.heap, 0);
}
```

This guards against someone later adding a `try` between allocation and return. It's a style choice—stdlib tends to omit redundant `errdefer` when the code path is obviously safe, but defensive placement is reasonable for maintainability. Current code is correct as-is.

## 4. Distinguishing Handleable Errors vs Bugs

Let's look at this line of code:

```zig
const c = std.math.divCeil(usize, n, 64) catch unreachable;
```

What does `catch unreachable` mean here ?

In Zig, `catch unreachable` means "this error can never happen; if it does, it's a bug in my code."

Looking at the above code:

`std.math.divCeil` returns an error union because it can fail with `error.DivisionByZero` when the divisor is 0. However, here the divisor is the compile-time constant `64`, which is never zero.

**What `catch unreachable` does:**

- In **Debug/ReleaseSafe** builds: triggers a panic with a stack trace if the error actually occurs — useful for catching logic bugs
- In **ReleaseFast/ReleaseSmall** builds: the compiler assumes this path is never taken and optimizes accordingly (undefined behavior if violated)

**Alternatives:**

| Pattern | Meaning |
|---------|---------|
| `catch unreachable` | "This error is logically impossible" |
| `catch \|err\| return err` | Propagate the error |
| `try expr` | Shorthand for `catch \|err\| return err` |
| `catch default_value` | Use a fallback value on error |
| `catch @panic("msg")` | Always panic with custom message |

Here it's the correct choice, dividing by 64 cannot fail, and expressing that with `catch unreachable` documents the invariant while letting the compiler optimize in release builds.

> Is it Zig way to differentiate between errors that can be handled and those that indicate bugs in code and should not be caught ?

Yes, exactly. Zig makes a deliberate distinction between two categories:

### 1. Recoverable Errors → Error Union (`!T`)

Expected failure conditions that callers should handle:

- File not found
- Network timeout
- Out of memory
- Invalid user input

```zig
fn readFile(path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_size);
}
// Caller decides: retry, fallback, propagate, etc.
```

### 2. Bugs/Contract Violations → `unreachable`, `@panic`, assertions

Logic errors that indicate programmer mistakes:

- Invalid invariants
- Impossible states
- Violated preconditions

```zig
// unreachable - "this cannot happen if my code is correct"
const c = std.math.divCeil(usize, n, 64) catch unreachable;

// std.debug.assert - checked in Debug/ReleaseSafe, removed in ReleaseFast
std.debug.assert(index < len);

// @panic - always crashes with message
if (impossible_state) @panic("corrupted internal state");
```

### Why This Matters

| Mechanism | Debug Build | ReleaseFast | Purpose |
|-----------|-------------|-------------|---------|
| `try`/`catch` | Returns error | Returns error | Expected failures |
| `unreachable` | Panic + trace | UB (optimized out) | Impossible paths |
| `std.debug.assert` | Panic + trace | No-op | Debug-only checks |
| `@panic` | Panic | Panic | Always-fatal bugs |

### The Philosophy

Zig rejects the "exceptions for everything" approach. Forcing programmers to think about which category an error belongs to:

- **Recoverable**: Use error unions, let caller decide
- **Bug**: Crash loudly in debug, assume impossible in release

This is why `std.math.divCeil` returns an error (divisor *could* be zero at runtime from user input) rather than just panicking—but when *you* know it's always 64, `catch unreachable` expresses "this is a bug if it happens."

## 5. Handling errors in deinit

Suppose we have this following code for deallocation of a structure:

```zig
pub fn deinit(self: *Bitset, allocator: std.mem.Allocator) void {
    // `allocator.free` on an empty slice is a no-op; no guard needed.
    allocator.free(self.heap);
    self.heap = &.{};
    self.chunks = 0;
}
```

In the above code, why does `deinit` not handle any error ? Can't we have any error within deinit, e.g. in `allocator.free` ?

In Zig's allocator interface, `free` is defined as:

```zig
pub fn free(self: Allocator, memory: anytype) void
```

It returns `void` — not an error union. This is deliberate.

## Why `free` Can't Fail

### What would you do with the error?

`deinit` is typically called during cleanup, often already in an error path:

```zig
fn doWork(allocator: Allocator) !void {
    var bitset = try Bitset.init(allocator, 256);
    defer bitset.deinit(allocator);  // ← What if this fails?
    
    try riskyOperation();  // If this fails, deinit runs in error path
}
```

If `deinit` could fail, you'd have nested error handling—and no good options.

### Deallocation failure = bug, not recoverable error

Valid reasons `free` might "fail":

- Double-free → bug in your code
- Invalid pointer → bug in your code  
- Heap corruption → bug somewhere

These are contract violations (should panic), not recoverable conditions.

### Universal convention

| Language | Deallocation | Returns |
|----------|--------------|---------|
| C | `free()` | `void` |
| C++ | destructors | can't throw (practically) |
| Rust | `Drop::drop()` | `()` |
| Zig | `Allocator.free()` | `void` |

### If cleanup truly needs fallibility

For resources where cleanup *can* meaningfully fail (e.g., flushing a file), Zig uses a separate pattern:

```zig
// Fallible close
pub fn close(self: *File) CloseError!void { ... }

// Infallible deinit for when you don't care about errors
pub fn deinit(self: *File) void {
    self.close() catch {};  // Ignore error
}
```

`deinit` is correct — `allocator.free` is guaranteed infallible by design.

## 6. Zig `@intCast`, Rust `as` and Zig `@as`

Here's a hash function from a `Bitset` struct in Zig:

```zig
pub fn hash(self: *const Bitset) u64 {
    var h: u64 = @intCast(self.popcnt());  // popcnt returns usize
    for (self.data()) |v| h ^= v;           // v is u64
    return h;
}
```

### `usize` vs `u64`

| Type | Definition | On macOS ARM64 | On 32-bit system |
|------|------------|----------------|------------------|
| `u64` | Always 64 bits | 64 bits | 64 bits |
| `usize` | Pointer-sized unsigned int | 64 bits | **32 bits** |

`usize` is the native word size—used for:

- Array indices
- Slice lengths  
- Pointer arithmetic
- Counts of things in memory

`u64` is a fixed-width type—used for:

- Hashes
- Serialization formats
- Cross-platform consistency

### Why `@intCast` is Needed

`popcnt()` returns `usize` (a count/index type), but `hash()` returns `u64` (fixed-width for cross-platform hash consistency).

**Zig requires explicit conversion between integer types**, even when it seems "safe":

```zig
var h: u64 = self.popcnt();  // ERROR: cannot coerce usize to u64
```

On a 64-bit system this would work at runtime, but on a 32-bit system `usize` is 32 bits—Zig refuses implicit widening because:

- It forces you to think about portability
- It makes truncation/overflow explicit

`@intCast` tells the compiler: "I know this value fits in the target type."

```zig
var h: u64 = @intCast(self.popcnt());  // usize → u64, OK
```

Here it's always safe because:

- `usize` ≤ 64 bits (widening or no-op)
- Population count of a bitset is never negative

The hash is `u64` (not `usize`) so it matches Go/Rust implementations and produces identical hashes across 32-bit and 64-bit platforms.

> Difference between `@intCast` in Zig and `as` keyword in Rust to achieve the same effect as above.

In Rust, you use the `as` keyword for integer casts:

```rust
fn hash(&self) -> u64 {
    let mut h: u64 = self.popcnt() as u64;  // usize → u64
    for chunk in self.data() {
        h ^= chunk;
    }
    h
}
```

### Rust `as` vs Zig `@intCast`

| Aspect | Rust `as` | Zig `@intCast` |
|--------|-----------|----------------|
| Syntax | `value as u64` | `@intCast(value)` |
| Truncation | Silent (wraps) | Panic in Debug, UB in ReleaseFast |
| Overflow | Silent | Panic in Debug |
| Sign extension | Implicit rules | Explicit |

### The Key Difference

**Rust `as` is lossy and silent:**

```rust
let big: u64 = 0xFFFF_FFFF_FFFF_FFFF;
let small: u32 = big as u32;  // Silently truncates to 0xFFFF_FFFF
```

**Zig `@intCast` is checked in safe builds:**

```zig
const big: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const small: u32 = @intCast(big);  // PANIC in Debug: integer overflow
```

### Rust's Safe Alternative

Rust has `try_into()` for checked conversions:

```rust
use std::convert::TryInto;

let h: u64 = self.popcnt().try_into().unwrap();  // Panics if doesn't fit
// or
let h: u64 = self.popcnt().try_into()?;  // Returns error
```

But most Rust code uses `as` for `usize → u64` because on 64-bit (the common case) it's a no-op, and on 32-bit it's widening (always safe). The silent truncation issue only matters when going the other direction (`u64 → usize` on 32-bit).

Zig's philosophy is stricter - no implicit or silent lossy conversions, ever.

> But zig also has `@as` - how is that different from (a) `as` in Rust (b) `@intCast` as discussed above.

They're quite different:

### Zig `@as` — Type Coercion (safe only)

`@as(T, value)` performs **type coercion**, not conversion. It only works when the conversion is guaranteed lossless and unambiguous:

```zig
// Works - coercion to a wider type
const x: u32 = 10;
const y = @as(u64, x);  // OK: u32 → u64 always fits

// Works - type disambiguation
const z = @as(f64, 3.14);  // Tell compiler this literal is f64

// FAILS - potentially lossy
const big: u64 = 1000;
const small = @as(u32, big);  // ERROR: cannot coerce u64 to u32
```

### Comparison

| Feature | Zig `@as` | Zig `@intCast` | Rust `as` |
|---------|-----------|----------------|-----------|
| Purpose | Type hint/coercion | Explicit conversion | Both |
| Lossy allowed | **No** | Yes (checked) | Yes (silent) |
| Widening `u32→u64` | ✓ | ✓ | ✓ |
| Narrowing `u64→u32` | ✗ Compile error | ✓ Runtime check | ✓ Silent truncate |
| Comptime known safe | ✓ | ✓ | ✓ |

### When to Use Each in Zig

```zig
// @as - disambiguate types, safe coercions
const arr = [_]u8{ 1, 2, 3 };
const ptr = @as([*]const u8, &arr);  // pointer coercion
const float = @as(f32, 0.5);         // literal type hint

// @intCast - explicit integer conversion (potentially lossy)
const hash: u64 = @intCast(some_usize);  // cross-width
const byte: u8 = @intCast(value & 0xFF); // known to fit
```

### The Key Insight

- **`@as`** = "compiler, treat this as type T" (must be provably safe)
- **`@intCast`** = "convert this integer to type T" (runtime-checked in Debug)
- **Rust `as`** = does both, silently truncates if needed

Zig separates these because silent truncation is a common source of bugs. `@as` refuses lossy conversions at compile time; `@intCast` makes you explicitly opt into them.

## 7. Generics: Functions Returning Types

Consider the following function in Zig:

```zig
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
```

This is a Zig idiom where instead of a `struct` we construct a `fn` that returns the struct as a type. Why not `pub const Operation = struct { .. }` ?

The `fn(...) type` pattern - Zig's generics:

```zig
pub fn Operation(comptime I: type, comptime O: type) type {                                
    return struct { client_id: u64, input: I, output: O, ... };                            
}
```

This is **how you write a generic type in Zig**. Zig has no `Operation<I, O>` syntax. Types are  first-class `comptime` values, and type is itself a type. So a "generic" is just a function  from types to a type, evaluated at compile time.

**Why not `pub const Operation = struct { ... }` ?**

Because a plain `struct` declaration has no way to parameterize `input: I` and `output: O`. The  fields must have concrete types known at that declaration. You'd be forced to pick one — `input: u32` — and every user of the library would be stuck with it.

The function form lets each call site pick its own `I` and `O`:

```zig
const RegOp = Operation(RegInput, i32);   // one struct type                               
const KvOp  = Operation(KvCmd,   KvResp); // a different struct type        
```

Each invocation of `Operation(I, O)` is memoized by Zig: calling it twice with the same arguments returns the same type (identity by comptime args), so `Operation(u32, i64) == Operation(u32, i64)` holds.

### Mental model vs. other languages

| Language | Generic               | What it really is                          |
|----------|-----------------------|--------------------------------------------|
| Rust     | `struct Op<I, O> { }` | Compiler-built parameterized type          |
| C++      | `template<...> ...`   | Compiler-built parameterized type          |
| Zig      | `fn Op(I, O) type`    | A plain comptime function returning a type |

Zig exposes the mechanism instead of hiding it behind syntax. The convention: name such a function in PascalCase (like a type), because semantically it produces one. std does the same — `std.ArrayList(T)`, `std.AutoHashMap(K, V)`, `std.meta.Tuple(...)` are all functions.

### Bonus: what you can do because it's just a function

- Compute types: `fn Pair(comptime T: type) type { return struct { a: T, b: T }; }`
- Specialize methods inside the returned struct — they close over I/O from the enclosing scope, so `pub fn foo(self: @This(), x: I) O` works naturally.
- Declare nested public constants like `pub const InputType = I;` so callers can recover the type parameters: `@TypeOf(op).InputType`.

So `pub fn Operation(...)` type isn't a workaround — it's the canonical Zig idiom for generics, and `pub const Operation = struct { ... }` simply cannot express the same thing.
