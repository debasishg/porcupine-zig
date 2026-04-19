## Misc Zig idioms used in this project (Learning Notes)

> In file bitset.zig, struct `Bitset`, the 2 functions `data` and `dataMut` have the same body - can this duplication be optimized ?

The bodies look identical but they actually differ in an important way: the **return types** and **self parameter mutability** are different.

- `data` takes `*const Bitset` and returns `[]const u64` (read-only view)
- `dataMut` takes `*Bitset` and returns `[]u64` (mutable view)

This is an intentional Zig pattern for enforcing const-correctness. You could DRY it up by having `data` call `dataMut` via a `@constCast`, but that would actually be worse — it would undermine the const safety guarantees. The current approach is idiomatic Zig.

In Zig there's no `const` generics or method overloading like C++ templates, so providing separate const/mutable accessors with duplicated bodies is the standard way to handle this. The duplication is minimal (3 lines) and keeps the API safe, so it's best left as-is.

> In file bitset.zig, the function `init` has a return type `std.mem.Allocator.Error!Bitset`, which explicitly states the type of error. What would be the pros and cons of using this technique versus returning `!Bitset` and using `errdefer allocator.free(..)` after `allocator.alloc` ? I have seen both patterns used.

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

Your current `init` with `std.mem.Allocator.Error!Bitset` is idiomatic.

> Should I need to add errdefer after alloc (line 41) for safety reasons ?

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
        @memset(self.heap, 0);                     // line 42
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
