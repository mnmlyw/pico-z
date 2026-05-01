// Compare two mono PCM WAVs by RMS over fixed time windows. Resamples
// linearly to a common rate so files captured at different sample rates
// (BBS at 44100/48000, our engine at 22050) can be compared.
//
// Usage:
//   node tools/diff_audio.mjs <ours.wav> <bbs.wav> [--window-ms 100]
//
// Prints, for each window:
//   <t_sec> | ours_rms | bbs_rms | abs_diff | corr
// Then a summary: mean RMS error and average windowed correlation.

import fs from 'node:fs/promises';

function parseArgs(argv) {
  const args = { ours: null, bbs: null, windowMs: 100, dumpAt: null, dumpLen: 200 };
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--window-ms') args.windowMs = parseInt(rest[++i], 10);
    else if (a === '--dump-at') args.dumpAt = parseFloat(rest[++i]);
    else if (a === '--dump-len') args.dumpLen = parseInt(rest[++i], 10);
    else if (!args.ours) args.ours = a;
    else if (!args.bbs) args.bbs = a;
  }
  if (!args.ours || !args.bbs) {
    console.error('usage: node tools/diff_audio.mjs <ours.wav> <bbs.wav> [--window-ms 100] [--dump-at <sec> [--dump-len 200]]');
    process.exit(2);
  }
  return args;
}

// Render an ASCII plot of two signals so we can eyeball waveform shape +
// phase. Each row is one sample; columns scale the amplitude. Both signals
// are overlaid: 'O' for ours-only column, 'B' for bbs-only, '*' for both.
function asciiPlot(a, b, count, width = 60) {
  const halfW = Math.floor(width / 2);
  const lines = [];
  lines.push('  i   |  ours    |  bbs     |  ' + '-'.repeat(halfW) + '0' + '-'.repeat(halfW));
  for (let i = 0; i < count; i++) {
    const va = Math.max(-1, Math.min(1, a[i] || 0));
    const vb = Math.max(-1, Math.min(1, b[i] || 0));
    const xa = halfW + Math.round(va * halfW);
    const xb = halfW + Math.round(vb * halfW);
    const cells = new Array(width + 1).fill(' ');
    cells[halfW] = '|';
    cells[xa] = (cells[xa] === ' ' || cells[xa] === '|') ? 'O' : '*';
    cells[xb] = (cells[xb] === ' ' || cells[xb] === '|') ? 'B' : '*';
    const num = (n) => (n >= 0 ? ' ' : '') + n.toFixed(4);
    lines.push(`${String(i).padStart(4)}  |  ${num(va)}  |  ${num(vb)}  |  ${cells.join('')}`);
  }
  return lines.join('\n');
}

async function readWav(path) {
  const buf = await fs.readFile(path);
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error(`not a WAV: ${path}`);
  }
  // Find fmt and data chunks
  let i = 12;
  let format = 0, channels = 0, sampleRate = 0, bitsPerSample = 0, dataOffset = 0, dataSize = 0;
  while (i < buf.length) {
    const id = buf.toString('ascii', i, i + 4);
    const size = buf.readUInt32LE(i + 4);
    if (id === 'fmt ') {
      format = buf.readUInt16LE(i + 8);
      channels = buf.readUInt16LE(i + 10);
      sampleRate = buf.readUInt32LE(i + 12);
      bitsPerSample = buf.readUInt16LE(i + 22);
    } else if (id === 'data') {
      dataOffset = i + 8;
      dataSize = size;
      break;
    }
    i += 8 + size;
  }
  if (format !== 1) throw new Error(`only PCM supported (got format=${format})`);
  if (bitsPerSample !== 16) throw new Error(`only 16-bit PCM supported (got ${bitsPerSample})`);

  const numSamples = dataSize / 2 / channels;
  const samples = new Float32Array(numSamples);
  for (let n = 0; n < numSamples; n++) {
    // Mix down to mono if needed
    let sum = 0;
    for (let c = 0; c < channels; c++) {
      sum += buf.readInt16LE(dataOffset + (n * channels + c) * 2) / 32768;
    }
    samples[n] = sum / channels;
  }
  return { samples, sampleRate };
}

function resample(samples, fromRate, toRate) {
  if (fromRate === toRate) return samples;
  const outLen = Math.floor((samples.length * toRate) / fromRate);
  const out = new Float32Array(outLen);
  const ratio = fromRate / toRate;
  for (let i = 0; i < outLen; i++) {
    const src = i * ratio;
    const idx = Math.floor(src);
    const frac = src - idx;
    const a = samples[idx] || 0;
    const b = samples[idx + 1] || 0;
    out[i] = a + (b - a) * frac;
  }
  return out;
}

function rms(arr, start, len) {
  let sum = 0;
  for (let i = 0; i < len; i++) {
    const v = arr[start + i] || 0;
    sum += v * v;
  }
  return Math.sqrt(sum / len);
}

