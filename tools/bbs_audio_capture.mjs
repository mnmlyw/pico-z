// Capture audio output from a Lexaloffle BBS PICO-8 cart by tapping the
// AudioContext's ScriptProcessorNode samples and dumping them as a WAV.
//
// Usage:
//   node tools/bbs_audio_capture.mjs <bbs-url> <script.txt> --out <path.wav>
//
// We replay the same script-format (frames, holds, screenshots, etc.) so
// timing aligns with run_cart's audio output. Screenshots are ignored here.
//
// Capture works by patching AudioContext.prototype.createScriptProcessor on
// page load: when PICO-8 creates its synth processor, we wrap the user's
// onaudioprocess setter so each output buffer is also copied into a global
// Float32Array we can read out of the page at the end of the run.

import puppeteer from 'puppeteer';
import fs from 'node:fs/promises';

function parseArgs(argv) {
  const args = { url: null, script: null, out: 'bbs.wav', headed: false };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--out') args.out = rest[++i];
    else if (a === '--headed') args.headed = true;
    else if (!args.url) args.url = a;
    else if (!args.script) args.script = a;
  }
  if (!args.url || !args.script) {
    console.error('usage: node tools/bbs_audio_capture.mjs <bbs-url> <script.txt> --out file.wav');
    process.exit(2);
  }
  return args;
}

const BTN_BIT = { left: 1, right: 2, up: 4, down: 8, o: 16, z: 16, x: 32 };
function btnSpec(spec) {
  const [p, b] = spec.split('.');
  const player = p === 'p0' ? 0 : 1;
  const mask = BTN_BIT[b];
  if (!mask) throw new Error(`unknown button: ${spec}`);
  return { btnIdx: player, btnMask: mask };
}

async function parseScript(scriptPath) {
  const text = await fs.readFile(scriptPath, 'utf8');
  const events = [];
  let maxFrames = 600;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    let m;
    if ((m = line.match(/^frames\s+(\d+)$/))) { maxFrames = parseInt(m[1], 10); continue; }
    const colon = line.indexOf(':');
    if (colon < 0) continue;
    const frame = parseInt(line.slice(0, colon).trim(), 10);
    const cmd = line.slice(colon + 1).trim();
    if (Number.isNaN(frame)) continue;
    if ((m = cmd.match(/^press\s+(p[01])\.(\w+)$/))) {
      events.push({ frame, action: 'press', ...btnSpec(`${m[1]}.${m[2]}`) });
    } else if ((m = cmd.match(/^release\s+(p[01])\.(\w+)$/))) {
      events.push({ frame, action: 'release', ...btnSpec(`${m[1]}.${m[2]}`) });
    } else if ((m = cmd.match(/^hold\s+(p[01])\.(\w+)\s+for\s+(\d+)$/))) {
      const b = btnSpec(`${m[1]}.${m[2]}`);
      const dur = parseInt(m[3], 10);
      events.push({ frame, action: 'press', ...b });
      events.push({ frame: frame + dur, action: 'release', ...b });
    } else if (cmd === 'quit') {
      events.push({ frame, action: 'quit' });
    }
    // ignore screenshot/eval/etc — visual capture is a separate tool
  }
  events.sort((a, b) => a.frame - b.frame);
  return { events, maxFrames };
}

function currentlyHeld(events, frame) {
  const m = new Map();
  for (const ev of events) {
    if (ev.frame > frame) break;
    if (ev.action === 'press') m.set(`${ev.btnIdx}:${ev.btnMask}`, true);
    else if (ev.action === 'release') m.set(`${ev.btnIdx}:${ev.btnMask}`, false);
  }
  const out = [];
  for (const [k, down] of m) {
    if (down) {
      const [idx, mask] = k.split(':').map(Number);
      out.push({ btnIdx: idx, btnMask: mask });
    }
  }
  return out;
}

function writeWav(path, samples, sampleRate) {
  const numSamples = samples.length;
  const byteRate = sampleRate * 2;
  const dataSize = numSamples * 2;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(byteRate, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < numSamples; i++) {
    const v = Math.max(-1, Math.min(1, samples[i])) * 32767;
    buf.writeInt16LE(v | 0, 44 + i * 2);
  }
  return fs.writeFile(path, buf);
}

