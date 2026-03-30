# PICO-8 Technical Reference

Reference for implementing a PICO-8 emulator. Primary source: official PICO-8 manual v0.2.7 (2025). Secondary: pico-8.fandom.com wiki.

## Memory Map (0x0000-0xFFFF)

| Address | Size | Contents |
|---------|------|----------|
| 0x0000-0x0FFF | 4096 | Sprite sheet (sprites 0-127) |
| 0x1000-0x1FFF | 4096 | Sprite sheet (sprites 128-255) / Map rows 32-63 (shared) |
| 0x2000-0x2FFF | 4096 | Map rows 0-31 |
| 0x3000-0x30FF | 256 | Sprite flags (1 byte per sprite, 8 bits each) |
| 0x3100-0x31FF | 256 | Music patterns (64 patterns, 4 bytes each) |
| 0x3200-0x42FF | 4352 | SFX (64 slots, 68 bytes each) |
| 0x4300-0x55FF | 4864 | General use / work RAM |
| 0x5600-0x5DFF | 2048 | General use / custom font |
| 0x5E00-0x5EFF | 256 | Persistent cart data (64 fixed-point numbers) |
| 0x5F00-0x5F3F | 64 | Draw state |
| 0x5F40-0x5F7F | 64 | Hardware state |
| 0x5F80-0x5FFF | 128 | GPIO pins |
| 0x6000-0x7FFF | 8192 | Screen (128x128, 4bpp, 2 pixels/byte, low nibble = left) |
| 0x8000-0xFFFF | 32768 | General use / extended sprites / extended map |

## Draw State (0x5F00-0x5F3F)

| Address | Size | Description |
|---------|------|-------------|
| 0x5F00-0x5F0F | 16 | Draw palette LUT (remap at draw time) |
| 0x5F10-0x5F1F | 16 | Screen palette LUT (remap at display time; 128-143 = extended colors) |
| 0x5F20 | 1 | Clip rect x_begin |
| 0x5F21 | 1 | Clip rect y_begin |
| 0x5F22 | 1 | Clip rect x_end |
| 0x5F23 | 1 | Clip rect y_end |
| 0x5F24 | 1 | Newline X position (set by cursor()) |
| 0x5F25 | 1 | Pen color. Bits 0-3: primary. Bits 4-7: secondary (fill pattern) |
| 0x5F26 | 1 | Print cursor X |
| 0x5F27 | 1 | Print cursor Y |
| 0x5F28-0x5F29 | 2 | Camera X (16-bit signed LE) |
| 0x5F2A-0x5F2B | 2 | Camera Y (16-bit signed LE) |
| 0x5F2C | 1 | Screen mode (see below) |
| 0x5F2D | 1 | Devkit flags: bit 0=enable, bit 1=mouse as btn, bit 2=pointer lock |
| 0x5F2E | 1 | Persistence flags (bits select which state survives reset) |
| 0x5F31-0x5F32 | 2 | Fill pattern (16-bit LE) |
| 0x5F33 | 1 | Fill pattern attrs: bit 0=transparency, bit 1=sprite fill, bit 2=global sprite fill |
| 0x5F34 | 1 | Advanced color mode (bit 0=observe pattern bits, bit 1=inversion) |
| 0x5F35 | 1 | Line endpoint validity |
| 0x5F36 | 1 | Chipset features (see below) |
| 0x5F37 | 1 | tline precision / disable auto-reload |
| 0x5F38-0x5F39 | 2 | tline map width/height masks |
| 0x5F3A-0x5F3B | 2 | tline map X/Y offsets (tiles) |
| 0x5F3C-0x5F3F | 4 | Previous line endpoint (x16, y16 signed LE) |

### 0x5F2C Screen Modes

| Value | Effect |
|-------|--------|
| 0 | Normal 128x128 |
| 1 | Horizontal stretch (64x128) |
| 2 | Vertical stretch (128x64) |
| 3 | Both stretch (64x64) |
| 5 | Horizontal mirror |
| 6 | Vertical mirror |
| 7 | Both mirror |
| 129 | Horizontal flip |
| 130 | Vertical flip |
| 131 | Both flip |
| 133 | CW 90-degree rotation |
| 135 | CCW 90-degree rotation |

### 0x5F36 Chipset Feature Bits

