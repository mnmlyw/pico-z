// Drive a Lexaloffle BBS PICO-8 cart in headless Chromium and capture the
// inner 128x128 canvas at the same frame numbers a run_cart script asks for.
//
// Usage:
//   node tools/bbs_capture.mjs <bbs-url> <script.txt> [--out <dir>] [--fps 60] [--headed]
//
// Reads only these directives from the script:
//   frames <n>
//   <frame>: press|release|hold p0.<button> [for <n>]
//   <frame>: screenshot <path.bmp>
//   screenshot every <n> to <prefix>
//   <frame>: quit
//
// Everything else (eval/dump/assert) is silently ignored — they're only
// meaningful against our local engine.
//
// Each captured frame is written to <out>/<basename>.png so it can be
// directly compared against our run_cart .bmp output.

import puppeteer from 'puppeteer';
import fs from 'node:fs/promises';
import path from 'node:path';

// PICO-8 BBS reads input from `window.pico8_buttons` — an array indexed by
// player, with a bitmask of currently-pressed buttons.
//   bit 0=left, 1=right, 2=up, 3=down, 4=O, 5=X
const BTN_BIT = { left: 1, right: 2, up: 4, down: 8, o: 16, z: 16, x: 32 };
function btnSpec(spec) {
  const [p, b] = spec.split('.');
  const player = p === 'p0' ? 0 : 1;
  const mask = BTN_BIT[b];
  if (!mask) throw new Error(`unknown button: ${spec}`);
  return { btnIdx: player, btnMask: mask };
}

// Returns list of {btnIdx, btnMask} for buttons that should be held at `frame`
// (any press whose matching release is later than `frame`).
function currentlyHeld(events, frame) {
  const heldKey = new Map();  // key -> last action (true=down, false=up)
  for (const ev of events) {
    if (ev.frame > frame) break;
    if (ev.action === 'press') heldKey.set(`${ev.btnIdx}:${ev.btnMask}`, true);
    else if (ev.action === 'release') heldKey.set(`${ev.btnIdx}:${ev.btnMask}`, false);
  }
  const out = [];
  for (const [k, down] of heldKey) {
    if (down) {
      const [idx, mask] = k.split(':').map(Number);
      out.push({ btnIdx: idx, btnMask: mask });
    }
  }
  return out;
}

function parseArgs(argv) {
  const args = { url: null, script: null, out: 'bbs_runs', fps: 60, headed: false };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--out')    args.out = rest[++i];
    else if (a === '--fps') args.fps = parseInt(rest[++i], 10);
    else if (a === '--headed') args.headed = true;
    else if (!args.url) args.url = a;
    else if (!args.script) args.script = a;
  }
  if (!args.url || !args.script) {
    console.error('usage: node tools/bbs_capture.mjs <bbs-url> <script.txt> [--out dir] [--fps 60] [--headed]');
    process.exit(2);
  }
  return args;
}

async function parseScript(scriptPath) {
  const text = await fs.readFile(scriptPath, 'utf8');
  const events = [];
  let maxFrames = 600;
  let autoEvery = 0, autoPrefix = null;

  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i].trim();
    if (!raw || raw.startsWith('#')) continue;

    let m;
    if ((m = raw.match(/^frames\s+(\d+)$/))) { maxFrames = parseInt(m[1], 10); continue; }
    if ((m = raw.match(/^log\s+/)))                      continue; // local-only
    if ((m = raw.match(/^screenshot\s+every\s+(\d+)\s+to\s+(.+)$/))) {
      autoEvery = parseInt(m[1], 10);
      autoPrefix = m[2].trim();
      continue;
    }

    // <frame>: <command...>
    const colon = raw.indexOf(':');
    if (colon < 0) continue;
    const frame = parseInt(raw.slice(0, colon).trim(), 10);
    const cmd = raw.slice(colon + 1).trim();
    if (Number.isNaN(frame)) continue;

    if ((m = cmd.match(/^press\s+(p[01])\.(\w+)$/))) {
      const b = btnSpec(`${m[1]}.${m[2]}`);
      events.push({ frame, action: 'press', ...b });
    } else if ((m = cmd.match(/^release\s+(p[01])\.(\w+)$/))) {
      const b = btnSpec(`${m[1]}.${m[2]}`);
      events.push({ frame, action: 'release', ...b });
    } else if ((m = cmd.match(/^hold\s+(p[01])\.(\w+)\s+for\s+(\d+)$/))) {
      const b = btnSpec(`${m[1]}.${m[2]}`);
      const dur = parseInt(m[3], 10);
      events.push({ frame, action: 'press', ...b });
      events.push({ frame: frame + dur, action: 'release', ...b });
    } else if ((m = cmd.match(/^screenshot\s+(.+)$/))) {
      events.push({ frame, action: 'screenshot', path: m[1].trim() });
    } else if (cmd === 'quit') {
      events.push({ frame, action: 'quit' });
    }
    // dump / dump globals / dump source / eval / assert — local only
  }

  events.sort((a, b) => a.frame - b.frame);
  return { events, maxFrames, autoEvery, autoPrefix };
}

