# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build                      # build native app
zig build run -- <cart>.p8     # build and run a cart
zig build test                 # run all tests
zig build -Dweb                # build WASM module to web/
bash build.sh v0.2.0           # cross-compile release zips to dist/
```

Requires Zig 0.16+. Do not auto-launch the app — only build unless explicitly asked to run.

## Architecture

PICO-8 emulator: preprocessor transforms PICO-8 Lua dialect → standard Lua 5.2, executed via ziglua, with SDL3 for rendering/audio/input.

**Core loop** (`main.zig`): SDL event polling → `input.update()` → `callUpdate()` → `callDraw()` → `renderToARGB()` → SDL present. Frame timing at 30 or 60fps based on `_update60` presence.

**Lua API pattern**: All PICO-8 API functions use the upvalue closure pattern — `pushLightUserdata(pico)` + `pushClosure`. Retrieve state with `getPico(lua)` from upvalue index 1. Registered in `api.registerAll()`.

**Memory model**: Flat `[65536]u8` RAM matching PICO-8 layout. Screen at 0x6000 (4bpp, 2 pixels/byte, low nibble = left pixel). Sprites at 0x0000, map at 0x2000 (rows 32-63 shared with sprite sheet at 0x1000). Draw state at 0x5F00-0x5F7F. ROM is a separate `[65536]u8` for `reload()`/`cstore()`.

**Cart loading** (`cart.zig`): Parses `.p8` text format (section-based) and `.p8.png` (steganographic extraction from PNG RGBA pixels, old compression and PXA decompression). SFX memory layout differs between .p8 format and engine — must rearrange header/notes after memcpy.

**Preprocessor** (`preprocessor.zig`): Line-by-line transformation. Short-if/while expansion runs first, then character-by-character processing for operators (`!=`→`~=`, `^^`→`bxor()`, `>>`→`shr()`, etc.), compound assignment (`+=`, `^=`, `^^=`), peek shortcuts (`@`→`peek()`, `%`→`peek2()`, `$`→`peek4()`), integer division (`\`→`flr()`), binary literals, and `?` print shorthand.

**Audio** (`audio.zig`): 4-channel synthesis at 22050 Hz. SDL callback fills samples in 4096-chunk loop. Music fade separates `music_mix`/`sfx_mix` so SFX aren't affected. Custom instruments use child SFX with retrigger on pitch change. `sfx(-2)` sets per-channel `loop_released` flag (doesn't mutate RAM).

**Save states** (`save_state.zig`): Serializes full RAM + full ROM + audio channels/music state + input + pico fields + Lua globals (via Lua serializer script). Staged loading with rollback on failure. Version field must match exactly.

**Cart switching** (`main.zig:loadCart`): Flushes cartdata → saves old memory → swaps in new memory/ROM → clears cartdata ID → resets audio/RNG/timing → resets VM (without replaying old source) → loads new cart Lua → calls `_init`. On failure: cold-restarts old cart from ROM.

## Key Dependencies

- **ziglua** (Lua 5.2): Must compile with `.optimize = .ReleaseFast` — Lua's C hash functions use intentional integer wrapping that Zig's Debug safety traps.
- **SDL3** via castholm: SDL3 API (not SDL2). `SDL_Init` returns bool. Events use `SDL_EVENT_*` constants. Audio uses `SDL_OpenAudioDeviceStream` with callback.

## Testing

Tests are in `src/tests.zig`. Helpers: `makeTestPico()` creates headless state, `initTestLuaEngine(pico, source)` sets up Lua with source code, `runLua(lua, code)` executes code, `evalLuaNumber(lua, code)` returns a number. Tests run against real Lua VM with full API registered. Lua code in tests must use standard Lua 5.2 syntax (no `0b` binary literals, no PICO-8 `!=` — those require the preprocessor).

## PICO-8 Quirks

- `sgn(0)` returns 1, not 0
- `sin`/`cos` use turns (0–1), not radians; `sin` is inverted for screen-space
- Numbers are conceptually 16:16 fixed-point (emulated with f64); bitwise ops convert via `toFixed`/`fromFixed`
- `cls()` resets clip rect; `pal()` with no args also resets `fillp`
- `print()` returns rightmost x pixel; `camera()`/`clip()`/`color()` return previous values
- `poke4`/`peek4` convert between f64 and 16:16 fixed-point via i32 bitcast
- Map tile 0 is skipped by default in `map()`/`tline()`; controlled by `poke(0x5F36, 0x8)`
