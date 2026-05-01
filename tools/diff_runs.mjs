// Compare two runs frame-by-frame.
//
// Usage:
//   node tools/diff_runs.mjs <ours-dir> <bbs-dir> [--out <diff-dir>] [--match <pattern>]
//
// Pairs files by name across the two directories (after extension normalization:
// .bmp <-> .png are matched). For each pair, computes a per-pixel diff and
// writes a side-by-side composite to <diff-dir>/<name>.diff.png.
//
// Prints a summary: filename, pixels-changed, % match.

import fs from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';

function parseArgs(argv) {
  const args = { ours: null, bbs: null, out: 'diff', match: null };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--out')   args.out = rest[++i];
    else if (a === '--match') args.match = rest[++i];
    else if (!args.ours) args.ours = a;
    else if (!args.bbs)  args.bbs = a;
  }
  if (!args.ours || !args.bbs) {
    console.error('usage: node tools/diff_runs.mjs <ours-dir> <bbs-dir> [--out diff] [--match pattern]');
    process.exit(2);
  }
  return args;
}

// Decode a 24-bit BMP (the format run_cart writes) -> {w,h,rgba}.
async function readBmp(filePath) {
  const buf = await fs.readFile(filePath);
  if (buf[0] !== 0x42 || buf[1] !== 0x4d) throw new Error(`not a BMP: ${filePath}`);
  const dataOffset = buf.readUInt32LE(10);
  const w = buf.readInt32LE(18);
  const h = buf.readInt32LE(22);
  const bpp = buf.readUInt16LE(28);
  if (bpp !== 24) throw new Error(`unsupported BMP bpp=${bpp} for ${filePath}`);
  const stride = ((w * 3 + 3) & ~3);
  const rgba = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    // BMP rows are bottom-up
    const srcRow = dataOffset + (h - 1 - y) * stride;
    for (let x = 0; x < w; x++) {
      const s = srcRow + x * 3;
      const d = (y * w + x) * 4;
      rgba[d + 0] = buf[s + 2]; // R
      rgba[d + 1] = buf[s + 1]; // G
      rgba[d + 2] = buf[s + 0]; // B
      rgba[d + 3] = 255;
    }
  }
  return { w, h, rgba };
}

// Decode a PNG (uses Node's zlib for IDAT inflate; supports 8-bit RGBA only).
async function readPng(filePath) {
  const buf = await fs.readFile(filePath);
  // Validate signature
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  for (let i = 0; i < 8; i++) if (buf[i] !== sig[i]) throw new Error(`bad PNG sig: ${filePath}`);

  let i = 8;
  let w = 0, h = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (i < buf.length) {
    const len = buf.readUInt32BE(i); i += 4;
    const type = buf.toString('ascii', i, i + 4); i += 4;
    const data = buf.subarray(i, i + len); i += len + 4; // skip CRC
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') break;
  }
  if (bitDepth !== 8) throw new Error(`PNG bit depth ${bitDepth} not supported (${filePath})`);
  if (colorType !== 6 && colorType !== 2) throw new Error(`PNG color type ${colorType} not supported (${filePath})`);
  const channels = colorType === 6 ? 4 : 3;
  const inflated = zlib.inflateSync(Buffer.concat(idat));
  const rowBytes = w * channels;
  const rgba = Buffer.alloc(w * h * 4);
  let prev = Buffer.alloc(rowBytes);
  for (let y = 0; y < h; y++) {
    const off = y * (rowBytes + 1);
    const filter = inflated[off];
    const row = Buffer.from(inflated.subarray(off + 1, off + 1 + rowBytes));
    // Apply PNG filter
    if (filter === 0) {
      // None
    } else if (filter === 1) {
      // Sub
      for (let x = channels; x < rowBytes; x++) row[x] = (row[x] + row[x - channels]) & 0xff;
    } else if (filter === 2) {
      // Up
      for (let x = 0; x < rowBytes; x++) row[x] = (row[x] + prev[x]) & 0xff;
    } else if (filter === 3) {
      // Average
      for (let x = 0; x < rowBytes; x++) {
        const left = x >= channels ? row[x - channels] : 0;
        row[x] = (row[x] + Math.floor((left + prev[x]) / 2)) & 0xff;
      }
    } else if (filter === 4) {
      // Paeth
      for (let x = 0; x < rowBytes; x++) {
        const left = x >= channels ? row[x - channels] : 0;
        const up = prev[x];
        const ul = x >= channels ? prev[x - channels] : 0;
        const p = left + up - ul;
        const pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - ul);
        const pred = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : ul);
        row[x] = (row[x] + pred) & 0xff;
      }
    } else throw new Error(`unsupported PNG filter ${filter}`);
    prev = row;

    for (let x = 0; x < w; x++) {
      const s = x * channels;
      const d = (y * w + x) * 4;
      rgba[d + 0] = row[s + 0];
      rgba[d + 1] = row[s + 1];
      rgba[d + 2] = row[s + 2];
      rgba[d + 3] = channels === 4 ? row[s + 3] : 255;
    }
  }
  return { w, h, rgba };
}

