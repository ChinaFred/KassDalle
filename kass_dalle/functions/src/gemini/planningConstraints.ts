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
 * Un critère réservé à un jour nommé (« street food le vendredi ») est rendu à
 * part, sous ce jour (`par_jour`) : il ne vaut que pour les créneaux de ce
 * jour de semaine (`criteriaForWeekday`), jamais pour toute la semaine.
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
import { MAIN_PROTEINS, MAIN_STARCHES, RECIPE_STYLES, RECIPE_STYLE_LABELS } from "./mealRole";
import {
  MAX_DURATION_MAX,
  MAX_DURATION_MIN,
  criteriaIsEmpty,
  mergeCriteria,
  readPlanningCriteria,
  type PlanningCriteria,
} from "./planningCriteria";

/**
 * Version du prompt : une entrée de cache d'une autre version est retraduite.
 * 2 (v0.24.60) : styles voulus (`styles_voulus`) et critères réservés à un
 * jour de semaine (`par_jour`).
 */
export const PLANNING_CONSTRAINTS_PROMPT_VERSION = 2;

/** Textes traduits par appel, au plus. Au-delà : non vérifiés, transmis tels quels. */
export const CONSTRAINT_TEXTS_PER_CALL = 16;

/** Longueur au-delà de laquelle un texte n'est pas traduit : il part au prompt tel quel. */
export const CONSTRAINT_TEXT_MAX_CHARS = 2_000;

/** Entrées gardées dans le cache ; les plus anciennes sortent. */
export const CONSTRAINT_CACHE_MAX_ENTRIES = 40;

/**
 * Plafond de jetons de sortie : seize objets courts, plus la réflexion de
 * Claude, qui compte dans `max_tokens`. Mesuré sur Sonnet 5 : 662 jetons de
 * sortie (22 oct. 2026). Gemini ne reçoit pas ce plafond ; il ne sert qu'à
 * l'estimation du coût plafond.
 */
export const PLANNING_CONSTRAINTS_MAX_TOKENS = 12_000;

/** Ce que le programme a compris d'un texte. */
export interface TextUnderstanding {
  /** Critères valables tous les jours. */
  criteria: PlanningCriteria;
  /**
   * Critères réservés à un jour de semaine (1 = lundi … 7 = dimanche) :
   * « street food le vendredi ». Absent ou vide : aucun.
   */
  criteriaByWeekday?: ReadonlyMap<number, PlanningCriteria>;
  /** Ce que le modèle n'a pas su traduire, recopié : part au prompt, non vérifié. */
  untranslated: string;
}

/** Empreinte d'un texte, clé du cache : SHA-256 du texte sans espaces en bord. */
export function constraintTextHash(text: string): string {
  return createHash("sha256").update(text.trim(), "utf8").digest("hex");
}

/** Les critères d'un texte, ou d'un jour de ce texte : mêmes clés. */
const CRITERIA_PROPERTIES = {
  allergenes_exclus: { type: "array", items: { type: "string" } },
  proteines_exclues: { type: "array", items: { type: "string" } },
  feculents_exclus: { type: "array", items: { type: "string" } },
  proteines_voulues: { type: "array", items: { type: "string" } },
  feculents_voulus: { type: "array", items: { type: "string" } },
  styles_voulus: { type: "array", items: { type: "string" } },
  preparation_max_min: { type: "integer" },
  leger: { type: "boolean" },
};

const CONSTRAINTS_SCHEMA = {
  type: "object",
  properties: {
    textes: {
      type: "array",
      items: {
        type: "object",
        properties: {
          index: { type: "integer" },
          ...CRITERIA_PROPERTIES,
          par_jour: {
            type: "array",
            items: {
              type: "object",
              properties: { jour: { type: "integer" }, ...CRITERIA_PROPERTIES },
              required: ["jour"],
              additionalProperties: false,
            },
          },
          non_traduit: { type: "string" },
        },
        required: ["index", "non_traduit"],
        additionalProperties: false,
      },
    },
  },
  required: ["textes"],
  additionalProperties: false,
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
    `- styles_voulus : style de plat souhaité, parmi : ${RECIPE_STYLES.map(
      (k) => `${k} (${RECIPE_STYLE_LABELS[k]})`,
    ).join(", ")}.`,
  );
  lines.push(
    "- par_jour : les critères que le texte réserve à un jour de la semaine nommé, un objet par jour : " +
      '"jour" (1 = lundi, 2 = mardi, 3 = mercredi, 4 = jeudi, 5 = vendredi, 6 = samedi, 7 = dimanche) ' +
      "et les mêmes clés de critères.",
  );
  lines.push(
    "- non_traduit : ce qui reste du texte une fois les critères relevés, recopié tel quel ; vide si tout est traduit.",
  );
  lines.push("");
  lines.push("=== RÈGLES ===");
  lines.push(
    "- Ne relève un critère que si le texte le dit. N'en déduis aucun d'un goût, d'une habitude ou d'une règle de variété.",
  );
  lines.push(
    "- Un exclu est une interdiction (« pas de », « sans », « jamais », une allergie). Un voulu est un souhait (« plutôt », « de préférence », « généralement », « en général »).",
  );
  lines.push(
    "- Un critère qui nomme un jour de la semaine (« le vendredi », « tous les lundis ») va dans par_jour sous ce jour, et pas dans les critères de tous les jours.",
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
      '"proteines_voulues", "feculents_voulus", "styles_voulus" (listes de valeurs du vocabulaire), ' +
      '"preparation_max_min" (entier), "leger" (booléen) et "par_jour" (liste d\'objets).',
  );
  return lines.join("\n");
}

