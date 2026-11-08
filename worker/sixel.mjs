// RGBA (premultiplied, as resvg renders it) -> Sixel. Opaque pixels only (alpha < 128 stays unset, P2 = 1 keeps the terminal
// background there). At most 256 colours: exact when the image has that few, else a 6x6x6 cube.

const MAX_COLORS = 256;

function cube(key) {
  const q = (v) => Math.round(Math.round((v / 255) * 5) * 51);
  return (q((key >> 16) & 255) << 16) | (q((key >> 8) & 255) << 8) | q(key & 255);
}

function rle(chars) {
  let out = "";
  let i = 0;
  // trailing unset columns carry no information
  let end = chars.length;
  while (end > 0 && chars[end - 1] === 63) end--;
  while (i < end) {
    let j = i;
    while (j < end && chars[j] === chars[i]) j++;
    const n = j - i;
    const c = String.fromCharCode(chars[i]);
    out += n > 3 ? `!${n}${c}` : c.repeat(n);
    i = j;
  }
  return out;
}

/**
 * @param {Uint8Array} rgba width*height*4 bytes
 * @param {number} width
 * @param {number} height
 * @returns {string} DCS ... ST
 */
export function encode(rgba, width, height) {
  const head = `\x1bP0;1;q"1;1;${width};${height}`;
  const keys = new Uint32Array(width * height); // 0 = transparent, else 1<<24 | rgb
  const distinct = new Set();
  for (let p = 0; p < width * height; p++) {
    if (rgba[p * 4 + 3] < 128) continue;
    // resvg hands out premultiplied RGBA: undo it so edge pixels keep their colour
    const a = rgba[p * 4 + 3];
    const un = (v) => Math.min(255, Math.round((v * 255) / a));
    const k = (un(rgba[p * 4]) << 16) | (un(rgba[p * 4 + 1]) << 8) | un(rgba[p * 4 + 2]);
    keys[p] = 0x1000000 | k;
    distinct.add(k);
  }
  const reduce = distinct.size > MAX_COLORS;
  const index = new Map(); // rgb -> palette index, in order of first appearance
  const pixel = new Int32Array(width * height).fill(-1);
  for (let p = 0; p < keys.length; p++) {
    if (!keys[p]) continue;
    let k = keys[p] & 0xffffff;
    if (reduce) k = cube(k);
    if (!index.has(k)) index.set(k, index.size);
    pixel[p] = index.get(k);
  }
  let defs = "";
  for (const [k, i] of index) {
    const pc = (v) => Math.round((v * 100) / 255);
    defs += `#${i};2;${pc((k >> 16) & 255)};${pc((k >> 8) & 255)};${pc(k & 255)}`;
  }
  const bands = [];
  for (let y0 = 0; y0 < height; y0 += 6) {
    const rows = new Map(); // colour -> sixel chars per column
    for (let dy = 0; dy < 6 && y0 + dy < height; dy++) {
      for (let x = 0; x < width; x++) {
        const c = pixel[(y0 + dy) * width + x];
        if (c < 0) continue;
        let r = rows.get(c);
        if (!r) rows.set(c, (r = new Uint8Array(width).fill(63)));
        r[x] += 1 << dy;
      }
    }
    bands.push([...rows].map(([c, r]) => `#${c}${rle(r)}`).join("$"));
  }
  // empty bands in the middle still need their '-' (graphics newline); only trailing ones go
  while (bands.length && !bands[bands.length - 1]) bands.pop();
  return head + defs + bands.join("-") + "\x1b\\";
}
