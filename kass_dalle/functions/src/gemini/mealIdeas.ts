/**
 * Idées de repas sur une consigne libre.
 *
 * Le sélecteur de recette du planning propose, sous « Saisir un nom libre »,
 * « Générer avec l'IA » : la personne écrit ce qu'elle a envie de manger, le
 * modèle rend trois idées, et elle affine en modifiant la consigne. Ce qu'elle
 * retient devient un repas libre — un nom et deux durées estimées, sans recette
 * liée. Rien n'est écrit dans les livres : ce poste ne conçoit pas de recette,
 * c'est le rôle de `generateRecipeConcept`.
 *
 * Trois idées et pas une : une seule proposition se refuse ou s'accepte, trois
 * se comparent. Les titres déjà proposés voyagent avec la relance pour que
 * « trois autres » en rende trois autres.
 */

import { askJson } from "../ai/askJson";
import type { ModelCallContext } from "../ai/types";

export const MEAL_IDEAS_PROMPT_VERSION = 1;

/** Ce que rend un appel : ni plus, ni moins. */
export const MEAL_IDEAS_COUNT = 3;

/** Longueur maximale d'une consigne, en caractères. */
export const MEAL_IDEAS_MAX_PROMPT_CHARS = 600;

/** Titres déjà proposés que la relance transporte, au plus. */
export const MEAL_IDEAS_MAX_PREVIOUS = 15;

export interface MealIdeasInput {
  /** La consigne écrite par la personne. */
  prompt: string;
  /** Préférences générales du foyer, telles qu'elles vivent dans le planning. */
  globalConstraints?: string;
  /** Titres des idées déjà rendues : le modèle en propose d'autres. */
  previousTitles?: string[];
}

export interface MealIdea {
  /** Le nom du plat, tel qu'il s'affichera dans le planning. */
  titre: string;
  /** Une phrase : ce qui compose l'assiette. */
  description: string;
  /** Durées estimées, en minutes ; null quand le modèle ne se prononce pas. */
  prepMinutes: number | null;
  cookMinutes: number | null;
}

const MEAL_IDEAS_SCHEMA = {
  type: "object",
  properties: {
    idees: {
      type: "array",
      items: {
        type: "object",
        properties: {
          titre: { type: "string" },
          description: { type: "string" },
          preparation_min: { type: "integer" },
          cuisson_min: { type: "integer" },
        },
        required: ["titre", "description"],
      },
    },
  },
  required: ["idees"],
};

/**
 * Le prompt, exporté pour être testable seul : c'est lui qui porte la consigne,
 * les préférences et les titres à ne pas reprendre.
 */
export function buildMealIdeasPrompt(input: MealIdeasInput): string {
  const lines: string[] = [];
  lines.push(
    "Tu es un cuisinier de famille. Une personne cherche une idée de repas et t'écrit sa demande.",
  );
  lines.push(
    `Propose exactement ${MEAL_IDEAS_COUNT} idées de repas différentes qui répondent à cette ` +
      "demande. Chacune est un plat qu'on cuisine à la maison, pour un repas ordinaire.",
  );
  lines.push("");
  lines.push("=== DEMANDE ===");
  lines.push(input.prompt.trim());
  lines.push("");

  const constraints = (input.globalConstraints ?? "").trim();
  if (constraints) {
    lines.push("=== PRÉFÉRENCES GÉNÉRALES DU FOYER ===");
    lines.push(constraints);
    lines.push("");
  }

  const previous = (input.previousTitles ?? []).map((t) => t.trim()).filter((t) => t.length > 0);
  if (previous.length > 0) {
    lines.push("=== DÉJÀ PROPOSÉ — NE PAS REPRENDRE ===");
    for (const titre of previous) lines.push(`- ${titre}`);
    lines.push("");
  }

  lines.push("=== RÈGLES ===");
  lines.push(
    "- Les idées se distinguent entre elles : protéine principale, féculent ou registre différents.",
  );
  lines.push(
    "- Le titre nomme le plat comme sur une carte, en français, sans point final, soixante caractères au plus.",
  );
  lines.push(
    "- La description tient en une phrase : ce qui compose l'assiette et ce qui fait le plat.",
  );
  lines.push(
    "- Les durées sont estimées en minutes entières : preparation_min pour la préparation, cuisson_min pour la cuisson. Omets une durée que tu ne sais pas estimer.",
  );
  lines.push(
    "- Si la demande contredit les préférences du foyer, la demande l'emporte. Si elle est hors cuisine ou irréalisable, propose ce qui s'en approche le plus.",
  );
  lines.push("");
  lines.push("=== FORMAT DE RÉPONSE ===");
  lines.push(
    "Réponds UNIQUEMENT avec un objet JSON, sans balises ni texte autour, portant une clé " +
      `"idees" : un tableau de ${MEAL_IDEAS_COUNT} objets, chacun avec les clés "titre" (texte), ` +
      '"description" (texte), "preparation_min" (entier, facultatif) et "cuisson_min" (entier, facultatif).',
  );
  return lines.join("\n");
}

function readMinutes(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null;
  return Math.round(value);
}

/**
 * Lit la réponse du modèle.
 *
 * Rend au plus [MEAL_IDEAS_COUNT] idées, sans doublon de titre, ou `null` si
 * la forme ne tient pas ou si aucune idée n'a de titre. Moins de trois idées
 * valides passent : deux idées valent mieux qu'un écran vide, et l'écran dit
 * combien il en a reçu.
 */
export function parseMealIdeas(parsed: unknown): MealIdea[] | null {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const raw = (parsed as { idees?: unknown }).idees;
  if (!Array.isArray(raw)) return null;

  const out: MealIdea[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const record = item as Record<string, unknown>;
    const titre = typeof record.titre === "string" ? record.titre.trim() : "";
    if (!titre) continue;
    const key = titre.toLocaleLowerCase("fr");
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({
      titre,
      description: typeof record.description === "string" ? record.description.trim() : "",
      prepMinutes: readMinutes(record.preparation_min),
      cookMinutes: readMinutes(record.cuisson_min),
    });
    if (out.length === MEAL_IDEAS_COUNT) break;
  }
  return out.length > 0 ? out : null;
}

/** Trois idées de repas pour une consigne. Une réponse illisible lève. */
export async function suggestMealIdeas(
  input: MealIdeasInput,
  ctx: ModelCallContext,
): Promise<MealIdea[]> {
  return askJson({
    prompt: buildMealIdeasPrompt(input),
    ctx: { ...ctx, feature: "planning_meal_ideas", timeoutMs: 45 * 1000 },
    outputSchema: { name: "meal_ideas", schema: MEAL_IDEAS_SCHEMA },
    maxTokens: 2_000,
    validate: parseMealIdeas,
  });
}
