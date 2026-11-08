import { test } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../sixel.mjs";

function img(w, h, fn) {
  const a = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) a.set(fn(x, y), (y * w + x) * 4);
  return a;
}

test("two columns red and blue", () => {
  const s = encode(img(2, 6, (x) => (x === 0 ? [255, 0, 0, 255] : [0, 0, 255, 255])), 2, 6);
  assert.ok(s.startsWith("\x1bP"));
  assert.ok(s.endsWith("\x1b\\"));
  assert.ok(s.includes("#0;2;100;0;0"));
  assert.ok(s.includes("#1;2;0;0;100"));
  // red: all six bits in column 0 -> '~' ; blue in column 1 -> '?~'
  assert.ok(s.includes("#0~"));
  assert.ok(s.includes("#1?~"));
});

test("fully transparent input has an empty raster", () => {
  const s = encode(img(4, 6, () => [0, 0, 0, 0]), 4, 6);
  assert.equal(s, '\x1bP0;1;q"1;1;4;6\x1b\\');
});

test("more than 256 colours are quantised to at most 256", () => {
  const w = 32, h = 32;
  const s = encode(img(w, h, (x, y) => [x * 8, y * 8, (x * y) % 256, 255]), w, h);
  const defs = s.match(/#\d+;2;/g) || [];
  assert.ok(defs.length > 1 && defs.length <= 256, `colours: ${defs.length}`);
});

test("runs longer than three are run-length coded and bands separated by '-'", () => {
  const s = encode(img(10, 12, () => [0, 255, 0, 255]), 10, 12);
  assert.ok(s.includes("#0!10~-#0!10~"), s);
});

test("a blank band in the middle keeps the rows below in place", () => {
  const w = 2, h = 13;
  const px = img(w, h, (x, y) => (y === 12 ? [0, 0, 0, 255] : [0, 0, 0, 0]));
  assert.deepEqual([...decode(encode(px, w, h)).px], [...px]);
});

test("premultiplied input is un-premultiplied", () => {
  const s = encode(img(1, 1, () => [153, 0, 0, 153]), 1, 1);
  assert.ok(s.includes("#0;2;100;0;0"), s);
});

// Minimal Sixel decoder (spec: DCS params q, "raster, #colour defs, data, ! repeat, $ CR, - LF)
// used to check the encoder end to end: pixels in == pixels out.
function decode(s) {
  const m = /^\x1bP[\d;]*q"1;1;(\d+);(\d+)([\s\S]*)\x1b\\$/.exec(s);
  assert.ok(m, "DCS header");
  const w = +m[1], h = +m[2];
  const out = new Uint8Array(w * h * 4); // transparent
  const pal = [];
  let cur = 0, x = 0, band = 0, i = 0;
  const body = m[3];
  const put = (bits, n) => {
    for (let r = 0; r < n; r++, x++)
      for (let b = 0; b < 6; b++)
        if (bits & (1 << b) && x < w && band * 6 + b < h) out.set([...pal[cur], 255], ((band * 6 + b) * w + x) * 4);
  };
  while (i < body.length) {
    const c = body[i];
    if (c === "#") {
      const d = /^#(\d+)(?:;2;(\d+);(\d+);(\d+))?/.exec(body.slice(i));
      cur = +d[1];
      if (d[2] !== undefined) pal[cur] = [d[2], d[3], d[4]].map((v) => Math.round((+v * 255) / 100));
      i += d[0].length;
    } else if (c === "!") {
      const d = /^!(\d+)(.)/.exec(body.slice(i));
      put(d[2].charCodeAt(0) - 63, +d[1]);
      i += d[0].length;
    } else if (c === "$") { x = 0; i++; }
    else if (c === "-") { x = 0; band++; i++; }
    else { put(c.charCodeAt(0) - 63, 1); i++; }
  }
  return { w, h, px: out };
}

test("round trip: decoded pixels equal the input (transparency, bands, runs)", () => {
  const w = 9, h = 14;
  const px = img(w, h, (x, y) => {
    if ((x + y) % 5 === 0) return [0, 0, 0, 0];
    return x < 4 ? [255, 0, 0, 255] : y < 7 ? [0, 0, 255, 255] : [0, 255, 0, 255];
  });
  const back = decode(encode(px, w, h));
  assert.equal(back.w, w);
  assert.equal(back.h, h);
  assert.deepEqual([...back.px], [...px]);
});
