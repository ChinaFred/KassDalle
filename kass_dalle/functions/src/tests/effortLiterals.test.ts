/**
 * L'effort de réflexion Claude d'un poste ne s'écrit qu'à un endroit :
 * `CODE_EFFORTS`, dans `ai/featureEfforts.ts`.
 *
 * L'écran Admin › Moteur d'IA affiche cette table (« Selon le poste (haute) »)
 * et l'écrit sur les postes qu'il fige avant de changer la réflexion par
 * défaut. Un `effort: "high"` recopié dans un appel ferait afficher un effort
 * que le poste ne reçoit pas. Ce test échoue dès qu'un fichier de `src/`
 * (tests exclus) écrit un effort en dur hors des fichiers listés ci-dessous.
 *
 * Lecture des sources seule : ni Firestore, ni réseau.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/** `lib/tests` → `src`. */
const SRC = path.join(__dirname, "..", "..", "src");

/**
 * Fichiers autorisés à écrire un effort en dur, chemin relatif à `src/`.
 *
 * - `ai/featureEfforts.ts` : la table elle-même.
 * - `gemini/tagging.ts` : `TAGGING_EFFORT` et `TAGGING_RETRY_EFFORT`, gardés
 *   pour la logique de reprise du balisage ; `featureEfforts.test.ts`
 *   vérifie que `TAGGING_EFFORT` vaut l'effort de ses deux postes.
 */
const ALLOWED = new Set(["ai/featureEfforts.ts", "gemini/tagging.ts"]);

/** `effort: "high"`, `effort = 'low'`, `Effort = "medium"`… */
const HARDCODED_EFFORT = /\beffort\s*[:=]\s*["'`](low|medium|high)["'`]/i;

function sourceFiles(dir: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "tests") continue;
      files.push(...sourceFiles(full));
    } else if (entry.name.endsWith(".ts")) {
      files.push(full);
    }
  }
  return files;
}

test("aucun effort écrit en dur hors de ai/featureEfforts.ts", () => {
  const offenders: string[] = [];
  for (const file of sourceFiles(SRC)) {
    const relative = path.relative(SRC, file).split(path.sep).join("/");
    if (ALLOWED.has(relative)) continue;
    readFileSync(file, "utf8")
      .split("\n")
      .forEach((line, index) => {
        if (HARDCODED_EFFORT.test(line)) offenders.push(`${relative}:${index + 1}: ${line.trim()}`);
      });
  }
  assert.deepEqual(
    offenders,
    [],
    "Effort écrit en dur : l'inscrire dans CODE_EFFORTS (ai/featureEfforts.ts) et le lire " +
      "par codeEffortFor(feature).",
  );
});

test("le motif reconnaît un effort écrit en dur", () => {
  // Sans ce témoin, un motif cassé laisserait passer le premier test.
  assert.ok(HARDCODED_EFFORT.test('  effort: "high",'));
  assert.ok(HARDCODED_EFFORT.test("ctx.effort = 'low';"));
  assert.ok(!HARDCODED_EFFORT.test("  effort: codeEffortFor(feature),"));
  assert.ok(!HARDCODED_EFFORT.test('  anthropicEffort: "low" | "medium" | "high" | null;'));
});

test("les fichiers autorisés existent encore", () => {
  // Un fichier renommé ou supprimé doit sortir de la liste.
  const present = new Set(
    sourceFiles(SRC).map((file) => path.relative(SRC, file).split(path.sep).join("/")),
  );
  for (const allowed of ALLOWED) assert.ok(present.has(allowed), allowed);
});
