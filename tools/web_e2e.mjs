// End-to-end tests for the web player at http://localhost:8000.
// Each test loads a cart and exercises one feature. Tests are sequential
// because they share a single browser tab.
//
// Usage:
//   node tools/web_e2e.mjs
//
// Requires the web server to already be running:
//   zig build -Dweb && (cd web && python3 -m http.server 8000)

import puppeteer from 'puppeteer';
import fs from 'node:fs/promises';
import path from 'node:path';

const URL = process.env.PICOZ_WEB_URL || 'http://localhost:8000/';
const CART = process.env.PICOZ_TEST_CART || path.resolve('carts/mansion_bros-10.p8.png');

class TestRunner {
  constructor() { this.results = []; }
  async run(name, fn) {
    const t0 = Date.now();
    try {
      await fn();
      const ms = Date.now() - t0;
      this.results.push({ name, ok: true, ms });
      console.log(`✓ ${name} (${ms}ms)`);
    } catch (e) {
      const ms = Date.now() - t0;
      this.results.push({ name, ok: false, ms, err: e.message });
      console.log(`✗ ${name} (${ms}ms): ${e.message}`);
      if (e.stack) console.log(e.stack.split('\n').slice(0, 4).join('\n'));
    }
  }
  summary() {
    const pass = this.results.filter((r) => r.ok).length;
    const fail = this.results.length - pass;
    console.log(`\n${pass} passed, ${fail} failed (${this.results.length} total)`);
    return fail === 0;
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}

// Capture the canvas's current pixels as a Uint8ClampedArray (length 128*128*4).
async function readCanvas(page) {
  return new Uint8ClampedArray(await page.evaluate(() => {
    const c = document.getElementById('screen');
    const ctx = c.getContext('2d');
    return Array.from(ctx.getImageData(0, 0, 128, 128).data);
  }));
}

function pixelsDiffer(a, b) {
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i += 4) {
    if (a[i] !== b[i] || a[i+1] !== b[i+1] || a[i+2] !== b[i+2]) return true;
  }
  return false;
}

async function loadCart(page, cartPath) {
  const bytes = await fs.readFile(cartPath);
  const arr = Array.from(bytes);
  await page.evaluate(async (arr) => {
    const u8 = new Uint8Array(arr);
    await window.loadCart(u8);
  }, arr);
  await page.waitForFunction(() => {
    const c = document.getElementById('screen');
    return c && getComputedStyle(c).display !== 'none';
  }, { timeout: 10000 });
}