| Bit | Effect |
|-----|--------|
| 1 | Circle diameter +1 when radius frac >= 0.5 |
| 2 | Disable auto-newline after print() |
| 3 | Render sprite 0 in map()/tline() |
| 4 | Interpret 0x5F59-5F5B as OOB defaults for sget/mget/pget |
| 5 | Disable dampen filter for PCM |
| 6 | Disable print() auto-scroll |
| 7 | Enable auto-wrap for print() |

## Hardware State (0x5F40-0x5F7F)

| Address | Size | Description |
|---------|------|-------------|
| 0x5F40 | 1 | Audio: per-channel clock/pitch halving (bit N=clock, bit N+4=pitch) |
| 0x5F41 | 1 | Audio: reverb (bit N=reverb-1, bit N+4=reverb-2) |
| 0x5F42 | 1 | Audio: bitcrush/distortion |
| 0x5F43 | 1 | Audio: dampen (bit N=dampen-1, bit N+4=dampen-2) |
| 0x5F44-0x5F4B | 8 | RNG state |
| 0x5F4C-0x5F53 | 8 | Button states for 8 players (1 byte each, bits 0-5 = buttons) |
| 0x5F54 | 1 | GFX source remap (0x00=sprites, 0x60=screen) |
| 0x5F55 | 1 | Screen target remap (0x60=screen, 0x00=sprites) |
| 0x5F56 | 1 | Map source remap (0x20=default; upper 8 bits of base addr) |
| 0x5F57 | 1 | Map width (0=256; RAM default 0; effective default 128) |
| 0x5F58-0x5F5B | 4 | Default print attrs / OOB return values (when 0x5F36 bit 4 set) |
| 0x5F5C | 1 | btnp() initial repeat delay (1/30s; 0=default 15; 255=disabled) |
| 0x5F5D | 1 | btnp() repeat interval (1/30s; 0=default 4) |
| 0x5F5E | 1 | Bitplane write/read mask: bits 0-3=write, bits 4-7=read |

## SFX Format (68 bytes per slot)

### In-memory layout (PICO-8 native / .p8.png)
First 64 bytes = 32 notes (2 bytes each LE), last 4 bytes = header.
Our engine rearranges to header-first on load (see cart.zig SFX rearrangement).

