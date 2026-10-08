// Formate le fichier qu'un outil d'édition vient d'écrire.
//
// La CI refuse un fichier Dart non formaté (`dart format --set-exit-if-changed`)
// et un fichier TypeScript que Prettier réécrirait (`npm run format:check`).
// Formater à l'écriture évite d'apprendre l'écart au bout d'un cycle de CI.
//
// Hook PostToolUse sur Edit|Write|MultiEdit. Écrit en Node plutôt qu'en bash
// pour tourner aussi bien dans une session cloud que sur le PC Windows.
//
// Un échec du formateur ne bloque pas l'édition : il est écrit sur stderr, et
// la CI reste le contrôle qui fait foi.
import { spawnSync } from "node:child_process";
import path from "node:path";

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);

let filePath;
try {
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  filePath = input?.tool_input?.file_path;
} catch (err) {
  console.error(`format-on-edit : entrée illisible (${err.message})`);
  process.exit(0);
}
if (typeof filePath !== "string" || filePath.length === 0) process.exit(0);

const root = process.env.CLAUDE_PROJECT_DIR ?? process.cwd();
const rel = path.relative(root, path.resolve(filePath)).split(path.sep).join("/");

// Une seule chaîne de commande, avec un chemin relatif au dossier de travail :
// shell: true est nécessaire sous Windows (dart.bat, npx.cmd), et un chemin
// relatif du dépôt ne contient ni « $ », ni « % », ni antislash de tête UNC
// que le shell réinterpréterait. Les guillemets couvrent les espaces.
function run(command, cwd) {
  const result = spawnSync(command, { cwd, shell: true, encoding: "utf8" });
  if (result.error || result.status !== 0) {
    const detail = result.error?.message || result.stderr?.trim() || `code ${result.status}`;
    console.error(`format-on-edit : « ${command} » a échoué sur ${rel} — ${detail}`);
  }
}

if (rel.startsWith("kass_dalle/") && rel.endsWith(".dart")) {
  run(`dart format "${rel}"`, root);
} else if (rel.startsWith("kass_dalle/functions/src/") && rel.endsWith(".ts")) {
  const functionsDir = path.join(root, "kass_dalle", "functions");
  const fromFunctions = rel.slice("kass_dalle/functions/".length);
  run(`npx --no-install prettier --write "${fromFunctions}"`, functionsDir);
}
