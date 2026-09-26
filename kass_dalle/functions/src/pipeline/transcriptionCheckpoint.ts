/**
 * Point de reprise de la transcription d'une page.
 *
 * Un job d'import qui échoue après la transcription — balisage coupé, plafond de
 * dépense, panne d'écriture — était rejoué par Cloud Tasks depuis le début, et
 * refaisait l'appel le plus cher : la lecture de la page par le modèle. Sur
 * l'import du livre de Jamie Oliver (26 septembre 2026), 35 transcriptions sur
 * 112 étaient des reprises, soit 10 $ facturés pour un résultat déjà obtenu.
 *
 * La transcription réussie est donc écrite sur le job. Une nouvelle tentative, et
 * une relance depuis la file, la relisent au lieu de la refaire. Elle s'efface
 * quand le job aboutit : elle n'a d'usage qu'entre deux tentatives.
 *
 * Le contenu est une chaîne JSON, pas une carte Firestore : une transcription
 * porte des tableaux dans des tableaux, que Firestore refuse quand ils s'imbriquent
 * directement.
 */

import type { PageTranscription, PageType } from "../gemini/transcription";

/**
 * Taille au-delà de laquelle on n'écrit pas le point de reprise.
 *
 * Un document Firestore pèse un mégaoctet au plus, et le job en porte d'autres
 * champs. Une transcription de recette en compte une dizaine de milliers ; ce
 * plafond n'est atteint que par une page anormale, qui se transcrit alors de
 * nouveau à la tentative suivante.
 */
export const CHECKPOINT_MAX_CHARS = 300_000;

const PAGE_TYPES: readonly PageType[] = [
  "recipe",
  "ingredient_note",
  "technique",
  "equipment",
  "other",
  "no_recipe",
];

/** La transcription sous sa forme écrite sur le job, ou `null` si elle est trop grosse. */
export function serializeCheckpoint(transcription: PageTranscription): string | null {
  const json = JSON.stringify(transcription);
  return json.length <= CHECKPOINT_MAX_CHARS ? json : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function isIngredientSection(value: unknown): boolean {
  return isRecord(value) && typeof value.titre === "string" && isStringArray(value.lignes);
}

function isStepSection(value: unknown): boolean {
  return isRecord(value) && typeof value.titre === "string" && isStringArray(value.etapes);
}

function isNote(value: unknown): boolean {
  return isRecord(value) && typeof value.genre === "string" && typeof value.texte === "string";
}

function isRecipe(value: unknown): boolean {
  return (
    isRecord(value) &&
    typeof value.titre === "string" &&
    typeof value.introduction === "string" &&
    isStringArray(value.lecturesIncertaines) &&
    Array.isArray(value.sectionsIngredients) &&
    value.sectionsIngredients.every(isIngredientSection) &&
    Array.isArray(value.sectionsEtapes) &&
    value.sectionsEtapes.every(isStepSection) &&
    Array.isArray(value.notes) &&
    value.notes.every(isNote)
  );
}

/**
 * Relit un point de reprise.
 *
 * Rend `null` quand le job n'en porte pas — le cas ordinaire d'une première
 * tentative. Lève quand il en porte un qui ne se lit pas : l'appelant journalise
 * et transcrit la page de nouveau, ce qui coûte un appel mais donne un résultat
 * sûr. Un point de reprise corrompu ne doit ni faire échouer le job ni passer
 * inaperçu.
 */
export function parseCheckpoint(raw: unknown): PageTranscription | null {
  if (raw == null || raw === "") return null;
  if (typeof raw !== "string") {
    throw new Error("Point de reprise illisible : ce n'est pas une chaîne JSON.");
  }
  const value: unknown = JSON.parse(raw);
  if (
    !isRecord(value) ||
    typeof value.pageType !== "string" ||
    !PAGE_TYPES.includes(value.pageType as PageType) ||
    typeof value.titre !== "string" ||
    typeof value.raison !== "string" ||
    typeof value.document !== "string" ||
    (value.page !== null && typeof value.page !== "number") ||
    !Array.isArray(value.recettes) ||
    !value.recettes.every(isRecipe)
  ) {
    throw new Error("Point de reprise illisible : la forme de la transcription ne convient pas.");
  }
  return value as unknown as PageTranscription;
}
