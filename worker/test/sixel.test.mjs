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
