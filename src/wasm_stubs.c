// Stubs for WASM build of Lua
#include "lua.h"
#include "lauxlib.h"

// Lua IO/OS libraries excluded from WASM build
int luaopen_io(lua_State *L) { (void)L; return 0; }
int luaopen_os(lua_State *L) { (void)L; return 0; }

// WASI expects a main symbol
int main(void) { return 0; }

// setjmp/longjmp shim required by zig 0.16's bundled wasi-musl headers.
// Lua never actually calls these (LUAI_TRY/LUAI_THROW are overridden via
// include/wasm/user.h), but ldo.c includes <setjmp.h> unconditionally,
// which forces these declarations to exist. Provide trivial stubs so the
// link succeeds. See include/wasm/setjmp.h for the rationale.
#include <stdint.h>

typedef int jmp_buf[1];
typedef jmp_buf sigjmp_buf;

int setjmp(jmp_buf env) { (void)env; return 0; }
__attribute__((noreturn)) void longjmp(jmp_buf env, int val) {
    (void)env; (void)val;
    __builtin_trap();
}
int _setjmp(jmp_buf env) { return setjmp(env); }
__attribute__((noreturn)) void _longjmp(jmp_buf env, int val) { longjmp(env, val); }

int sigsetjmp(sigjmp_buf env, int savesigs) { (void)env; (void)savesigs; return 0; }
__attribute__((noreturn)) void siglongjmp(sigjmp_buf env, int val) {
    (void)env; (void)val;
    __builtin_trap();
}
