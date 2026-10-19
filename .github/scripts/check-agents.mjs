// Vérifie que Claude Code peut charger chaque agent et chaque skill du dépôt.
//
// Claude Code écarte sans message un agent dont l'en-tête YAML est invalide :
// ux-designer et securite ont manqué à toutes les sessions du 14 au 19 octobre
// 2026 (v0.24.10). Ce script rend l'écart visible.
//
//   node .github/scripts/check-agents.mjs          CI : sort en 1 sur une anomalie
//   node .github/scripts/check-agents.mjs --warn   hook : avertit, sort toujours en 0
//
// js-yaml se charge depuis kass_dalle/functions/node_modules (devDependency).

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** En-tête YAML d'un fichier Markdown, ou null s'il n'en a pas. */
export function extractFrontmatter(text) {
  const normalized = text.replace(/\r\n/g, "\n");
  const match = /^---\n([\s\S]*?)\n---(\n|$)/.exec(normalized);
  return match ? match[1] : null;
}

/** Anomalies d'un fichier d'agent ou de skill. `expectedName` : nom attendu. */
export function checkDefinition(yaml, text, expectedName) {
  const header = extractFrontmatter(text);
  if (header === null) return ["en-tête YAML absent (le fichier doit commencer par ---)"];
  let data;
  try {
    data = yaml.load(header);
  } catch (error) {
    const reason = String(error.reason ?? error.message).split("\n")[0];
    const line = error.mark ? `, ligne ${error.mark.line + 2}` : "";
    return [`en-tête YAML invalide${line} : ${reason}`];
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return ["en-tête YAML qui n'est pas une suite de clés"];
  }
  const problems = [];
  for (const key of ["name", "description"]) {
    if (typeof data[key] !== "string" || data[key].trim() === "") {
      problems.push(`clé \`${key}\` absente ou vide`);
    }
  }
  if (typeof data.name === "string" && data.name !== expectedName) {
    problems.push(`\`name: ${data.name}\` diffère du nom attendu \`${expectedName}\``);
  }
  return problems;
}

/** Noms cités en première colonne du premier tableau qui suit `heading`. */
export function namesInTable(markdown, heading) {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((line) => line.startsWith(heading));
  if (start < 0) return [];
  const names = [];
  let inTable = false;
  for (const line of lines.slice(start + 1)) {
    const cell = /^\| `([^`]+)` \|/.exec(line);
    if (cell) {
      inTable = true;
      names.push(cell[1]);
    } else if (inTable && !line.startsWith("|")) {
      break;
    } else if (line.startsWith("## ")) {
      break;
    }
  }
  return names;
}

function loadYaml() {
  const require = createRequire(join(ROOT, "kass_dalle", "functions", "package.json"));
  return require("js-yaml");
}

function listDefinitions() {
  const agentsDir = join(ROOT, ".claude", "agents");
  const skillsDir = join(ROOT, ".claude", "skills");
  const agents = existsSync(agentsDir)
    ? readdirSync(agentsDir)
        .filter((file) => file.endsWith(".md"))
        .map((file) => ({
          kind: "agent",
          name: basename(file, ".md"),
          path: join(agentsDir, file),
        }))
    : [];
  const skills = existsSync(skillsDir)
    ? readdirSync(skillsDir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => ({
          kind: "skill",
          name: entry.name,
          path: join(skillsDir, entry.name, "SKILL.md"),
        }))
    : [];
  return [...agents, ...skills];
}

function main() {
  const warnOnly = process.argv.includes("--warn");
  const problems = [];

  let yaml;
  try {
    yaml = loadYaml();
  } catch (error) {
    const message =
      `check-agents : js-yaml introuvable (${error.code ?? error.message}). ` +
      "Lancer `npm ci` dans kass_dalle/functions ; agents et skills non vérifiés.";
    console.log(message);
    process.exit(warnOnly ? 0 : 1);
  }

  const definitions = listDefinitions();
  for (const { kind, name, path } of definitions) {
    const relative = path.slice(ROOT.length + 1);
    if (!existsSync(path)) {
      problems.push(`${relative} — ${kind} \`${name}\` : fichier absent`);
      continue;
    }
    for (const problem of checkDefinition(yaml, readFileSync(path, "utf8"), name)) {
      problems.push(`${relative} — ${kind} \`${name}\` non chargé : ${problem}`);
    }
  }

  const claudeMd = readFileSync(join(ROOT, "CLAUDE.md"), "utf8");
  const present = new Set(definitions.map(({ kind, name }) => `${kind}:${name}`));
  for (const name of namesInTable(claudeMd, "## Agents")) {
    if (!present.has(`agent:${name}`)) {
      problems.push(`CLAUDE.md — agent \`${name}\` cité, aucun fichier .claude/agents/${name}.md`);
    }
  }
  for (const name of namesInTable(claudeMd, "| Skill |")) {
    if (!present.has(`skill:${name}`)) {
      problems.push(`CLAUDE.md — skill \`${name}\` cité, aucun dossier .claude/skills/${name}/`);
    }
  }

  if (problems.length === 0) {
    if (!warnOnly)
      console.log(`check-agents : ${definitions.length} agents et skills chargeables.`);
    return;
  }
  const header = warnOnly
    ? `ATTENTION — ${problems.length} agent(s) ou skill(s) absent(s) de cette session. ` +
      "Le signaler à l'utilisateur avant tout travail qui en a besoin (CLAUDE.md, « Agents ») :"
    : `check-agents : ${problems.length} anomalie(s) :`;
  console.log([header, ...problems.map((problem) => `- ${problem}`)].join("\n"));
  process.exit(warnOnly ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
