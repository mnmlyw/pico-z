// Override for the broken setjmp.h in zig 0.16's bundled wasi libc.
//
// Zig 0.16's wasi libc setjmp implementation requires `+exception_handling`
// AND the LLVM `-mllvm -wasm-enable-sjlj` flag. When zig auto-builds wasi
// libc.a, it does not pass that LLVM flag to its own `setjmp/wasm32/rt.c`,
// so the libc compilation fails before Lua is even built. This header
// shadows the system one and forwards to our own implementation in
// src/wasm_setjmp.c, which uses inline asm to declare the wasm exception
// tag explicitly so that it compiles without the LLVM flag.
//
// Remove once zig fixes its libc rt.c compilation.

#ifndef _PICO_Z_SETJMP_H
#define _PICO_Z_SETJMP_H

typedef struct {
    void *func_invocation_id;
    unsigned int label;
    struct { void *env; int val; } arg;
} jmp_buf[1];

typedef jmp_buf sigjmp_buf;

#define _setjmp setjmp
#define _longjmp longjmp

int setjmp(jmp_buf env) __attribute__((returns_twice));
__attribute__((noreturn)) void longjmp(jmp_buf env, int val);

int sigsetjmp(sigjmp_buf env, int savesigs) __attribute__((returns_twice));
__attribute__((noreturn)) void siglongjmp(sigjmp_buf env, int val);

#endif
