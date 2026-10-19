import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { checkDefinition, extractFrontmatter, namesInTable } from "./check-agents.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const yaml = createRequire(join(ROOT, "kass_dalle", "functions", "package.json"))("js-yaml");

const agent = (description) =>
  `---\nname: ux-designer\ndescription: ${description}\ntools: Read\n---\n\nCorps.\n`;

test("un en-tête valide ne lève aucune anomalie", () => {
  assert.deepEqual(
    checkDefinition(yaml, agent('"Expert UX. Lecture seule : il relit."'), "ux-designer"),
    [],
  );
});

test("un deux-points suivi d’une espace hors guillemets rend l’en-tête invalide (v0.24.10)", () => {
  const problems = checkDefinition(
    yaml,
    agent("Expert UX. Lecture seule : il relit."),
    "ux-designer",
  );
  assert.equal(problems.length, 1);
  assert.match(problems[0], /^en-tête YAML invalide, ligne 3/);
});

test("un fichier sans en-tête est signalé", () => {
  assert.deepEqual(checkDefinition(yaml, "# Titre\n", "x"), [
    "en-tête YAML absent (le fichier doit commencer par ---)",
  ]);
});

test("name et description sont exigés, name égal au nom du fichier", () => {
  const problems = checkDefinition(yaml, "---\nname: autre\n---\n", "ux-designer");
  assert.deepEqual(problems, [
    "clé `description` absente ou vide",
    "`name: autre` diffère du nom attendu `ux-designer`",
  ]);
});

test("les fins de ligne Windows sont acceptées", () => {
  assert.equal(extractFrontmatter("---\r\nname: a\r\n---\r\nCorps"), "name: a");
});

test("les noms du tableau qui suit le titre sont lus, et seulement eux", () => {
  const markdown = [
    "## Agents",
    "",
    "| Agent | Quand |",
    "|---|---|",
    "| `relecteur-regles` | relecture |",
    "| `securite` | audit |",
    "",
    "| Skill | Quand |",
    "|---|---|",
    "| `backfill` | reprise |",
    "",
    "## Suite",
    "| `autre` | x |",
  ].join("\n");
  assert.deepEqual(namesInTable(markdown, "## Agents"), ["relecteur-regles", "securite"]);
  assert.deepEqual(namesInTable(markdown, "| Skill |"), ["backfill"]);
  assert.deepEqual(namesInTable(markdown, "## Absent"), []);
});
