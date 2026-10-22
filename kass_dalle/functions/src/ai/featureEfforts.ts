/**
 * Effort de réflexion Claude que le code de chaque poste demande.
 *
 * Source unique. Les appels qui fixent un effort (`transcription.ts`,
 * `detector.ts`, `illustrations/extract.ts`, `translation.ts`, le bac à sable)
 * le lisent ici par `codeEffortFor(feature)` au lieu de recopier la valeur, et
 * `getAiRoutingPolicyFn` l'envoie à l'écran Admin › Moteur d'IA. Sans cette
 * table, l'écran ne pouvait pas dire quelle réflexion reçoit un poste qui
 * n'a pas de réglage propre.
 *
 * Un poste absent de la table demande `DEFAULT_CODE_EFFORT`, celui que
 * `requestShapeFor` applique quand l'appel n'en précise aucun.
 *
 * Ordre de priorité à l'exécution (`resolveAnthropicEffort`, `ai/router.ts`) :
 * effort du poste dans la politique, puis effort par défaut de la politique,
 * puis cette table.
 *
 * Fichier sans dépendance : `ai/anthropic.ts` l'importe, et il ne doit rien
 * tirer de plus que des types.
 */

import type { ModelCallContext } from "./types";

export type AnthropicEffort = NonNullable<ModelCallContext["effort"]>;

/** Effort d'un poste que la table ne nomme pas. */
export const DEFAULT_CODE_EFFORT: AnthropicEffort = "low";

/**
 * Postes dont le code demande un effort autre que `DEFAULT_CODE_EFFORT`.
 *
 * `tests/featureEfforts.test.ts` vérifie que chaque clé est un poste de
 * `ROUTABLE_FEATURES`, et que `TAGGING_EFFORT` vaut l'effort de ses postes.
 */
export const CODE_EFFORTS: Readonly<Record<string, AnthropicEffort>> = {
  // Lire une page de livre ou un texte collé demande du soin : avec `low`, le
  // modèle recollait « en poudre » au mauvais ingrédient et résumait une
  // énumération d'épices en « les épices ».
  transcription_page: "high",
  text_extraction: "high",
  url_import_fallback: "high",
  recipe_translation: "medium",
  // Situer des rectangles dans une image demande du soin, pas de la vitesse.
  detect_illustrations: "high",
  page_illustrations_precheck: "high",
  page_illustrations_frame: "high",
  page_illustrations_orientation: "high",
  page_illustrations_regions: "high",
  sandbox_detect_page: "high",
  sandbox_detect_orientation: "high",
  sandbox_detect_regions: "high",
};

/** Effort que le code d'un poste demande, hors réglage de la politique. */
export function codeEffortFor(feature: string): AnthropicEffort {
  // `Object.hasOwn` : un nom comme `constructor` ne doit pas lire le prototype.
  return Object.hasOwn(CODE_EFFORTS, feature) ? CODE_EFFORTS[feature] : DEFAULT_CODE_EFFORT;
}
