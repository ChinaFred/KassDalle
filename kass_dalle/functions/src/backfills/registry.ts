/**
 * Registre des backfills d'Admin › Backfills.
 *
 * Chaque backfill est classé une fois pour toutes :
 *
 *  - `ponctuel` : il reprend un fonds antérieur à une règle ou à un champ. Une
 *    fois passé sans reste, il est marqué terminé (automatiquement, ou à la
 *    main par un administrateur) et descend en bas de l'écran, en attendant
 *    d'être retiré du code (skill `backfill`, « Retrait »). Il ne se programme
 *    pas.
 *  - `recurrent` : il a du travail à chaque nouvelle recette ou à chaque
 *    nouvel ingrédient. Il garde la date de son dernier passage et peut être
 *    programmé (jours + heure de Paris), lancé par `scheduledBackfills`.
 *
 * Le pendant côté client est `lib/features/admin/domain/backfill_registry.dart`
 * — mêmes clés, même classement. Un backfill ajouté à l'écran s'ajoute aux deux.
 *
 * Retirés en v0.23.52, une fois terminés en production : `recipe_protein`,
 * `estimated_times` et `planning_defaults`.
 * Retirés en v0.24.33, une fois terminés en production : `system_books`,
 * `group_planning_reach`, `ticket_analyses`, `ticket_delivered_pr`,
 * `recipe_title_keys` et `invitation_group_owner`.
 * Retirés en v0.24.37, une fois terminés en production : `illustration_folders`
 * et `illustration_folders_move`.
 * Retiré en v0.24.44, sur demande, sans être terminé (ponctuel réutilisable) :
 * `move_meals_to_group`.
 * Retirés en v0.24.52, une fois terminés en production : `default_units` et
 * `users_schema_check`.
 * Leurs documents `app_config/backfill_run_<clé>` restent en base ; plus rien
 * ne les lit. La liste complète, avec les versions : skill `backfill`,
 * « Backfills retirés ».
 */

export type BackfillKind = "ponctuel" | "recurrent";

export const BACKFILL_KEYS = [
  "nutrition",
  "enrich_referentials",
  "allergens",
  "recipe_roles",
  "shopping_products",
  "refresh_sodium",
  "utensils_cleanup",
] as const;

export type BackfillKey = (typeof BACKFILL_KEYS)[number];

export interface BackfillDefinition {
  key: BackfillKey;
  kind: BackfillKind;
  /** Titre de la tuile, repris dans les messages d'erreur. */
  title: string;
  /** Le passage appelle-t-il un modèle (donc est-il facturé) ? */
  usesAi: boolean;
  /**
   * Programmation appliquée tant que `app_config/backfill_schedules` ne dit
   * rien de ce backfill, `null` sans défaut. Seule la nutrition en a une :
   * elle remplace `scheduledNutritionCatchUp` (tous les jours à 5 h), retirée
   * en v0.23.45. Même valeur côté client (`backfill_registry.dart`), qui
   * l'affiche « (par défaut) » et en pré-remplit l'éditeur ; fixture
   * `backfill_schedule.json`.
   */
  defaultSchedule: BackfillDefaultSchedule | null;
}

/** Jours ISO (lundi = 1) et heure de Paris d'une programmation par défaut. */
export interface BackfillDefaultSchedule {
  days: readonly number[];
  hour: number;
}

export const BACKFILLS: readonly BackfillDefinition[] = [
  {
    key: "nutrition",
    kind: "recurrent",
    title: "Reprendre la nutrition",
    usesAi: true,
    defaultSchedule: { days: [1, 2, 3, 4, 5, 6, 7], hour: 5 },
  },
  {
    key: "enrich_referentials",
    kind: "recurrent",
    title: "Enrichir unités et ingrédients",
    usesAi: true,
    defaultSchedule: null,
  },
  {
    key: "allergens",
    kind: "recurrent",
    title: "Allergènes des ingrédients et des recettes",
    usesAi: true,
    defaultSchedule: null,
  },
  {
    key: "recipe_roles",
    kind: "recurrent",
    title: "Rôle des recettes dans un repas",
    usesAi: true,
    defaultSchedule: null,
  },
  {
    key: "shopping_products",
    kind: "recurrent",
    title: "Recalculer les produits d'achat",
    usesAi: false,
    defaultSchedule: null,
  },
  {
    key: "refresh_sodium",
    kind: "ponctuel",
    title: "Reprendre le sel des ingrédients",
    usesAi: true,
    defaultSchedule: null,
  },
  {
    key: "utensils_cleanup",
    kind: "ponctuel",
    title: "Retirer les ustensiles des ingrédients",
    // Le passage n'appelle aucun modèle, mais chaque recette corrigée est
    // recalculée par `onRecipeWritten`, qui peut en appeler un.
    usesAi: true,
    defaultSchedule: null,
  },
];

/** La définition d'une clé, ou `null` si elle n'existe pas. */
export function backfillDefinition(key: unknown): BackfillDefinition | null {
  if (typeof key !== "string") return null;
  return BACKFILLS.find((b) => b.key === key) ?? null;
}

/** Les clés des backfills récurrents, dans l'ordre de l'écran. */
export function recurrentKeys(): BackfillKey[] {
  return BACKFILLS.filter((b) => b.kind === "recurrent").map((b) => b.key);
}

/**
 * Backfills qui écrivent les mêmes documents et ne doivent pas tourner
 * ensemble : l'enrichissement des référentiels et la réparation du sel
 * réécrivent tous deux `per100g` des ingrédients. Le nettoyage des ustensiles
 * supprime des fiches que ces deux-là, et les allergènes, pourraient recréer
 * par une écriture fusionnée. Un passage de l'un est refusé pendant que l'autre tient
 * son verrou. Un backfill peut appartenir à plusieurs groupes.
 */
const LOCK_GROUPS: readonly (readonly BackfillKey[])[] = [
  ["enrich_referentials", "refresh_sodium"],
  ["utensils_cleanup", "enrich_referentials"],
  ["utensils_cleanup", "refresh_sodium"],
  ["utensils_cleanup", "allergens"],
];

/** Les autres backfills dont le verrou bloque [key], dans l'ordre des groupes. */
export function lockSiblings(key: BackfillKey): BackfillKey[] {
  const out: BackfillKey[] = [];
  for (const group of LOCK_GROUPS) {
    if (!group.includes(key)) continue;
    for (const k of group) if (k !== key && !out.includes(k)) out.push(k);
  }
  return out;
}
