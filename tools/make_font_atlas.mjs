// Anomaly Coop: a bitmap font atlas for CGameFont (the engine's UI font): <name>_h<N>.dds + <name>_h<N>.ini per screen height.
//
// Generic: any font file(s), weight and pixel size. The glyphs are drawn by the canvas of a headless Edge (playwright-core
// of the raylink-launcher project), the DDS is written here (A8R8G8B8, one level, no mips, white glyphs with the coverage in
// the alpha: the font shader tints them with the colour of the text). Nothing is downloaded, no package is added.
//
// What the engine reads (CGameFont::Initialize, [symbol_coords]): `height` = the line (cell) height in px, and for each of the
// 256 codes of the single-byte text `NNN = x1, y1, x2, y2`: the glyph cell in the atlas, its width x2 - x1 is also the advance.
// The text of the game is cp1251, so code N is the cp1251 character N (controls and the undefined 0x98 are empty, 0,0,0,0).
// A glyph is drawn 1:1 in screen pixels, so one atlas fits one screen height: a family has a tier per height,
// <name>_h<N> authored for a screen N px high (the engine picks the nearest, see ResolveFontFamily); the size of a tier is the
// size at --ref-height scaled by N / ref-height, which keeps the text the same part of the screen at every resolution.
//
// Usage:
//   node tools/make_font_atlas.mjs --spec tools/menu_fonts.json [--out DIR] [--preview DIR] [--only NAME[,NAME]]
//   node tools/make_font_atlas.mjs --name ui_font_x --font FILE.woff2[=U+RANGE] [--font FILE2.woff2=U+RANGE ...]
//        --weight 600 --size 28 [--ref-height 1080] [--heights 720,1080,1440] [--line-height 1.3] [--pad 2] [--tabular-digits]
//        [--out DIR] [--preview DIR]
// --tabular-digits ("tabularDigits": true in a spec) gives all ten digits the width of the widest, each centred in its cell,
// for numbers that change (a clock). A spec file is {"out", "refHeight", "heights", "fonts": [{"name", "weight", "size",
// "lineHeight", "tabularDigits", "files": [{"path",, relative paths are taken from the repository root. `range` is a CSS unicode-range ("U+0000-00FF,U+0131"):
// with two files of one family (latin + cyrillic) it says which characters each one serves.
// --out defaults to gamedata/textures/ui. --preview writes <name>_h<N>.png (the atlas) and <name>_h<N>_sample.png (text laid
// out exactly as the engine does, from the atlas and the ini).
// A cp1251 character the font does not have is drawn from a system font (--fallback-font, default Arial; the log lists them),
// so every cell of the table has a glyph; --no-fallback refuses instead. Exit code 0 = written, 1 = bad arguments, 2 = a
// character of cp1251 that the font does not have and --no-fallback (nothing is written for that font).
// Check the result with tools/check_font_atlas.py.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire('D:/Projects/ForEverything/raylink-launcher/package.json');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// ---------------------------------------------------------------- arguments
function parseArgs(argv) {
  const o = { fonts: [], font: [], heights: null, refHeight: null, fallback: 'Arial' };
  const need = (i) => {
    if (i + 1 >= argv.length) throw new Error(`${argv[i]} needs a value`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--spec') o.spec = need(i++);
    else if (a === '--out') o.out = need(i++);
    else if (a === '--preview') o.preview = need(i++);
    else if (a === '--only') o.only = need(i++).split(',');
    else if (a === '--name') o.name = need(i++);
    else if (a === '--font') o.font.push(need(i++));
    else if (a === '--weight') o.weight = Number(need(i++));
    else if (a === '--size') o.size = Number(need(i++));
    else if (a === '--ref-height') o.refHeight = Number(need(i++));
    else if (a === '--heights') o.heights = need(i++).split(',').map(Number);
    else if (a === '--line-height') o.lineHeight = Number(need(i++));
    else if (a === '--pad') o.pad = Number(need(i++));
    else if (a === '--tabular-digits') o.tabular = true;
    else if (a === '--fallback-font') o.fallback = need(i++);
    else if (a === '--no-fallback') o.fallback = '';
    else throw new Error(`unknown argument ${a}`);
  }
  return o;
}

function resolvePath(p) {
  return path.isAbsolute(p) ? p : path.resolve(ROOT, p);
}

function jobsFrom(o) {
  const jobs = [];
  let defaults = { refHeight: 1080, heights: [720, 1080, 1440], pad: 2 };
  let out = o.out;
  if (o.spec) {
    const spec = JSON.parse(fs.readFileSync(resolvePath(o.spec), 'utf8'));
    out = out || spec.out;
    defaults = { ...defaults, ...(spec.refHeight && { refHeight: spec.refHeight }), ...(spec.heights && { heights: spec.heights }), ...(spec.pad && { pad: spec.pad }) };
    for (const f of spec.fonts) {
      jobs.push({
        name: f.name,
        weight: f.weight,
        size: f.size,
        lineHeight: f.lineHeight,
        tabular: !!(f.tabularDigits || o.tabular),
        refHeight: f.refHeight || o.refHeight || defaults.refHeight,
        heights: f.heights || o.heights || defaults.heights,
        pad: f.pad || o.pad || defaults.pad,
        files: f.files.map((x) => ({ path: resolvePath(x.path), range: x.range || '' })),
      });
    }
  } else {
    if (!o.name || !o.font.length || !o.weight || !o.size) throw new Error('--name, --font, --weight and --size are required (or --spec)');
    jobs.push({
      name: o.name,
      weight: o.weight,
      size: o.size,
      lineHeight: o.lineHeight,
      tabular: !!o.tabular,
      refHeight: o.refHeight || defaults.refHeight,
      heights: o.heights || defaults.heights,
      pad: o.pad || defaults.pad,
      files: o.font.map((s) => {
        const k = s.lastIndexOf('=U+');
        return k < 0 ? { path: resolvePath(s), range: '' } : { path: resolvePath(s.slice(0, k)), range: s.slice(k + 1) };
      }),
    });
  }
  const only = o.only;
  const list = only ? jobs.filter((j) => only.includes(j.name)) : jobs;
  for (const j of list) {
    if (!/^[A-Za-z0-9_\-.]+$/.test(j.name)) throw new Error(`bad font name ${j.name}`);
    if (!(j.weight >= 100 && j.weight <= 900)) throw new Error(`${j.name}: weight ${j.weight}`);
    if (!(j.size >= 4 && j.size <= 400)) throw new Error(`${j.name}: size ${j.size}`);
    if (!j.heights.length || j.heights.some((h) => !(h >= 100 && h <= 8000))) throw new Error(`${j.name}: heights ${j.heights}`);
    for (const f of j.files) if (!fs.existsSync(f.path)) throw new Error(`${j.name}: no file ${f.path}`);
  }
  return { jobs: list, out: resolvePath(out || 'gamedata/textures/ui') };
}

// cp1251 byte -> the character (null: no character, an empty cell: controls, DEL, 0x98 that cp1251 leaves undefined)
function cp1251Table() {
  const dec = new TextDecoder('windows-1251');
  const t = [];
  for (let i = 0; i < 256; i++) {
    if (i < 32 || i === 127 || i === 0x98) t.push(null);
    else if (i === 0xad) t.push('-'); // the soft hyphen shows as a hyphen in single-byte text, as in the stock fonts
    else t.push(dec.decode(Uint8Array.of(i)));
  }
  return t;
}

// ---------------------------------------------------------------- the page: draws one tier of one font
// Runs in the browser; everything it needs comes in `a`. Returns the atlas as an 8-bit alpha plane (base64), the cells and the
// characters the font does not have.
async function pageRender(a) {
  const family = a.family;
  if (a.load) {
    for (const f of a.files) {
      const bytes = Uint8Array.from(atob(f.b64), (c) => c.charCodeAt(0));
      const face = new FontFace(family, bytes.buffer, { weight: '100 900', unicodeRange: f.range || 'U+0-10FFFF' });
      await face.load();
      document.fonts.add(face);
    }
  }
  const px = a.px;
  const css = `${a.weight} ${px}px "${family}"${a.fallback ? `, ${a.fallback}` : ''}`;
  const mk = (w, h) => {
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    return c;
  };
  const probe = mk(8, 8).getContext('2d');
  probe.font = css;
  probe.textBaseline = 'alphabetic';
  probe.fontKerning = 'none';

  // does the font have the character: the same text in the font and three different system fonts around it
  const side = Math.ceil(px * 2.2);
  const bitmapHash = (ch, fallback) => {
    const c = mk(side, side).getContext('2d', { willReadFrequently: true });
    c.font = `${a.weight} ${px}px "${family}", ${fallback}`;
    c.textBaseline = 'alphabetic';
    c.fillStyle = '#fff';
    c.fillText(ch, Math.round(px * 0.3), Math.round(px * 1.4));
    const d = c.getImageData(0, 0, side, side).data;
    let h = 0x811c9dc5;
    for (let i = 3; i < d.length; i += 4) h = Math.imul(h ^ d[i], 0x01000193) >>> 0;
    return h;
  };
  const fallbacks = ['"Courier New"', '"Times New Roman"', 'Impact'];
  const has = (ch) => {
    const b = fallbacks.map((f) => bitmapHash(ch, f));
    return b[0] === b[1] && b[1] === b[2];
  };

  const cells = [];
  const missing = [];
  let ascent = Math.ceil(probe.measureText('Hg').fontBoundingBoxAscent);
  let descent = Math.ceil(probe.measureText('Hg').fontBoundingBoxDescent);
  for (let code = 0; code < 256; code++) {
    const ch = a.chars[code];
    if (ch === null) {
      cells.push({ code, ch: '', blank: true, w: 0, ox: 0 });
      continue;
    }
    const space = ch === ' ' || ch === '\u00a0';
    if (!space && !has(ch)) missing.push(code);
    const m = probe.measureText(ch);
    const inkL = Math.max(0, m.actualBoundingBoxLeft);
    const inkR = space ? 0 : m.actualBoundingBoxRight;
    ascent = Math.max(ascent, Math.ceil(space ? 0 : m.actualBoundingBoxAscent));
    descent = Math.max(descent, Math.ceil(space ? 0 : m.actualBoundingBoxDescent));
    const ox = Math.ceil(inkL);
    const w = Math.max(1, Math.round(m.width), Math.ceil(ox + inkR));
    cells.push({ code, ch, blank: space, w, ox, adv: m.width, left: m.actualBoundingBoxLeft, right: m.actualBoundingBoxRight });
  }
  if (a.tabular) {
    const digits = cells.filter((c) => c.code >= 48 && c.code <= 57);
    const wide = Math.max(...digits.map((c) => c.w));
    for (const c of digits) {
      c.w = wide;
      c.ox = Math.round((wide - (c.right + c.left)) / 2 + c.left); // the ink centred, whatever the glyph's own bearings
    }
  }
  let H = ascent + descent;
  if (a.lineHeight) {
    const want = Math.round(px * a.lineHeight);
    if (want > H) {
      ascent += Math.floor((want - H) / 2);
      H = want;
    }
  }

  // shelves into a power of two atlas, the smallest area that holds them
  const pad = a.pad;
  const pot = [128, 256, 512, 1024, 2048, 4096];
  const live = cells.filter((c) => c.w > 0 && !c.blank);
  const spaces = cells.filter((c) => c.w > 0 && c.blank);
  const all = live.concat(spaces);
  const candidates = [];
  for (const W of pot) {
    let x = pad;
    let y = pad;
    let ok = true;
    for (const c of all) {
      if (c.w + pad > W - pad) {
        ok = false;
        break;
      }
      if (x + c.w + pad > W) {
        x = pad;
        y += H + pad;
      }
      c.px = x;
      c.py = y;
      x += c.w + pad;
    }
    if (!ok) continue;
    const need = y + H + pad;
    let Ht = 128;
    while (Ht < need) Ht *= 2;
    if (Ht > 4096) continue;
    candidates.push({ W, Ht, pos: all.map((c) => [c.px, c.py]) });
  }
  if (!candidates.length) throw new Error('the glyphs do not fit 4096x4096');
  // the least area; among those within a third of it the squarest (a 128x4096 strip is the same memory but a poor texture)
  const least = Math.min(...candidates.map((c) => c.W * c.Ht));
  const best = candidates
    .filter((c) => c.W * c.Ht <= least * 1.34)
    .sort((x, y) => Math.max(x.W, x.Ht) - Math.max(y.W, y.Ht) || x.W * x.Ht - y.W * y.Ht)[0];
  all.forEach((c, i) => {
    c.px = best.pos[i][0];
    c.py = best.pos[i][1];
  });

  const atlas = mk(best.W, best.Ht);
  const ctx = atlas.getContext('2d', { willReadFrequently: true });
  ctx.font = css;
  ctx.textBaseline = 'alphabetic';
  ctx.fontKerning = 'none';
  ctx.fillStyle = '#fff';
  for (const c of live) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(c.px, c.py, c.w, H);
    ctx.clip();
    ctx.fillText(c.ch, c.px + c.ox, c.py + ascent);
    ctx.restore();
  }
  const rgba = ctx.getImageData(0, 0, best.W, best.Ht).data;
  const alpha = new Uint8Array(best.W * best.Ht);
  for (let i = 0; i < alpha.length; i++) alpha[i] = rgba[i * 4 + 3];
  let bin = '';
  for (let i = 0; i < alpha.length; i += 0x8000) bin += String.fromCharCode.apply(null, alpha.subarray(i, i + 0x8000));

  const out = {
    W: best.W,
    H: best.Ht,
    cell: H,
    ascent,
    px,
    missing,
    alpha: btoa(bin),
    cells: cells.map((c) => ({ code: c.code, w: c.w, x: c.w > 0 ? c.px : 0, y: c.w > 0 ? c.py : 0, adv: c.adv || 0 })),
  };

  if (a.preview) {
    // the atlas on a dark ground, and a sample set the way the engine sets it: cell by cell, the width is the advance
    const bg = mk(best.W, best.Ht);
    const b = bg.getContext('2d');
    b.fillStyle = '#12161b';
    b.fillRect(0, 0, best.W, best.Ht);
    b.drawImage(atlas, 0, 0);
    out.atlasPng = bg.toDataURL('image/png').split(',')[1];

    const lines = a.sample;
    const rows = lines.length;
    const widthOf = (s) => [...s].reduce((n, chr) => n + (out.cells[a.codeOf[chr]]?.w || 0), 0);
    const sw = Math.max(...lines.map(widthOf)) + 40;
    const sh = rows * (H + 6) + 28;
    const sample = mk(sw, sh);
    const s = sample.getContext('2d');
    s.fillStyle = '#12161b';
    s.fillRect(0, 0, sw, sh);
    s.imageSmoothingEnabled = false;
    let yy = 14;
    for (const line of lines) {
      let xx = 20;
      for (const chr of line) {
        const cell = out.cells[a.codeOf[chr]];
        if (!cell || !cell.w) continue;
        if (!(chr === ' ' || chr === '\u00a0')) s.drawImage(atlas, cell.x, cell.y, cell.w, H, xx, yy, cell.w, H);
        xx += cell.w;
      }
      yy += H + 6;
    }
    out.samplePng = sample.toDataURL('image/png').split(',')[1];
  }
  return out;
}

