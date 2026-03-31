// Stubs for WASM build of Lua
#include "lua.h"
#include "lauxlib.h"

// Lua IO/OS libraries excluded from WASM build
int luaopen_io(lua_State *L) { (void)L; return 0; }
int luaopen_os(lua_State *L) { (void)L; return 0; }

// WASI expects a main symbol
int main(void) { return 0; }
