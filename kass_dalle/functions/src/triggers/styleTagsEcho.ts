/**
 * Échos d'écriture qui ne changent que le style d'une recette.
 *
 * Le backfill « Style des recettes » écrit `tags.styles` et
 * `tags.styles_checked_at` sur des centaines de recettes ; chacune de ces
 * écritures réveille `onRecipeWritten`. Les traitements qui appellent un
 * modèle (rôle dans un repas, durées estimées) lisent ces gardes pour ne pas
 * facturer un appel sur une écriture qui ne touche aucune de leurs entrées.
 */

import { isDeepStrictEqual } from "node:util";

/** Sous-champs de `tags` que le backfill « Style des recettes » écrit. */
export const STYLE_TAG_FIELDS: ReadonlySet<string> = new Set(["styles", "styles_checked_at"]);

/**
 * Les mêmes, plus la marque de correction à la main (`styles_manual`) : pour
 * un traitement que le style n'intéresse en rien, une correction du style à
 * la main est aussi un écho.
 */
export const STYLE_TAG_FIELDS_WITH_MANUAL: ReadonlySet<string> = new Set([
  ...STYLE_TAG_FIELDS,
  "styles_manual",
]);

/** Vrai quand au moins un champ a changé, et seulement parmi [fields]. */
export function onlyFieldsChanged(
  before: Record<string, unknown>,
  after: Record<string, unknown>,
  fields: ReadonlySet<string>,
): boolean {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  let changed = false;
  for (const key of keys) {
    if (isDeepStrictEqual(before[key], after[key])) continue;
    if (!fields.has(key)) return false;
    changed = true;
  }
  return changed;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/**
 * Vrai quand l'écriture ne change que des sous-champs [fields] de `tags`
 * (par défaut `tags.styles` et `tags.styles_checked_at`) : c'est le backfill
 * « Style des recettes ». Faux pour une création, et quand rien n'a changé.
 */
export function onlyStyleTagsChanged(
  before: Record<string, unknown>,
  after: Record<string, unknown>,
  fields: ReadonlySet<string> = STYLE_TAG_FIELDS,
): boolean {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  let changed = false;
  for (const key of keys) {
    if (isDeepStrictEqual(before[key], after[key])) continue;
    if (key !== "tags") return false;
    if (!onlyFieldsChanged(asRecord(before.tags), asRecord(after.tags), fields)) return false;
    changed = true;
  }
  return changed;
}
