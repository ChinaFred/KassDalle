/**
 * Traduction des préférences du planning en critères structurés.
 *
 * Poste `planning_constraints`. Le texte libre des préférences générales et
 * des notes du jour (« pas de porc », « 30 min max », « pas trop gras ») est
 * lu par le modèle, qui rend des critères du vocabulaire de
 * `planningCriteria.ts` et recopie ce qu'il ne sait pas traduire. Le
 * programme vérifie ensuite ces critères sur chaque candidat : au modèle la
 * reconnaissance, au programme la vérification.
 *
 * Un appel par génération au plus, pour les seuls textes absents du cache
 * (`users/{uid}/preferences/planning_constraints`, par empreinte du texte) :
 * un texte inchangé ne relance aucun appel. Rien ne part à la frappe.
 *
 * Pur hors `askJson` : ni Firestore, ni SDK de fournisseur.
 */

import { createHash } from "node:crypto";

import { askJson } from "../ai/askJson";
import type { ModelCallContext } from "../ai/types";
import { ALLERGEN_KEYS, ALLERGEN_LABELS } from "../nutrition/allergens";
import { MAIN_PROTEINS, MAIN_STARCHES } from "./mealRole";
import {
  MAX_DURATION_MAX,
  MAX_DURATION_MIN,
  readPlanningCriteria,
  type PlanningCriteria,
} from "./planningCriteria";

/** Version du prompt : une entrée de cache d'une autre version est retraduite. */
export const PLANNING_CONSTRAINTS_PROMPT_VERSION = 1;

/** Textes traduits par appel, au plus. Au-delà : non vérifiés, transmis tels quels. */
export const CONSTRAINT_TEXTS_PER_CALL = 16;

/** Longueur au-delà de laquelle un texte n'est pas traduit : il part au prompt tel quel. */
export const CONSTRAINT_TEXT_MAX_CHARS = 2_000;

/** Entrées gardées dans le cache ; les plus anciennes sortent. */
export const CONSTRAINT_CACHE_MAX_ENTRIES = 40;

/** Plafond de jetons de sortie : seize objets courts. */
export const PLANNING_CONSTRAINTS_MAX_TOKENS = 3_000;

/** Ce que le programme a compris d'un texte. */
export interface TextUnderstanding {
  criteria: PlanningCriteria;
  /** Ce que le modèle n'a pas su traduire, recopié : part au prompt, non vérifié. */
  untranslated: string;
}

/** Empreinte d'un texte, clé du cache : SHA-256 du texte sans espaces en bord. */
export function constraintTextHash(text: string): string {
  return createHash("sha256").update(text.trim(), "utf8").digest("hex");
}

const CONSTRAINTS_SCHEMA = {
  type: "object",
  properties: {
    textes: {
      type: "array",
      items: {
        type: "object",
        properties: {
          index: { type: "integer" },
          allergenes_exclus: { type: "array", items: { type: "string" } },
          proteines_exclues: { type: "array", items: { type: "string" } },
          feculents_exclus: { type: "array", items: { type: "string" } },
          proteines_voulues: { type: "array", items: { type: "string" } },
          feculents_voulus: { type: "array", items: { type: "string" } },
          preparation_max_min: { type: "integer" },
          leger: { type: "boolean" },
          non_traduit: { type: "string" },
        },
        required: ["index", "non_traduit"],
      },
    },
  },
  required: ["textes"],
};