### Note encoding (16-bit LE)
```
byte0: [pitch 5:0] [waveform 1:0 << 6]
byte1: [waveform bit2] [volume 2:0 << 1] [effect 2:0 << 4] [custom << 7]
```
- Pitch: 0-63 (C-0 to D#-5)
- Waveform: 0-7 (0=tri, 1=tilted_saw, 2=saw, 3=square, 4=pulse, 5=organ, 6=noise, 7=phaser)
- Volume: 0-7
- Effect: 0-7 (0=none, 1=slide, 2=vibrato, 3=drop, 4=fade_in, 5=fade_out, 6=arp_fast, 7=arp_slow)
- Custom: 1 = use waveform field as child SFX instrument ID (0-7)

### Header (4 bytes at offset +64)
- +64: Editor/flags byte
- +65: Speed (note duration in 183-sample units at 22050 Hz; ~120.49 Hz tick rate)
- +66: Loop start (0-31)
- +67: Loop end (0-31; 0 = no loop)

### .p8 text format vs memory
- .p8 text: `EESSLLLL` header (8 hex chars) + 32 notes x 5 hex chars = 168 chars/line
- Note hex: `d0 d1 d2 d3 d4` where pitch=(d0<<4|d1), waveform=(d2&7), custom=(d2>>3), volume=d3, effect=d4
- .p8.png: notes first (64B) then header (4B) -- opposite of our engine (header first)

## Music Format (4 bytes per pattern)

One byte per channel:
- Bits 0-5: SFX ID (0-63)
- Bit 6: channel disabled
- Bit 7 on byte 0: loop_start flag
- Bit 7 on byte 1: loop_back flag
- Bit 7 on byte 2: stop flag

## Audio

- Sample rate: 22050 Hz
- Channels: 4
- Note tick rate: ~120.49 Hz (183 samples per note at speed 1)
- Waveforms: triangle, tilted_saw, sawtooth, square, pulse, organ, noise, phaser
- Effects: none, slide, vibrato, drop, fade_in, fade_out, arp_fast(4x), arp_slow(8x)
- Custom instruments: waveform field 0-7 indexes SFX 0-7 as child instrument
- sfx(-1): stop channel (all if channel<0)
- sfx(-2): release loop (channel plays to end instead of looping)

## API Quick Reference

### Graphics
```
cls([col])                              -- clear screen, reset clip
pset(x,y,[col])  pget(x,y)             -- pixel
sget(x,y)  sset(x,y,[col])             -- sprite sheet pixel
fget(n,[f])  fset(n,[f],val)            -- sprite flags
circ(x,y,r,[col])  circfill(...)       -- circle
oval(x0,y0,x1,y1,[col])  ovalfill(...) -- ellipse in bounding box
line(x0,y0,[x1,y1,[col]])              -- line with persistent endpoint
rect(x0,y0,x1,y1,[col])  rectfill(...) -- rectangle
rrect(x,y,w,h,r,[col])  rrectfill(...) -- rounded rect (w,h=size, NOT x1,y1)
spr(n,x,y,[w,h],[flip_x],[flip_y])     -- draw sprite
sspr(sx,sy,sw,sh,dx,dy,[dw,dh],[fx,fy])-- stretch sprite
map(tx,ty,[sx,sy],[tw,th],[layers])     -- draw map
tline(x0,y0,x1,y1,mx,my,[mdx,mdy],[layers]) -- textured line
print(str,[x,y,[col]]) / print(str,[col])    -- text; returns right-x
cursor(x,y,[col])  color([col])         -- cursor/color; return prev
camera([x,y])  clip([x,y,w,h,[prev]])  -- viewport; return prev
pal([c0,c1,[p]]) / pal(tbl,[p]) / pal()-- palette; p: 0=draw,1=display,2=secondary
palt([c,t]) / palt(bitfield) / palt()  -- transparency
fillp([p])                              -- fill pattern
```

### Math
```
max(x,y)  min(x,y)  mid(x,y,z)
flr(x)  ceil(x)  abs(x)  sqrt(x)
sin(x)  cos(x)              -- x in turns (0-1); sin is INVERTED
atan2(dx,dy)                 -- returns turns (0-1)
sgn(x)                       -- sgn(0) returns 1
rnd([x])                     -- 0<=n<x; rnd(tbl) = random element
srand(x)
```

### Bitwise (all operate on 16:16 fixed-point)
```
band(x,y)  bor(x,y)  bxor(x,y)  bnot(x)
shl(x,n)  shr(x,n)  lshr(x,n)  rotl(x,n)  rotr(x,n)
```

### Memory
```
peek(addr,[n])  poke(addr,val,...)       -- 8-bit (n values, max 8192)
peek2(addr)  poke2(addr,val)             -- 16-bit LE
peek4(addr)  poke4(addr,val)             -- 32-bit LE (16:16 fixed-point)
memcpy(dest,src,len)  memset(dest,val,len)
reload(dest,src,len,[filename])          -- ROM to RAM
cstore(dest,src,len,[filename])          -- RAM to ROM
```

### Input
```
btn([b],[pl])                -- b: 0=L 1=R 2=U 3=D 4=O 5=X; no args=bitfield
btnp([b],[pl])               -- just pressed + repeat (0x5F5C/5D configurable)
```

### Audio
```
sfx(n,[channel],[offset],[length])  -- n: 0-63, -1=stop, -2=release
music(n,[fade_ms],[channel_mask])   -- n: 0-63, -1=stop
```

### Strings
```
sub(str,pos0,[pos1])  chr(val,...)  ord(str,[i],[n])
tostr(val,[flags])  tonum(val,[flags])  split(str,[sep],[convert])
type(val)
```

### Tables
```
add(tbl,val,[i])  del(tbl,val)  deli(tbl,[i])  count(tbl,[val])
all(tbl)  foreach(tbl,func)  pack(...)  unpack(tbl,[i],[j])
```

### Cart Data
```
cartdata(id)  dget(idx)  dset(idx,val)  -- idx: 0-63
```

### System
```
time() / t()                 -- frame-counted seconds since start
stat(n)                      -- system query (see stat table)
flip()                       -- present frame
printh(str,[file],[overwrite])
load(file,[breadcrumb],[params])  run([params])  stop([msg])  reset()
menuitem(idx,[label],[callback])  extcmd(cmd,[p1],[p2])
```

## stat() IDs

| ID | Type | Description |
|----|------|-------------|
| 0 | number | Memory usage (KB, 0-2048) |
| 1 | number | CPU usage (0.0-1.0+) |
| 4 | string | Clipboard contents |
| 5 | number | PICO-8 version |
| 6 | string | Parameter string from load()/run() |
| 7 | number | Current FPS |
| 8 | number | Target FPS (30 or 60) |
| 28 | bool | Key state by SDL scancode (takes arg) |
| 30 | bool | Key event available |
| 31 | string | Key character (consume after stat(30)) |
| 32-33 | number | Mouse X, Y |
| 34 | number | Mouse buttons (0x1=L, 0x2=R, 0x4=M) |
| 36 | number | Mouse wheel (1=up, -1=down) |
| 46-49 | number | SFX index on channels 0-3 (-1=none) |
| 50-53 | number | Note number on channels 0-3 |
| 54 | number | Current music pattern |
| 55 | number | Patterns played since music() |
| 56 | number | Ticks on current pattern |
| 57 | bool | Music playing |
| 80-85 | number | UTC: year, month, day, hour, min, sec |
| 90-95 | number | Local: year, month, day, hour, min, sec |
| 100 | string | Breadcrumb label from load() |
| 110 | number | Frame-by-frame debug mode |

## P8SCII Control Codes

### Byte codes 0x00-0x0F (official manual v0.2.7)

| Byte | Escape | Params | Description |
|------|--------|--------|-------------|
| 0x00 | \0 | 0 | Terminate string |
| 0x01 | \* | 1+1 | Repeat next char P0 times |
| 0x02 | \# | 1 hex | Draw solid background with color P0 |
| 0x03 | \- | 1 | Shift cursor horizontally by P0-16 pixels |
| 0x04 | \| | 1 | Shift cursor vertically by P0-16 pixels |
| 0x05 | \+ | 2 | Shift cursor by (P0-16, P1-16) pixels |
| 0x06 | \^ | varies | Special command (see subcommands) |
| 0x07 | \a | varies | Play audio |
| 0x08 | \b | 0 | Backspace |
| 0x09 | \t | 0 | Tab (next stop) |
| 0x0A | \n | 0 | Newline |
| 0x0B | \v | 2 | Decorate previous char |
| 0x0C | \f | 1 hex | Set foreground color (0-f) |
| 0x0D | \r | 0 | Carriage return |
| 0x0E | \014 | 0 | Switch to custom font (0x5600) |
| 0x0F | \015 | 0 | Switch to default font |

Parameter encoding: '0'-'f' = 0-15, 'g' = 16, etc. (superset hex)

### \^ Subcommands

| Cmd | Params | Description |
|-----|--------|-------------|
| 1-9 | 0 | Skip 1,2,4,8,...,256 frames |
| d | 1 | Delay N frames per character |
| c | 1 hex | Clear screen to color, reset cursor |
| g | 0 | Go to home position |
| h | 0 | Set home to current position |
| j | 2 | Jump to absolute (x,y) in char units x4 |
| s | 1 | Set tab stop width |
| r | 1 | Set right border (P0 x 4 pixels) |
| x | 1 | Set character width |
| y | 1 | Set character height |
| w | 0 | Toggle wide (2x width) |
| t | 0 | Toggle tall (2x height) |
| = | 0 | Toggle stripey |
| p | 0 | Toggle pinball (wide+tall+stripey) |
| i | 0 | Toggle inverted |
| b | 0 | Toggle bordered (default on) |
| # | 0 | Toggle solid background |
| -X | 0 | Disable mode X |

## PICO-8 Lua Dialect

### Operators not in Lua 5.2
| Syntax | Equivalent |
|--------|-----------|
| `!=` | `~=` |
| `a \ b` | `flr(a/b)` |
| `@expr` | `peek(expr)` |
| `%expr` | `peek2(expr)` (when not preceded by value char) |
| `$expr` | `peek4(expr)` |
| `&` | `band()` |
| `\|` | `bor()` |
| `^^` | `bxor()` |
| `~` (unary) | `bnot()` |
| `<<` | `shl()` |
| `>>` | `shr()` (arithmetic) |
| `>>>` | `lshr()` (logical) |
| `<<>` | `rotl()` |
| `>><` | `rotr()` |

### Compound assignment
`+=`, `-=`, `*=`, `/=`, `\=`, `%=`, `^=`, `..=`, `&=`, `|=`, `^^=`, `<<=`, `>>=`, `>>>=`

### Short-if
`if (cond) stmt` expands to `if cond then stmt end` (parens required)

### Print shorthand
`?expr` on its own line = `print(expr)`

### Number system
- 16:16 fixed-point (emulated with f64)
- Range: -32768.0 to ~32767.99998
- Binary literals: `0b1010`
- Hex with fraction: `0x11.4000` = 17.25
- String indexing: `str[i]` returns character at position i

### Blocked globals
`io`, `os`, `debug`, `package`, `require`, `module`, `dofile`, `loadfile`, `load`, `collectgarbage`, `coroutine` (replaced by cocreate/coresume/costatus/yield), `math` (replaced by individual functions)

### Available
`setmetatable`, `getmetatable`, `rawget`, `rawset`, `rawequal`, `rawlen`, `select`, `pcall`, `tostring`, `tonumber`, `string.*`, `table.*`, `pairs` (nil-tolerant), `ipairs` (nil-tolerant), `type` (no-args returns nil)

## .p8 File Format

### Header
```
pico-8 cartridge // http://www.pico-8.com
version <N>
```

### Sections
| Section | Encoding | Lines | Chars/line |
|---------|----------|-------|------------|
| `__lua__` | UTF-8 text | varies | varies |
| `__gfx__` | hex nibbles (1 char = 1 pixel) | 128 | 128 |
| `__gff__` | hex bytes (2 chars = 1 sprite flag) | 2 | 256 |
| `__map__` | hex bytes (2 chars = 1 tile) | 32 | 256 |
| `__sfx__` | 8 header hex + 32x5 note hex | 64 | 168 |
| `__music__` | 2 flag hex + 4x2 channel hex | 64 | 10 |

### SFX text note: 5 hex digits `d0 d1 d2 d3 d4`
- pitch = (d0<<4) | d1
- waveform = d2 & 7
- custom = d2 >> 3
- volume = d3
- effect = d4

## .p8.png Format

### Steganographic encoding
- 160x205 PNG, RGBA
- `byte = (A&3)<<6 | (R&3)<<4 | (G&3)<<2 | (B&3)`
- Data layout mirrors memory map: sprites, map, flags, music, sfx, then compressed Lua

### Old compression (magic: `:c:\x00`)
- 2-byte uncompressed size (LE), 2-byte padding
- 59-char lookup: `\n 0123456789abcdefghijklmnopqrstuvwxyz!#%(){}[]<>+=/*:;.,~_`
- 0x00 = literal escape, 0x01-0x3B = lookup, 0x3C+ = back-reference (offset+count)

### PXA compression (magic: `\x00pxa`)
- 2-byte uncompressed size, 2-byte compressed size
- Bitstream: bit=1 for MTF literal (unary-coded index), bit=0 for back-reference
- Back-ref: 2 control bits select offset width (5/10/15 bits), then variable-length count

## PICO-8 Quirks

- `sgn(0)` returns 1, not 0
- `sin`/`cos` use turns (0-1), not radians; `sin` is inverted for screen-space
- `cls()` resets clip rect to full screen
- `pal()` with no args also resets `fillp`
- `print()` returns rightmost x pixel position
- `camera()`/`clip()`/`color()` return previous values
- `line(x1,y1)` draws from last endpoint; `line()` resets
- `sfx(-2)` releases loop (doesn't mutate RAM)
- Map tile 0 skipped by default; enable with `poke(0x5F36, 0x8)`
- `poke4`/`peek4` convert between f64 and 16:16 fixed-point via i32 bitcast
- `tostr(val, 0x2)` shifts left 16, shows as integer
- `tonum(str, 0x1)` reads hex without prefix; `tonum(str, 0x4)` returns 0 on failure
- `foreach` silently stops on callback error (matches PICO-8)
- `time()` is frame-counted, not wall-clock
- Division by zero returns 0x7FFF.FFFF (not inf/error)
- Arpeggio speeds halved when SFX speed <= 8 (fast=2, slow=4 instead of 4, 8)
- `circ`/`circfill` with negative radius: not drawn
- `rrect`/`rrectfill` take (x, y, w, h, r) — w,h are size, not x1,y1