// ---------------------------------------------------------------- files
function ddsArgb(w, h, alpha) {
  const hdr = Buffer.alloc(128);
  hdr.write('DDS ', 0, 'latin1');
  hdr.writeUInt32LE(124, 4);
  hdr.writeUInt32LE(0x100f, 8); // CAPS | HEIGHT | WIDTH | PIXELFORMAT | PITCH
  hdr.writeUInt32LE(h, 12);
  hdr.writeUInt32LE(w, 16);
  hdr.writeUInt32LE(w * 4, 20);
  hdr.writeUInt32LE(1, 28); // one level
  hdr.writeUInt32LE(32, 76); // pixel format: A8R8G8B8
  hdr.writeUInt32LE(0x41, 80); // RGB | ALPHAPIXELS
  hdr.writeUInt32LE(32, 88);
  hdr.writeUInt32LE(0x00ff0000, 92);
  hdr.writeUInt32LE(0x0000ff00, 96);
  hdr.writeUInt32LE(0x000000ff, 100);
  hdr.writeUInt32LE(0xff000000, 104);
  hdr.writeUInt32LE(0x1000, 108); // TEXTURE
  const px = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    px[i * 4] = 255; // B
    px[i * 4 + 1] = 255; // G
    px[i * 4 + 2] = 255; // R
    px[i * 4 + 3] = alpha[i];
  }
  return Buffer.concat([hdr, px]);
}