/** Le prompt. Exporté pour être testable seul. Aucun exemple rempli : le vocabulaire seul. */
export function buildConstraintsPrompt(texts: readonly string[]): string {
  const lines: string[] = [];
  lines.push(
    "Tu lis des préférences de repas écrites par une famille pour son planning. Pour chaque texte, " +
      "relève les critères qui appartiennent au vocabulaire ci-dessous, et recopie mot pour mot ce " +
      "que tu ne sais pas traduire.",
  );
  lines.push("");
  lines.push("=== VOCABULAIRE ===");
  lines.push(
    `- allergenes_exclus : allergènes que la famille ne mange pas, parmi : ${ALLERGEN_KEYS.map(
      (k) => `${k} (${ALLERGEN_LABELS[k]})`,
    ).join(", ")}.`,
  );
  lines.push(
    `- proteines_exclues / proteines_voulues : protéine principale d'un plat, parmi : ${MAIN_PROTEINS.join(", ")}.`,
  );
  lines.push(
    `- feculents_exclus / feculents_voulus : féculent principal d'un plat, parmi : ${MAIN_STARCHES.join(", ")}.`,
  );
  lines.push(
    `- preparation_max_min : durée de préparation maximale en minutes entières, de ${MAX_DURATION_MIN} à ${MAX_DURATION_MAX}.`,
  );
  lines.push("- leger : vrai si le texte demande un repas léger.");
  lines.push(
    "- non_traduit : ce qui reste du texte une fois les critères relevés, recopié tel quel ; vide si tout est traduit.",
  );
  lines.push("");
  lines.push("=== RÈGLES ===");
  lines.push(
    "- Ne relève un critère que si le texte le dit. N'en déduis aucun d'un goût, d'une habitude ou d'une règle de variété.",
  );
  lines.push(
    "- Un exclu est une interdiction (« pas de », « sans », « jamais », une allergie). Un voulu est un souhait (« plutôt », « de préférence », « du poisson le vendredi »).",
  );
  lines.push(
    "- Une règle qui porte sur plusieurs jours (« pas deux fois de suite », « au plus deux fois par semaine ») ne se traduit pas : elle reste dans non_traduit.",
  );
  lines.push("- Une valeur hors vocabulaire ne s'invente pas : le passage reste dans non_traduit.");
  lines.push("");
  lines.push("=== TEXTES ===");
  texts.forEach((t, i) => {
    lines.push(`--- texte ${i} ---`);
    lines.push(t.trim());
  });
  lines.push("");
  lines.push("=== FORMAT DE RÉPONSE ===");
  lines.push(
    'Réponds UNIQUEMENT avec un objet JSON portant une clé "textes" : un tableau d\'objets, un par ' +
      'texte, chacun avec "index" (le numéro du texte), "non_traduit" (texte), et seulement les ' +
      'critères relevés parmi "allergenes_exclus", "proteines_exclues", "feculents_exclus", ' +
      '"proteines_voulues", "feculents_voulus" (listes de valeurs du vocabulaire), ' +
      '"preparation_max_min" (entier) et "leger" (booléen).',
  );
  return lines.join("\n");
}

/**
 * Lit la réponse du modèle : une compréhension par index de texte.
 *
 * Donnée non fiable : une valeur hors vocabulaire est écartée
 * (`readPlanningCriteria`), un index hors bornes ou en double est ignoré, un
 * `non_traduit` plus long que le texte est ramené au texte entier. Un texte
 * sans réponse manque à la carte : il part au prompt tel quel, non vérifié.
 * `null` si la forme ne tient pas.
 */
export function parseConstraintsAnswer(
  parsed: unknown,
  texts: readonly string[],
): Map<number, TextUnderstanding> | null {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const raw = (parsed as { textes?: unknown }).textes;
  if (!Array.isArray(raw)) return null;
  const out = new Map<number, TextUnderstanding>();
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const r = item as Record<string, unknown>;
    const index = r.index;
    if (typeof index !== "number" || !Number.isInteger(index)) continue;
    if (index < 0 || index >= texts.length || out.has(index)) continue;
    const text = texts[index].trim();
    const rest = typeof r.non_traduit === "string" ? r.non_traduit.trim() : text;
    out.set(index, {
      criteria: readPlanningCriteria({
        excluded_allergens: r.allergenes_exclus,
        excluded_proteins: r.proteines_exclues,
        excluded_starches: r.feculents_exclus,
        wanted_proteins: r.proteines_voulues,
        wanted_starches: r.feculents_voulus,
        max_duration: r.preparation_max_min,
        light: r.leger,
      }),
      untranslated: rest.length > text.length ? text : rest,
    });
  }
  return out;
}

/** Traduit des textes en un appel. Une réponse illisible lève (`askJson`). */
export async function translateConstraintTexts(
  texts: readonly string[],
  ctx: ModelCallContext,
): Promise<Map<number, TextUnderstanding>> {
  return askJson({
    prompt: buildConstraintsPrompt(texts),
    ctx: { ...ctx, feature: "planning_constraints", timeoutMs: 45 * 1000 },
    outputSchema: { name: "planning_constraints", schema: CONSTRAINTS_SCHEMA },
    maxTokens: PLANNING_CONSTRAINTS_MAX_TOKENS,
    validate: (parsed) => parseConstraintsAnswer(parsed, texts),
  });
}
