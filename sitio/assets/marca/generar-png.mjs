// Genera los PNG de la marca a partir de los SVG, con transparencia y tamaños exactos.
// Usa Edge o Chrome sin interfaz (headless): sin dependencias de npm.
// Uso: node marca/generar-png.mjs
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const aqui = dirname(fileURLToPath(import.meta.url));
const salida = join(aqui, "png");
const tamanos = [16, 32, 48, 128, 256, 512, 1024];
const logos = ["alma-logo", "alma-logo-oscuro", "alma-logo-mono", "alma-icono-app"];

const candidatos = [
  process.env.NAVEGADOR,
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
].filter(Boolean);
const navegador = candidatos.find((c) => existsSync(c));
if (!navegador) throw new Error("No encontré Edge ni Chrome; define NAVEGADOR con su ruta.");

mkdirSync(salida, { recursive: true });
const temporal = join(tmpdir(), "alma-marca");
mkdirSync(temporal, { recursive: true });

for (const logo of logos) {
  let svg = readFileSync(join(aqui, `${logo}.svg`), "utf8");
  // El monocromo usa currentColor: en PNG se exporta en la tinta de la marca.
  svg = svg.replaceAll("currentColor", "#16131F");
  const uri = "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");
  const html = `<!doctype html><meta charset="utf-8"><body><script>
    const tamanos = ${JSON.stringify(tamanos)};
    const img = new Image();
    img.onload = () => {
      const out = [];
      for (const n of tamanos) {
        const c = document.createElement("canvas");
        c.width = n; c.height = n;
        c.getContext("2d").drawImage(img, 0, 0, n, n);
        out.push(n + ":" + c.toDataURL("image/png"));
      }
      document.body.textContent = "INICIO" + out.join("|") + "FIN";
    };
    img.src = ${JSON.stringify(uri)};
  </script></body>`;
  const pagina = join(temporal, `${logo}.html`);
  writeFileSync(pagina, html);
  const dom = execFileSync(navegador, [
    "--headless=new", "--disable-gpu", "--no-first-run", "--virtual-time-budget=5000",
    `--user-data-dir=${join(temporal, "perfil")}`, "--dump-dom", pathToFileURL(pagina).href,
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const m = dom.match(/INICIO(.*)FIN/s);
  if (!m) throw new Error(`El navegador no generó ${logo}`);
  for (const parte of m[1].split("|")) {
    const [n, url] = parte.split(/:(.*)/s);
    writeFileSync(join(salida, `${logo}-${n}.png`), Buffer.from(url.split(",")[1], "base64"));
  }
  console.log(`${logo}: ${tamanos.join(", ")} px`);
}
rmSync(temporal, { recursive: true, force: true });