async function readImage(filePath) {
  if (filePath.endsWith('.bmp')) return readBmp(filePath);
  if (filePath.endsWith('.png')) return readPng(filePath);
  throw new Error(`unsupported image extension: ${filePath}`);
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
function pngChunk(type, data, t) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data]), t) >>> 0, 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}
async function writePng(filePath, rgba, w, h) {
  const t = makeCrcTable();
  const sig = Buffer.from([137,80,78,71,13,10,26,10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8]=8; ihdr[9]=6; ihdr[10]=0; ihdr[11]=0; ihdr[12]=0;
  const filtered = Buffer.alloc((w*4+1)*h);
  for (let y = 0; y < h; y++) {
    filtered[y*(w*4+1)] = 0;
    rgba.copy(filtered, y*(w*4+1)+1, y*w*4, (y+1)*w*4);
  }
  const idat = zlib.deflateSync(filtered);
  await fs.writeFile(filePath, Buffer.concat([
    sig, pngChunk('IHDR', ihdr, t), pngChunk('IDAT', idat, t), pngChunk('IEND', Buffer.alloc(0), t),
  ]));
}

// Build a 3-panel side-by-side image: [ours | bbs | diff highlight].
function composite(ours, bbs) {
  const w = ours.w, h = ours.h;
  if (bbs.w !== w || bbs.h !== h) throw new Error(`size mismatch: ${w}x${h} vs ${bbs.w}x${bbs.h}`);
  const outW = w * 3 + 4;
  const out = Buffer.alloc(outW * h * 4, 0xff);
  let diffPixels = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const si = (y * w + x) * 4;
      // ours
      let di = (y * outW + x) * 4;
      out[di] = ours.rgba[si]; out[di+1] = ours.rgba[si+1]; out[di+2] = ours.rgba[si+2]; out[di+3] = 255;
      // bbs
      di = (y * outW + (w + 2) + x) * 4;
      out[di] = bbs.rgba[si]; out[di+1] = bbs.rgba[si+1]; out[di+2] = bbs.rgba[si+2]; out[di+3] = 255;
      // diff
      const dr = ours.rgba[si]   - bbs.rgba[si];
      const dg = ours.rgba[si+1] - bbs.rgba[si+1];
      const db = ours.rgba[si+2] - bbs.rgba[si+2];
      const same = dr === 0 && dg === 0 && db === 0;
      if (!same) diffPixels++;
      di = (y * outW + (2 * (w + 2)) + x) * 4;
      if (same) {
        // grey background
        out[di] = 32; out[di+1] = 32; out[di+2] = 32; out[di+3] = 255;
      } else {
        // bright magenta
        out[di] = 255; out[di+1] = 0; out[di+2] = 255; out[di+3] = 255;
      }
    }
  }
  return { w: outW, h, rgba: out, diffPixels };
}

async function main() {
  const args = parseArgs(process.argv);
  await fs.mkdir(args.out, { recursive: true });

  const oursFiles = (await fs.readdir(args.ours)).filter((f) => /\.(bmp|png)$/i.test(f));
  const bbsFiles  = (await fs.readdir(args.bbs)).filter((f) => /\.(bmp|png)$/i.test(f));

  const baseToBbs = new Map();
  for (const f of bbsFiles) baseToBbs.set(f.replace(/\.(bmp|png)$/i, ''), f);

  console.log(`ours: ${oursFiles.length} files | bbs: ${bbsFiles.length} files`);
  console.log(`name                          our_pixels      bbs_pixels      diff%   diff_px`);
  console.log('-'.repeat(80));

  const rows = [];
  for (const f of oursFiles.sort()) {
    if (args.match && !f.includes(args.match)) continue;
    const base = f.replace(/\.(bmp|png)$/i, '');
    const bbsName = baseToBbs.get(base);
    if (!bbsName) {
      console.log(`${base.padEnd(30)} (no BBS counterpart)`);
      continue;
    }
    const ours = await readImage(path.join(args.ours, f));
    const bbs = await readImage(path.join(args.bbs, bbsName));
    if (ours.w !== bbs.w || ours.h !== bbs.h) {
      console.log(`${base.padEnd(30)} size mismatch: ${ours.w}x${ours.h} vs ${bbs.w}x${bbs.h}`);
      continue;
    }
    const c = composite(ours, bbs);
    const total = ours.w * ours.h;
    const pct = (c.diffPixels / total) * 100;
    const outPath = path.join(args.out, `${base}.diff.png`);
    await writePng(outPath, c.rgba, c.w, c.h);
    rows.push({ base, total, diffPixels: c.diffPixels, pct });
    console.log(`${base.padEnd(30)} ${String(total).padEnd(15)} ${String(total).padEnd(15)} ${pct.toFixed(1).padStart(5)}%  ${c.diffPixels}`);
  }
  console.log('-'.repeat(80));
  if (rows.length) {
    const avg = rows.reduce((a, r) => a + r.pct, 0) / rows.length;
    console.log(`mean divergence: ${avg.toFixed(2)}% across ${rows.length} frames`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