/** Les critères d'un objet de la réponse, clés françaises du prompt. */
function criteriaFromAnswer(r: Record<string, unknown>): PlanningCriteria {
  return readPlanningCriteria({
    excluded_allergens: r.allergenes_exclus,
    excluded_proteins: r.proteines_exclues,
    excluded_starches: r.feculents_exclus,
    wanted_proteins: r.proteines_voulues,
    wanted_starches: r.feculents_voulus,
    max_duration: r.preparation_max_min,
    light: r.leger,
    wanted_styles: r.styles_voulus,
  });
}

/**
 * Les critères réservés à un jour, lus dans `par_jour`. Un jour hors 1 à 7,
 * un objet illisible ou sans critère est écarté ; deux objets du même jour
 * sont réunis.
 */
function criteriaByWeekdayFromAnswer(raw: unknown): Map<number, PlanningCriteria> {
  const out = new Map<number, PlanningCriteria>();
  if (!Array.isArray(raw)) return out;
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const r = item as Record<string, unknown>;
    const day = r.jour;
    if (typeof day !== "number" || !Number.isInteger(day) || day < 1 || day > 7) continue;
    const c = criteriaFromAnswer(r);
    if (criteriaIsEmpty(c)) continue;
    const before = out.get(day);
    out.set(day, before ? mergeCriteria([before, c]) : c);
  }
  return out;
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
    const byWeekday = criteriaByWeekdayFromAnswer(r.par_jour);
    out.set(index, {
      criteria: criteriaFromAnswer(r),
      ...(byWeekday.size > 0 ? { criteriaByWeekday: byWeekday } : {}),
      untranslated: rest.length > text.length ? text : rest,
    });
  }
  return out;
}

/**
 * La traduction tient-elle dans le plafond de la génération ?
 *
 * Sans plafond (taux de change absent) ou sans estimation (grille
 * illisible), aucun chiffre n'est inventé : la traduction part, bornée par le
 * plafond du jour. Sinon, son coût plafond doit tenir dans le plafond.
 */
export function translationFitsCap(args: {
  capUsd: number | null;
  estimateUsd: number | null;
}): boolean {
  if (args.capUsd == null || args.estimateUsd == null) return true;
  return args.estimateUsd <= args.capUsd;
}

/**
 * Ce que la traduction retire du plafond de la génération : son coût
 * enregistré, à défaut son estimation, à défaut rien.
 */
export function translationSpentUsd(args: {
  called: boolean;
  recordedUsd: number | null;
  estimateUsd: number | null;
}): number {
  if (!args.called) return 0;
  return args.recordedUsd ?? args.estimateUsd ?? 0;
}

/**
 * Coût d'un document de génération : l'appel de planning, plus ce que la
 * traduction a retiré du plafond (`spentUsd` : coût enregistré, à défaut son
 * estimation). Un appel sans montant compte dans `unpricedCalls`, et son
 * estimation reste dans `costUsd` : le plafond des conceptions ne la perd pas.
 */
export function planningRunCost(args: {
  modelCall: { costUsd: number | null } | null;
  translation: { called: boolean; costUsd: number | null; spentUsd: number } | null;
}): { costUsd: number; unpricedCalls: number } {
  const model = args.modelCall?.costUsd;
  const t = args.translation;
  const translated = t != null && t.called;
  return {
    costUsd: (typeof model === "number" ? model : 0) + (translated ? t.spentUsd : 0),
    unpricedCalls:
      (args.modelCall != null && model == null ? 1 : 0) + (translated && t.costUsd == null ? 1 : 0),
  };
}

/**
 * Traduit des textes en un appel. Une réponse illisible lève (`askJson`) ;
 * [onCost] reçoit le coût enregistré dans tous les cas où le modèle a répondu.
 */
export async function translateConstraintTexts(
  texts: readonly string[],
  ctx: ModelCallContext,
  onCost?: (costUsd: number | null) => void,
): Promise<Map<number, TextUnderstanding>> {
  return askJson({
    prompt: buildConstraintsPrompt(texts),
    ctx: { ...ctx, feature: "planning_constraints", timeoutMs: 45 * 1000 },
    outputSchema: { name: "planning_constraints", schema: CONSTRAINTS_SCHEMA },
    maxTokens: PLANNING_CONSTRAINTS_MAX_TOKENS,
    validate: (parsed) => parseConstraintsAnswer(parsed, texts),
    ...(onCost ? { onCost } : {}),
  });
}