async function main() {
  const args = parseArgs(process.argv);
  const script = await parseScript(args.script);

  const browser = await puppeteer.launch({
    headless: args.headed ? false : 'new',
    args: ['--autoplay-policy=no-user-gesture-required', '--no-sandbox'],
    defaultViewport: { width: 1024, height: 800 },
  });

  try {
    const page = await browser.newPage();
    page.on('console', (msg) => {
      const t = msg.text();
      if (t.startsWith('[pz_audio]')) console.log('  ' + t);
    });

    // Patch AudioContext to tap any ScriptProcessorNode the cart creates.
    // We accumulate samples into window.__pz_audio.samples, and record the
    // sampleRate on first connect.
    await page.evaluateOnNewDocument(() => {
      window.__pz_audio = { samples: [], rate: 0 };
      const origCSP = AudioContext.prototype.createScriptProcessor;
      AudioContext.prototype.createScriptProcessor = function (...a) {
        const node = origCSP.apply(this, a);
        const ctx = this;
        let userHandler = null;
        // The cart's code does node.onaudioprocess = fn. We override the
        // setter so we can copy each output buffer alongside calling the
        // user's handler.
        Object.defineProperty(node, 'onaudioprocess', {
          configurable: true,
          enumerable: true,
          get() { return userHandler; },
          set(fn) {
            userHandler = fn;
            const wrapped = function (e) {
              fn.call(this, e);
              if (window.__pz_audio.rate === 0) {
                window.__pz_audio.rate = ctx.sampleRate;
                console.log(`[pz_audio] capturing at ${ctx.sampleRate} Hz`);
              }
              const out = e.outputBuffer.getChannelData(0);
              const arr = window.__pz_audio.samples;
              for (let i = 0; i < out.length; i++) arr.push(out[i]);
            };
            // call origCSP's setter via prototype (avoid recursion)
            HTMLMediaElement; // no-op to make linter happy
            // Re-assign through the underlying property by deleting + setting
            Object.getOwnPropertyDescriptor(
              Object.getPrototypeOf(node),
              'onaudioprocess'
            ).set.call(node, wrapped);
          },
        });
        return node;
      };
    });

    console.log(`navigating to ${args.url}`);
    await page.goto(args.url, { waitUntil: 'load', timeout: 60000 });
    await new Promise((r) => setTimeout(r, 2000));

    const cartArgs = await page.evaluate(() => {
      const c = document.getElementById('p8_container');
      const oc = c.getAttribute('onclick') || '';
      const m = oc.match(/p8_run_cart\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*\)/);
      return m ? { jsUrl: m[1], cartId: m[2], pngUrl: m[3] } : null;
    });
    if (!cartArgs) throw new Error('could not find p8_run_cart() invocation');
    console.log('cart args:', cartArgs);

    await page.evaluate(({ jsUrl, cartId, pngUrl }) => {
      // eslint-disable-next-line no-undef
      p8_create_audio_context();
      // eslint-disable-next-line no-undef
      p8_run_cart(jsUrl, cartId, pngUrl);
    }, cartArgs);

    await page.waitForFunction(() => {
      const c = document.querySelector('canvas');
      return c && c.width === 128 && c.height === 128;
    }, { timeout: 30000 });
    console.log('canvas booted');

    // Wait until the cart starts producing audio (some samples captured).
    await page.waitForFunction(
      () => window.__pz_audio.samples.length > 0,
      { timeout: 30000, polling: 100 }
    );
    console.log('audio capture started');

    // Reset capture buffer so we begin counting at frame 0 of the script.
    await page.evaluate(() => { window.__pz_audio.samples = []; });

    const fps = 60;
    const frameMs = 1000 / fps;
    const totalFrames = script.maxFrames;
    const t0 = Date.now();
    let evIdx = 0;
    let frame = 0;
    while (frame < totalFrames) {
      const targetMs = frame * frameMs;
      const elapsed = Date.now() - t0;
      if (elapsed < targetMs) await new Promise((r) => setTimeout(r, targetMs - elapsed));

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
      // Re-pulse held buttons (matches bbs_capture.mjs)
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
      frame++;
    }

    console.log(`captured ${frame} frames`);
    const { samples, rate } = await page.evaluate(() => ({
      samples: Array.from(window.__pz_audio.samples),
      rate: window.__pz_audio.rate,
    }));
    if (samples.length === 0) throw new Error('no audio samples captured (cart may be silent)');

    await writeWav(args.out, samples, rate);
    console.log(`wrote ${args.out} (${samples.length} samples @ ${rate} Hz, ${(samples.length / rate).toFixed(2)}s)`);
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