function iniText(job, tier, r) {
  const L = [];
  L.push(`; Generated by tools/make_font_atlas.mjs: do not edit. Font ${job.name}, tier for a ${tier}px screen: weight ${job.weight}, ${r.px}px.`);
  L.push('; [symbol_coords] is what CGameFont reads: the cell height and, for each cp1251 code, x1, y1, x2, y2 of its cell (the width is the advance).');
  L.push('[atlas]');
  L.push(`width = ${r.W}`);
  L.push(`height = ${r.H}`);
  L.push(`tier = ${tier}`);
  L.push(`size_px = ${r.px}`);
  L.push(`weight = ${job.weight}`);
  if (job.tabular) L.push('tabular_digits = 1');
  L.push('');
  L.push('[symbol_coords]');
  L.push(`height = ${r.cell}`);
  for (const c of r.cells) {
    const n = String(c.code).padStart(3, '0');
    if (!c.w) L.push(`${n} = 0, 0, 0, 0`);
    else L.push(`${n} = ${c.x}, ${c.y}, ${c.x + c.w}, ${c.y + r.cell}`);
  }
  return L.join('\r\n') + '\r\n';
}

// ---------------------------------------------------------------- main
const SAMPLE = [
  'ХРОНИКА И КАРТА  ИГРАТЬ  Откатиться сюда',
  'Хроника: переход на Кордон, 12:30, 04.11.2026 № 7',
  'Съешь ещё этих мягких французских булок, да выпей чаю',
  'The quick brown fox jumps over the lazy dog 0123456789',
  'ЁЙЩЪЫЭЮЯ ёйщъыэюя «кавычки» — тире … ™ € • [ ] { } @ # % &',
];

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { jobs, out } = jobsFrom(args);
  if (!jobs.length) throw new Error('nothing to do');
  fs.mkdirSync(out, { recursive: true });
  if (args.preview) fs.mkdirSync(resolvePath(args.preview), { recursive: true });

  const chars = cp1251Table();
  const codeOf = {};
  chars.forEach((ch, code) => {
    if (ch !== null && !(ch in codeOf)) codeOf[ch] = code;
  });

  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  let exit = 0;
  try {
    for (const [ji, job] of jobs.entries()) {
      const page = await browser.newPage();
      await page.setContent('<!doctype html><meta charset="utf-8"><body></body>');
      const files = job.files.map((f) => ({ b64: fs.readFileSync(f.path).toString('base64'), range: f.range }));
      const family = `F${ji}`;
      for (const tier of job.heights) {
        const px = Math.max(4, Math.round((job.size * tier) / job.refHeight));
        const r = await page.evaluate(pageRender, {
          family,
          files,
          weight: job.weight,
          px,
          chars,
          codeOf,
          pad: job.pad,
          lineHeight: job.lineHeight || 0,
          preview: !!args.preview,
          sample: SAMPLE,
          tabular: !!job.tabular,
          fallback: args.fallback ? `"${args.fallback}"` : '',
          load: tier === job.heights[0],
        });
        const base = `${job.name}_h${tier}`;
        if (r.missing.length) {
          const list = r.missing.map((c) => `${c}(${chars[c]})`).join(' ');
          if (!args.fallback) {
            console.error(`${base}: the font has no glyph for cp1251 ${list}`);
            exit = 2;
            continue;
          }
          console.log(`${base}: not in the font, drawn from ${args.fallback}: ${list}`);
        }
        fs.writeFileSync(path.join(out, `${base}.dds`), ddsArgb(r.W, r.H, Buffer.from(r.alpha, 'base64')));
        fs.writeFileSync(path.join(out, `${base}.ini`), iniText(job, tier, r), 'latin1');
        if (args.preview) {
          fs.writeFileSync(path.join(resolvePath(args.preview), `${base}.png`), Buffer.from(r.atlasPng, 'base64'));
          fs.writeFileSync(path.join(resolvePath(args.preview), `${base}_sample.png`), Buffer.from(r.samplePng, 'base64'));
        }
        console.log(`${base}: ${r.W}x${r.H}, ${px}px, cell ${r.cell}px (ascent ${r.ascent})`);
      }
      await page.close();
    }
  } finally {
    await browser.close();
  }
  process.exit(exit);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
