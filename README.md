# PICO-Z

An alternative way to play [PICO-8](https://www.lexaloffle.com/pico-8.php) games on multiple platforms. Loads `.p8` and `.p8.png` carts using ziglua (Lua 5.2) + SDL3, implemented in Zig.

> **Note:** PICO-Z is a runtime/player only — it does not replace PICO-8's editor, splore, or game creation tools. You still need PICO-8 to make games.

## Build & Run

Requires Zig 0.15+.

```bash
zig build                      # build only
zig build run -- <cart>        # build and run a .p8 or .p8.png cart
```

## Features

- **Cart loading** — `.p8` text format and `.p8.png` image format (PNG decoding, steganographic extraction, old and PXA decompression)
- **Preprocessor** — transforms PICO-8 Lua syntax (short-if, compound assignment, `!=`, peek shortcuts, binary literals, bitwise ops) to standard Lua 5.2
- **Graphics** — pset, line, rect, circ, oval, spr, sspr, map, tline, print, pal, fillp, clip, camera
- **Audio** — 4-channel waveform synthesis (8 waveforms + custom instruments), SFX effects (slide, vibrato, drop, fade, arpeggio), music pattern sequencing
- **Input** — keyboard + gamepad via SDL3, btn/btnp with repeat
- **Memory** — flat 65536-byte RAM matching PICO-8 layout (sprites, map, SFX, draw state, screen)
- **Quick Save/Load** — press **P** to save state, **L** to load; saves full game state (RAM, audio, Lua globals) to `<cart>.sav` — not available in standard PICO-8

## Status

Tested primarily with [Celeste](https://www.lexaloffle.com/bbs/?tid=2145). Other carts may have undiscovered bugs — feel free to open issues.
