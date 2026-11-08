import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, mkdtempSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const here = dirname(fileURLToPath(import.meta.url));
const dir = mkdtempSync(join(tmpdir(), "inkmath-w-"));
let proc;
let buf = "";
const waiting = new Map();
let seq = 0;

before(() => {
  proc = spawn(process.execPath, [join(here, "..", "mathjax.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
  proc.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      const r = JSON.parse(line);
      waiting.get(r.id)?.(r);
      waiting.delete(r.id);
    }
  });
});

after(() => {
  proc.stdin.end();
  proc.kill();
  rmSync(dir, { recursive: true, force: true });
});

function req(o) {
  const id = ++seq;
  const out = join(dir, `${id}.png`);
  const msg = {
    id, display: false, macros: {}, color: "#c0caf5", cell_w: 10, cell_h: 20,
    container_px: 0, x_height: 0.45, baseline: 0.78, scale: 1, out, ...o,
  };
  return new Promise((res) => {
    waiting.set(id, (r) => res({ r, out }));
    proc.stdin.write(JSON.stringify(msg) + "\n");
  });
}

const png = (p) => PNG.sync.read(readFileSync(p));

test("inline x", async () => {
  const { r, out } = await req({ tex: "x" });
  assert.equal(r.ok, true);
  assert.equal(r.rows, 1);
  assert.ok(r.cols >= 1);
  const p = png(out);
  assert.equal(p.width, r.cols * 10);
  assert.equal(p.height, 20);
});

test("inline tall frac fits one row", async () => {
  const { r, out } = await req({ tex: "\\frac{a}{b}" });
  assert.equal(r.ok, true);
  assert.equal(r.rows, 1);
  assert.equal(png(out).height, 20);
});

test("display align multi row", async () => {
  const { r, out } = await req({
    tex: "\\begin{aligned}a&=b\\\\c&=d\\end{aligned}", display: true, container_px: 800,
  });
  assert.equal(r.ok, true);
  assert.ok(r.rows >= 2);
  assert.equal(r.cols, 80);
  const p = png(out);
  assert.equal(p.height, r.rows * 20);
  assert.equal(p.width, 800);
});

test("tagged equation", async () => {
  const { r } = await req({ tex: "\\begin{equation}a\\end{equation}", display: true, container_px: 800 });
  assert.equal(r.ok, true);
  assert.equal(r.cols, 80);
});

test("ratio", async () => {
  const a = await req({ tex: "\\frac{a}{b}" });
  assert.ok(a.r.ratio > 1, `ratio ${a.r.ratio}`);
  const b = await req({ tex: "x" });
  assert.ok(b.r.ratio < 1, `ratio ${b.r.ratio}`);
});

test("macros applied", async () => {
  const { r } = await req({ tex: "\\R", macros: { R: "\\mathbb{R}" } });
  assert.equal(r.ok, true);
});

test("error", async () => {
  const { r } = await req({ tex: "\\frac{" });
  assert.equal(r.ok, false);
  assert.ok(r.error && r.error.length > 0);
});

test("undefined macro is an error", async () => {
  const { r } = await req({ tex: "\\mycustom{x}" });
  assert.equal(r.ok, false);
  assert.ok(r.error && r.error.length > 0);
});

test("color", async () => {
  const { out } = await req({ tex: "x" });
  const p = png(out);
  let best = -1, rgb = null;
  for (let i = 0; i < p.data.length; i += 4) {
    if (p.data[i + 3] > best) { best = p.data[i + 3]; rgb = [p.data[i], p.data[i + 1], p.data[i + 2]]; }
  }
  const want = [0xc0, 0xca, 0xf5];
  for (let k = 0; k < 3; k++) assert.ok(Math.abs(rgb[k] - want[k]) <= 8, `rgb ${rgb}`);
});

test("survives bad json", async () => {
  proc.stdin.write("garbage\n");
  const { r } = await req({ tex: "x" });
  assert.equal(r.ok, true);
});

test("repeated labels do not clash", async () => {
  const tex = "\\begin{equation}a\\label{k}\\end{equation}";
  const a = await req({ tex, display: true, container_px: 800 });
  const b = await req({ tex, display: true, container_px: 800 });
  assert.equal(a.r.ok, true);
  assert.equal(b.r.ok, true, b.r.error);
});

test("equation numbering does not drift", async () => {
  const tex = "\\begin{equation}a\\end{equation}";
  const a = await req({ tex, display: true, container_px: 800 });
  const b = await req({ tex, display: true, container_px: 800 });
  assert.ok(readFileSync(a.out).equals(readFileSync(b.out)));
});

test("survives non-object json and bad fields", async () => {
  proc.stdin.write("null\n");
  proc.stdin.write("42\n");
  const bad = await req({ tex: 5 });
  assert.equal(bad.r.ok, false);
  const bad2 = await req({ tex: "x", cell_h: 0 });
  assert.equal(bad2.r.ok, false);
  const { r } = await req({ tex: "x" });
  assert.equal(r.ok, true);
});

test("the PNG is written atomically: no temp files remain, same path twice is fine", async () => {
  const out = join(dir, "shared.png");
  const [a, b] = await Promise.all([req({ tex: "s^2", out }), req({ tex: "s^2", out })]);
  assert.equal(a.r.ok, true);
  assert.equal(b.r.ok, true);
  assert.equal(png(out).height, 20);
  const bad = await req({ tex: "x", out: join(dir, "shared.png", "x.png") }); // parent is a file
  assert.equal(bad.r.ok, false);
  assert.deepEqual(readdirSync(dir).filter((f) => f.includes(".tmp.")), []);
});

// final review #3: the cache directory may be deleted (:InkMath clear-cache) while a
// request is queued; the worker creates it again instead of failing with ENOENT
test("writes into a directory deleted meanwhile", async () => {
  const sub = join(dir, "gone", "deeper");
  const { r } = await req({ tex: "y", out: join(sub, "y.png") });
  assert.equal(r.ok, true, r.error);
  assert.equal(png(join(sub, "y.png")).width, r.cols * 10);
});
