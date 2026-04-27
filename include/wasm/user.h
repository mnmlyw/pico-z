// User header injected into Lua via -DLUA_USER_H="user.h".
//
// This serves two purposes for the WASM build:
// 1. Forces the bundled lua sources to look for headers in this directory
//    first, so they pick up our shadowed <setjmp.h> instead of zig's
//    bundled wasi-musl one (which #errors when exception_handling is off).
// 2. Overrides Lua's LUAI_THROW/LUAI_TRY to skip setjmp/longjmp entirely,
//    so we don't need the wasm exception-handling proposal at all.
//
// Why: zig 0.16 has a bug where its bundled wasi libc rt.c (the setjmp
// runtime) fails to compile when +exception_handling is enabled, because
// zig doesn't pass `-mllvm -wasm-enable-sjlj` to its own libc build. We
// can't enable exception_handling without breaking the libc build, and
// without exception_handling there's no way to implement real longjmp on
// wasm. This shim accepts the trade: a Lua runtime error in WASM will
// trap the module instead of unwinding through pcall. Cart errors will
// crash the WASM module — the JS host can reload the page to recover.
//
// Remove the LUAI_THROW/LUAI_TRY overrides once zig fixes its libc.

#ifndef LUAI_THROW
#define LUAI_THROW(L, c)  __builtin_trap()
#define LUAI_TRY(L, c, a) do { a } while (0)
#define luai_jmpbuf       int
#endif