// Write a 128x128 RGBA pixel buffer to PNG. Uses node's zlib.
async function writePngFromRgba(filePath, rgba, w = 128, h = 128) {
  const zlib = await import('node:zlib');
  const crc = makeCrcTable();

  // PNG signature
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  // IHDR
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;   // bit depth
  ihdr[9] = 6;   // color type RGBA
  ihdr[10] = 0;  // compression
  ihdr[11] = 0;  // filter
  ihdr[12] = 0;  // interlace

  // IDAT: filter byte 0 prepended to each scanline
  const filtered = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    filtered[y * (w * 4 + 1)] = 0;
    rgba.copy(filtered, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const idatData = zlib.deflateSync(filtered);

  const chunks = [
    sig,
    chunk('IHDR', ihdr, crc),
    chunk('IDAT', idatData, crc),
    chunk('IEND', Buffer.alloc(0), crc),
  ];
  await fs.writeFile(filePath, Buffer.concat(chunks));
}

function chunk(type, data, crcTable) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcInput = Buffer.concat([typeBuf, data]);
  const c = crc32(crcInput, crcTable);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(c >>> 0, 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function makeCrcTable() {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
}

function crc32(buf, t) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = t[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

async function main() {
  const args = parseArgs(process.argv);
  const script = await parseScript(args.script);
  await fs.mkdir(args.out, { recursive: true });

  console.log(`launching chromium (headed=${args.headed})`);
  const browser = await puppeteer.launch({
    headless: args.headed ? false : 'new',
    args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio', '--no-sandbox'],
    defaultViewport: { width: 1024, height: 800 },
  });

  try {
    const page = await browser.newPage();
    page.on('console', (msg) => {
      const t = msg.text();
      if (t.includes('p8_')) console.log('  [p8]', t);
    });
    page.on('pageerror', (e) => console.log('  [pageerror]', e.message));

    // Force preserveDrawingBuffer:true on every WebGL context so we can read
    // pixels after frame presentation. PICO-8's player uses WebGL2; without
    // this, getImageData/drawImage return zeros (or garbage) after the GPU
    // swaps buffers.
    await page.evaluateOnNewDocument(() => {
      const orig = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (type, attrs) {
        if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
          attrs = Object.assign({}, attrs || {}, { preserveDrawingBuffer: true });
        }
        return orig.call(this, type, attrs);
      };
    });

    console.log(`navigating to ${args.url}`);
    await page.goto(args.url, { waitUntil: 'load', timeout: 60000 });
    await new Promise((r) => setTimeout(r, 2000));

    // BBS pages don't auto-start the cart — we have to call p8_run_cart()
    // directly. The container div has the right onclick attribute on it; we
    // pull jsUrl/cartId/pngUrl out of that and invoke the same API.
    const cartArgs = await page.evaluate(() => {
      const c = document.getElementById('p8_container');
      if (!c) return null;
      const oc = c.getAttribute('onclick') || '';
      const m = oc.match(/p8_run_cart\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*\)/);
      if (!m) return null;
      return { jsUrl: m[1], cartId: m[2], pngUrl: m[3] };
    });
    if (!cartArgs) throw new Error('could not find p8_run_cart() invocation on page');
    console.log('cart args:', cartArgs);

    await page.evaluate(({ jsUrl, cartId, pngUrl }) => {
      // eslint-disable-next-line no-undef
      p8_create_audio_context();
      // eslint-disable-next-line no-undef
      p8_run_cart(jsUrl, cartId, pngUrl);
    }, cartArgs);

    // Wait for cart canvas to appear at 128x128
    console.log('waiting for cart to boot...');
    await page.waitForFunction(() => {
      const c = document.querySelector('canvas#canvas, canvas.emscripten, canvas');
      return c && c.width === 128 && c.height === 128;
    }, { timeout: 30000, polling: 200 });
    console.log('canvas booted');

    // Wait for cart to actually start drawing (non-trivial pixel content)
    await page.waitForFunction(() => {
      const c = document.querySelector('canvas#canvas, canvas.emscripten, canvas');
      if (!c) return false;
      const off = document.createElement('canvas');
      off.width = 128; off.height = 128;
      const octx = off.getContext('2d');
      octx.drawImage(c, 0, 0);
      const id = octx.getImageData(0, 0, 128, 128);
      let nonzero = 0;
      for (let i = 0; i < id.data.length; i += 4) {
        if (id.data[i] || id.data[i+1] || id.data[i+2]) nonzero++;
      }
      return nonzero > 100; // arbitrary "real content" threshold
    }, { timeout: 30000, polling: 200 });
    console.log('cart is rendering — starting capture');
    // Click the canvas to ensure keyboard focus lands on PICO-8 (so trusted
    // keyboard events reach the SDL listener instead of the page chrome).
    await page.evaluate(() => {
      const c = document.querySelector('canvas');
      if (c) { c.tabIndex = 0; c.focus(); }
    });
    const cBox = await page.evaluate(() => {
      const c = document.querySelector('canvas');
      const r = c.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    });
    if (cBox.x > 0 && cBox.y > 0) {
      await page.mouse.click(cBox.x, cBox.y);
    }
    await new Promise((r) => setTimeout(r, 200));

    // Find the 128x128 canvas. Some PICO-8 BBS players use a WebGL canvas
    // that renders the 128x128 framebuffer scaled — in that case getImageData
    // won't return the right thing. We prefer canvas#canvas but verify it has
    // a usable 2d context.
    const targetIdx = await page.evaluate(() => {
      const cs = Array.from(document.querySelectorAll('canvas'));
      let idx = cs.findIndex((c) => c.width === 128 && c.height === 128);
      if (idx < 0) idx = cs.findIndex((c) => c.width === c.height && c.width <= 256);
      if (idx < 0) idx = 0;
      return idx;
    });
    console.log(`targeting canvas index ${targetIdx} for capture`);

    // Pre-compute when each event/screenshot fires (in ms after t0).
    const fps = args.fps;
    const frameMs = 1000 / fps;

    // Build the unified timeline: input events + screenshot moments.
    const allCaptures = [];
    for (const ev of script.events) {
      if (ev.action === 'screenshot') {
        allCaptures.push({ frame: ev.frame, path: path.basename(ev.path).replace(/\.bmp$/i, '.png') });
      }
    }
    if (script.autoEvery > 0 && script.autoPrefix) {
      for (let f = 0; f < script.maxFrames; f += script.autoEvery) {
        const idx = f / script.autoEvery;
        const name = `${path.basename(script.autoPrefix)}${String(idx).padStart(4, '0')}.png`;
        allCaptures.push({ frame: f, path: name });
      }
    }
    allCaptures.sort((a, b) => a.frame - b.frame);

    const t0 = Date.now();
    let evIdx = 0;
    let capIdx = 0;
    let frame = 0;
    const totalFrames = script.maxFrames;

    console.log(`running ${totalFrames} frames at ${fps}fps; ${script.events.length} events, ${allCaptures.length} captures`);

    while (frame < totalFrames) {
      const targetMs = frame * frameMs;
      const elapsed = Date.now() - t0;
      if (elapsed < targetMs) {
        await new Promise((r) => setTimeout(r, targetMs - elapsed));
      }

      // Fire input events scheduled at this exact frame.
      // We model "press"/"release" by writing directly to window.pico8_buttons
      // (the array PICO-8's cart code reads from). hold pulses are implemented
      // as a press at f, release at f+dur, but additionally we retrigger the
      // bit on subsequent frames during the hold so btnp() reliably sees a
      // transition regardless of where the cart's frame boundary lands.
      while (evIdx < script.events.length && script.events[evIdx].frame === frame) {
        const ev = script.events[evIdx];
        if (ev.action === 'press' || ev.action === 'release') {
          await page.evaluate(({ btnIdx, mask, press }) => {
            if (!window.pico8_buttons) return;
            if (press) window.pico8_buttons[btnIdx] |= mask;
            else       window.pico8_buttons[btnIdx] &= ~mask;
          }, { btnIdx: ev.btnIdx, mask: ev.btnMask, press: ev.action === 'press' });
        } else if (ev.action === 'quit') {
          frame = totalFrames;
        }
        evIdx++;
      }
      // For any "held" button: emit a 6-frame off → 6-frame on cycle inside
      // each 12-frame window. Keeps creating fresh btnp() edges even if our
      // wall-clock cadence drifts relative to the cart's update loop.
      const phase = frame % 12;
      const held = currentlyHeld(script.events, frame);
      if (held.length > 0) {
        const want = phase < 6 ? 'off' : 'on';
        await page.evaluate(({ items, want }) => {
          if (!window.pico8_buttons) return;
          for (const { btnIdx, btnMask } of items) {
            if (want === 'on') window.pico8_buttons[btnIdx] |= btnMask;
            else                window.pico8_buttons[btnIdx] &= ~btnMask;
          }
        }, { items: held, want });
      }

      // Capture screenshots scheduled at this frame
      while (capIdx < allCaptures.length && allCaptures[capIdx].frame === frame) {
        const cap = allCaptures[capIdx];
        const rgba = await page.evaluate((idx) => {
          const c = document.querySelectorAll('canvas')[idx];
          if (!c) return null;
          // Always go via an offscreen 2D canvas so we can read pixels even
          // when the source is WebGL.
          const off = document.createElement('canvas');
          off.width = 128; off.height = 128;
          const octx = off.getContext('2d');
          octx.imageSmoothingEnabled = false;
          octx.drawImage(c, 0, 0, 128, 128);
          const id = octx.getImageData(0, 0, 128, 128);
          return Array.from(id.data);
        }, targetIdx);

        if (rgba) {
          const buf = Buffer.from(rgba);
          const outPath = path.join(args.out, cap.path);
          await writePngFromRgba(outPath, buf, 128, 128);
          console.log(`f${frame}: wrote ${outPath}`);
        } else {
          console.warn(`f${frame}: capture failed (canvas null)`);
        }
        capIdx++;
      }

      frame++;
    }

    console.log(`ran ${frame} frames in ${(Date.now() - t0) / 1000}s`);
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