async function main() {
  const runner = new TestRunner();

  // Sanity: server must be up.
  try {
    const r = await fetch(URL);
    if (!r.ok) throw new Error(`server returned ${r.status}`);
  } catch (e) {
    console.error(`Cannot reach ${URL}: ${e.message}`);
    console.error('Start the server first:');
    console.error('  zig build -Dweb && (cd web && python3 -m http.server 8000)');
    process.exit(2);
  }

  const browser = await puppeteer.launch({
    headless: 'new',
    args: ['--no-sandbox', '--mute-audio', '--autoplay-policy=no-user-gesture-required'],
    defaultViewport: { width: 800, height: 800 },
  });
  const page = await browser.newPage();
  page.on('pageerror', (e) => console.error('page error:', e.message));

  try {
    await runner.run('page loads and exposes loadCart()', async () => {
      await page.goto(URL, { waitUntil: 'load', timeout: 10000 });
      // Wait for WASM to initialize
      await page.waitForFunction(() => typeof window.loadCart === 'function' || (window.wasm && typeof window.wasm.web_init === 'function'), { timeout: 15000 });
    });

    await runner.run('cart loads and starts rendering', async () => {
      await loadCart(page, CART);
      // Wait for non-zero pixels (cart is actually rendering)
      await page.waitForFunction(() => {
        const c = document.getElementById('screen');
        const ctx = c.getContext('2d');
        const d = ctx.getImageData(0, 0, 128, 128).data;
        for (let i = 0; i < d.length; i += 4) if (d[i] || d[i+1] || d[i+2]) return true;
        return false;
      }, { timeout: 10000 });
    });

    // Snapshot pixels twice with a delay; cart should be animating, so
    // they should differ.
    await runner.run('cart animates between frames', async () => {
      const a = await readCanvas(page);
      await new Promise((r) => setTimeout(r, 250));
      const b = await readCanvas(page);
      assert(pixelsDiffer(a, b), 'pixels did not change over 250ms — cart not animating');
    });

    // PAUSE: press backtick, wait, verify pixels stop changing
    await runner.run('Backtick pauses (frames freeze)', async () => {
      await page.evaluate(() => document.body.focus());
      await page.keyboard.press('Backquote');
      await new Promise((r) => setTimeout(r, 80));
      const a = await readCanvas(page);
      await new Promise((r) => setTimeout(r, 350));
      const b = await readCanvas(page);
      const stillRunning = pixelsDiffer(a, b);
      if (stillRunning) await page.keyboard.press('Backquote');
      assert(!stillRunning, 'cart kept rendering after backtick — pause not honored');
    });

    await runner.run('Backtick resumes (frames change again)', async () => {
      await page.keyboard.press('Backquote');
      await new Promise((r) => setTimeout(r, 80));
      const a = await readCanvas(page);
      await new Promise((r) => setTimeout(r, 250));
      const b = await readCanvas(page);
      assert(pixelsDiffer(a, b), 'cart did not resume after second backtick press');
    });

    await runner.run('reserved keys do not collide with game inputs', async () => {
      // Static check: pause/save/load keys must not also be in KEY_MAP.
      const conflicts = await page.evaluate(() => {
        const map = window.__pz.KEY_MAP;
        return window.__pz.RESERVED_KEYS.filter((k) => k in map);
      });
      assert(conflicts.length === 0, 'KEY_MAP collision: ' + conflicts.join(', '));

      // Dynamic check: pressing a reserved key never sets game button bits.
      // (Fire each, then read window.__pz.buttons — should still be 0/0.)
      // We need to re-test from a known state — release any stuck keys.
      const beforeBtns = await page.evaluate(() => window.__pz.buttons);
      for (const k of ['Backquote', 'p', 'l']) {
        await page.keyboard.down(k);
        const btns = await page.evaluate(() => window.__pz.buttons);
        await page.keyboard.up(k);
        assert(btns[0] === beforeBtns[0] && btns[1] === beforeBtns[1],
          `pressing ${k} mutated game buttons (${beforeBtns} -> ${btns})`);
      }
      await new Promise((r) => setTimeout(r, 80));
      if (await page.evaluate(() => window.__pz.paused)) {
        await page.keyboard.press('Backquote');
        await new Promise((r) => setTimeout(r, 80));
      }
    });

    // PAUSE under keyboard auto-repeat: a held key fires repeated keydown
    // events with e.repeat=true. These must NOT toggle pause state.
    await runner.run('held backtick (auto-repeat) does not flicker pause', async () => {
      if (await page.evaluate(() => window.__pz.paused)) {
        await page.keyboard.press('Backquote');
        await new Promise((r) => setTimeout(r, 80));
      }
      await page.evaluate(() => new Promise((res) => {
        document.dispatchEvent(new KeyboardEvent('keydown', {
          key: '`', code: 'Backquote', repeat: false, bubbles: true, cancelable: true,
        }));
        setTimeout(() => {
          document.dispatchEvent(new KeyboardEvent('keydown', {
            key: '`', code: 'Backquote', repeat: true, bubbles: true, cancelable: true,
          }));
          res();
        }, 30);
      }));
      await new Promise((r) => setTimeout(r, 80));
      const paused = await page.evaluate(() => window.__pz.paused);
      if (paused) {
        await page.keyboard.press('Backquote');
        await new Promise((r) => setTimeout(r, 80));
      }
      assert(paused, 'auto-repeat flipped pause back off — keydown handler is not guarding against e.repeat');
    });

    // PAUSE indicator: while paused, the small bars should be visible.
    await runner.run('paused overlay draws indicator', async () => {
      await page.keyboard.press('Backquote');
      await new Promise((r) => setTimeout(r, 100));
      const px = await page.evaluate(() => {
        const c = document.getElementById('screen');
        const ctx = c.getContext('2d');
        const id = ctx.getImageData(113, 6, 8, 10);
        // Look for any white pixel from the pause-bar fill
        for (let i = 0; i < id.data.length; i += 4) {
          if (id.data[i] > 240 && id.data[i+1] > 240 && id.data[i+2] > 240) return true;
        }
        return false;
      });
      // resume so we leave the player in a normal state
      await page.keyboard.press('Backquote');
      assert(px, 'pause indicator (white bars at top-right) not found while paused');
    });
  } finally {
    await browser.close();
  }

  process.exit(runner.summary() ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