function correlation(a, b, start, len) {
  let sa = 0, sb = 0;
  for (let i = 0; i < len; i++) {
    sa += a[start + i] || 0;
    sb += b[start + i] || 0;
  }
  const ma = sa / len, mb = sb / len;
  let num = 0, da = 0, db = 0;
  for (let i = 0; i < len; i++) {
    const va = (a[start + i] || 0) - ma;
    const vb = (b[start + i] || 0) - mb;
    num += va * vb;
    da += va * va;
    db += vb * vb;
  }
  if (da === 0 || db === 0) return 0;
  return num / Math.sqrt(da * db);
}

// Find the lag (in samples) of `b` relative to `a` that maximizes
// correlation. Searches +/- maxLagSec around zero. Uses sub-sampled
// envelopes to keep runtime reasonable on multi-second clips.
function findAlignment(a, b, sampleRate, maxLagSec) {
  const downsample = 50; // 1 envelope sample per 50 raw samples
  const ea = envelope(a, downsample);
  const eb = envelope(b, downsample);
  const maxLagDs = Math.floor((maxLagSec * sampleRate) / downsample);
  const minLagDs = -maxLagDs;
  let bestLag = 0;
  let bestScore = -Infinity;
  for (let lag = minLagDs; lag <= maxLagDs; lag++) {
    let s = 0, n = 0;
    const len = Math.min(ea.length, eb.length);
    for (let i = 0; i < len; i++) {
      const j = i + lag;
      if (j < 0 || j >= eb.length) continue;
      s += ea[i] * eb[j];
      n++;
    }
    const score = n > 0 ? s / n : -Infinity;
    if (score > bestScore) { bestScore = score; bestLag = lag; }
  }
  return bestLag * downsample;
}

function envelope(samples, downsample) {
  const out = new Float32Array(Math.floor(samples.length / downsample));
  for (let i = 0; i < out.length; i++) {
    let sum = 0;
    for (let j = 0; j < downsample; j++) sum += Math.abs(samples[i * downsample + j] || 0);
    out[i] = sum / downsample;
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv);
  const ours = await readWav(args.ours);
  const bbs = await readWav(args.bbs);
  console.log(`ours: ${ours.samples.length} samples @ ${ours.sampleRate} Hz (${(ours.samples.length / ours.sampleRate).toFixed(2)}s)`);
  console.log(`bbs:  ${bbs.samples.length} samples @ ${bbs.sampleRate} Hz (${(bbs.samples.length / bbs.sampleRate).toFixed(2)}s)`);

  // Resample to the lower of the two rates
  const targetRate = Math.min(ours.sampleRate, bbs.sampleRate);
  let a = resample(ours.samples, ours.sampleRate, targetRate);
  let b = resample(bbs.samples, bbs.sampleRate, targetRate);

  // Auto-align: find the lag of b vs a that maximizes envelope
  // correlation. Compensates for differing capture-start times.
  const lag = findAlignment(a, b, targetRate, 2.0);
  console.log(`auto-aligned: bbs lags ours by ${lag} samples (${(lag/targetRate*1000).toFixed(0)}ms)`);
  if (lag > 0) {
    b = b.subarray(lag);
  } else if (lag < 0) {
    a = a.subarray(-lag);
  }

  const len = Math.min(a.length, b.length);
  const winLen = Math.floor((args.windowMs / 1000) * targetRate);

  console.log(`comparing at ${targetRate} Hz, window=${args.windowMs}ms (${winLen} samples)`);
  console.log(' time(s) |  ours_rms |  bbs_rms  |  rms_diff |  corr');
  console.log('-'.repeat(60));

  let totalRmsDiff = 0;
  let totalCorr = 0;
  let nWindows = 0;
  for (let off = 0; off + winLen <= len; off += winLen) {
    const ra = rms(a, off, winLen);
    const rb = rms(b, off, winLen);
    const corr = correlation(a, b, off, winLen);
    const t = (off / targetRate).toFixed(2);
    console.log(`  ${t.padStart(5)}  |  ${ra.toFixed(4)}  |  ${rb.toFixed(4)}  |  ${Math.abs(ra - rb).toFixed(4)}  |  ${corr.toFixed(3)}`);
    totalRmsDiff += Math.abs(ra - rb);
    totalCorr += corr;
    nWindows++;
  }
  console.log('-'.repeat(60));
  console.log(`mean RMS diff: ${(totalRmsDiff / nWindows).toFixed(4)}`);
  console.log(`mean correlation: ${(totalCorr / nWindows).toFixed(3)}`);

  if (args.dumpAt != null) {
    const start = Math.floor(args.dumpAt * targetRate);
    console.log(`\nsample dump @ ${args.dumpAt}s (${start} samples in, ${args.dumpLen} samples wide):`);
    console.log(asciiPlot(a.subarray(start), b.subarray(start), args.dumpLen, 80));
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
