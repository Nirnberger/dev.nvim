// inkmath MathJax worker: newline-delimited JSON requests on stdin, one JSON response per
// request on stdout. Renders TeX -> SVG (MathJax) -> PNG (resvg) sized to a whole cell grid.
import { createInterface } from "node:readline";
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { mathjax } from "mathjax-full/js/mathjax.js";
import { TeX } from "mathjax-full/js/input/tex.js";
import { SVG } from "mathjax-full/js/output/svg.js";
import { liteAdaptor } from "mathjax-full/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "mathjax-full/js/handlers/html.js";
import { AllPackages } from "mathjax-full/js/input/tex/AllPackages.js";
import { Resvg } from "@resvg/resvg-js";
import { encode } from "./sixel.mjs";

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);

// noundefined/noerrors would turn undefined macros and TeX errors into red text; we want
// them to fail so the plugin can fall back to tectonic.
const PACKAGES = AllPackages.filter((p) => p !== "noundefined" && p !== "noerrors");

const documents = new Map();
function documentFor(macros) {
  const k = JSON.stringify(macros || {});
  let doc = documents.get(k);
  if (!doc) {
    if (documents.size >= 16) documents.clear();
    const tex = new TeX({
      packages: PACKAGES,
      tags: "ams",
      macros: macros || {},
      formatError: (_jax, err) => {
        throw err;
      },
    });
    doc = mathjax.document("", { InputJax: tex, OutputJax: new SVG({ fontCache: "none" }) });
    documents.set(k, doc);
  }
  return doc;
}

function render(req) {
  for (const k of ["cell_w", "cell_h", "x_height"]) {
    if (!(typeof req[k] === "number" && req[k] > 0)) throw new Error(`invalid ${k}`);
  }
  if (typeof req.tex !== "string") throw new Error("invalid tex");
  if (typeof req.out !== "string") throw new Error("invalid out");
  const { tex, display, macros, color, cell_w, cell_h, container_px, x_height, baseline, scale, out } = req;
  const pxEx = x_height * cell_h * scale;
  const doc = documentFor(macros);
  doc.inputJax[0].reset(); // clear labels / equation numbering from previous requests
  doc.clear();
  const node = doc.convert(tex, {
    display: !!display,
    em: pxEx / 0.442,
    ex: pxEx,
    containerWidth: display ? Math.max(container_px || 0, 1) : 1e6,
  });
  const html = adaptor.innerHTML(node);
  if (html.includes('data-mml-node="merror"')) {
    const m = /<title[^>]*>([^<]*)<\/title>/.exec(html);
    throw new Error(m ? m[1] : "TeX error");
  }
  const m = /^<svg([^>]*)>([\s\S]*)<\/svg>$/.exec(html.trim());
  if (!m) throw new Error("unexpected MathJax output");
  const attrs = m[1];
  const inner = m[2];
  const attr = (n) => new RegExp(`\\s${n}="([^"]*)"`).exec(attrs)?.[1];
  const wAttr = attr("width");
  const hEx = parseFloat(attr("height"));
  const dEx = -parseFloat(/vertical-align:\s*(-?[\d.]+)ex/.exec(attr("style") || "")?.[1] ?? "0");
  const h = hEx * pxEx;
  const d = dEx * pxEx;
  const full = wAttr.endsWith("%");
  const w = full ? container_px : parseFloat(wAttr) * pxEx;
  const viewBox = attr("viewBox");
  const ratio = h / cell_h;
  const tag = (ww, hh) =>
    `<svg xmlns="http://www.w3.org/2000/svg" width="${ww}" height="${hh}"` +
    (viewBox ? ` viewBox="${viewBox}"` : "") +
    ">";

  let cols, rows, s = 1, tx, ty;
  if (!display) {
    if (h > cell_h) s = cell_h / h;
    cols = Math.max(1, Math.ceil((w * s) / cell_w - 1e-6));
    rows = 1;
    tx = 0;
    ty = baseline * cell_h - s * (h - d);
    ty = Math.min(Math.max(ty, 0), cell_h - s * h);
  } else {
    rows = Math.max(1, Math.ceil(h / cell_h - 1e-6));
    cols = Math.max(1, Math.ceil(Math.max(w, container_px || 0) / cell_w - 1e-6));
    tx = full ? 0 : (cols * cell_w - w) / 2;
    ty = (rows * cell_h - h) / 2;
  }
  const W = cols * cell_w;
  const H = rows * cell_h;
  const body = (tag(w, h) + inner + "</svg>").replaceAll("currentColor", color);
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">` +
    `<g transform="translate(${tx} ${ty}) scale(${s})">${body}</g></svg>`;
  const rendered = new Resvg(svg, { fitTo: { mode: "original" }, background: "rgba(0,0,0,0)", font: { loadSystemFonts: false } }).render();
  const png = rendered.asPng();
  const six = req.sixel ? encode(rendered.pixels, rendered.width, rendered.height) : null;
  // write a temp file next to `out`, then rename (atomic): a reader of `out` never sees
  // a partly written PNG, and two writers of the same path cannot interleave
  // (the cache directory may have been deleted since the request: :InkMath clear-cache)
  const tmp = `${out}.tmp.${process.pid}.${req.id}`;
  try {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(tmp, png);
    renameSync(tmp, out);
    if (six !== null) {
      // next to the PNG, same name with .six; written after it so a .six implies a valid PNG
      const sixOut = out.replace(/\.png$/, "") + ".six";
      writeFileSync(tmp, six);
      renameSync(tmp, sixOut);
    }
  } catch (e) {
    rmSync(tmp, { force: true });
    throw e;
  }
  return { cols, rows, ratio };
}

function respond(o) {
  process.stdout.write(JSON.stringify(o) + "\n");
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return; // no id to answer; ignore garbage
  }
  if (req === null || typeof req !== "object" || Array.isArray(req)) return;
  try {
    respond({ id: req.id, ok: true, ...render(req) });
  } catch (e) {
    respond({ id: req?.id, ok: false, error: String((e && e.message) || e) || "render failed" });
  }
});
rl.on("close", () => process.exit(0));
