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
 */

export type BackfillKind = "ponctuel" | "recurrent";

export const BACKFILL_KEYS = [
  "nutrition",
  "enrich_referentials",
  "allergens",
  "recipe_roles",
  "shopping_products",
  "recipe_protein",
  "estimated_times",
  "refresh_sodium",
  "planning_defaults",
] as const;

export type BackfillKey = (typeof BACKFILL_KEYS)[number];

export interface BackfillDefinition {
  key: BackfillKey;
  kind: BackfillKind;
  /** Titre de la tuile, repris dans les messages d'erreur. */
  title: string;
  /** Le passage appelle-t-il un modèle (donc est-il facturé) ? */
  usesAi: boolean;
}

export const BACKFILLS: readonly BackfillDefinition[] = [
  { key: "nutrition", kind: "recurrent", title: "Reprendre la nutrition", usesAi: true },
  {
    key: "enrich_referentials",
    kind: "recurrent",
    title: "Enrichir unités et ingrédients",
    usesAi: true,
  },
  {
    key: "allergens",
    kind: "recurrent",
    title: "Allergènes des ingrédients et des recettes",
    usesAi: true,
  },
  {
    key: "recipe_roles",
    kind: "recurrent",
    title: "Rôle des recettes dans un repas",
    usesAi: true,
  },
  {
    key: "shopping_products",
    kind: "recurrent",
    title: "Recalculer les produits d'achat",
    usesAi: false,
  },
  {
    key: "recipe_protein",
    kind: "ponctuel",
    title: "Protéine et féculent des plats",
    usesAi: true,
  },
  { key: "estimated_times", kind: "ponctuel", title: "Durées estimées", usesAi: true },
  {
    key: "refresh_sodium",
    kind: "ponctuel",
    title: "Reprendre le sel des ingrédients",
    usesAi: true,
  },
  {
    key: "planning_defaults",
    kind: "ponctuel",
    title: "Contraintes de variété par défaut",
    usesAi: false,
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
 * réécrivent tous deux `per100g` des ingrédients. Un passage de l'un est
 * refusé pendant que l'autre tient son verrou.
 */
const LOCK_GROUPS: readonly (readonly BackfillKey[])[] = [
  ["enrich_referentials", "refresh_sodium"],
];

/** Les autres backfills dont le verrou bloque [key]. */
export function lockSiblings(key: BackfillKey): BackfillKey[] {
  const group = LOCK_GROUPS.find((g) => g.includes(key));
  return group ? group.filter((k) => k !== key) : [];
}
