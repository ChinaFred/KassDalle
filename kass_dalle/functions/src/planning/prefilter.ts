/**
 * Pré-filtrage déterministe des candidats par slot pour la génération de planning.
 *
 * Objectif :
 *  - réduire drastiquement le catalogue envoyé à Gemini (coût tokens, hallucinations d'ids)
 *  - garantir les contraintes dures (durée préparation, no-repeat 7 jours, déjà assignés)
 *    indépendamment de la docilité du modèle
 *  - laisser à l'IA le travail d'arbitrage qualitatif sur un sous-ensemble pertinent
 */

import type {
  DayConstraint,
  PlanningInput,
  PlanningRecipeSummary,
} from "../gemini/planning";

/** Fenêtre glissante (en jours) interdisant qu'une recette utilisée récemment reparaisse. */
export const NO_REPEAT_WINDOW_DAYS = 7;

/** Seuil sous lequel on ne pré-filtre pas (catalogue déjà raisonnable). */
export const PREFILTER_SKIP_THRESHOLD = 30;

/** Nombre maximum de candidats retenus par slot. */
export const TOP_N_PER_SLOT = 20;

export interface PrefilterResult {
  /** Catalogue réduit (union des candidats par slot) à transmettre à Gemini. */
  reducedRecipes: PlanningRecipeSummary[];
  /** Liste ordonnée d'ids candidats par index de slot. */
  candidatesBySlot: Record<number, string[]>;
  /** true si on a réellement appliqué un pré-filtrage. */
  applied: boolean;
}

type SlotKind = "batch" | "reheat" | "regular";

function slotKindFor(
  slotIndex: number,
  slotDates: string[],
  dailyConstraints: Record<number, DayConstraint>,
  batchCookingDay: number | undefined,
): SlotKind {
  const dateStr = slotDates[slotIndex];
  if (!dateStr) return "regular";
  const weekday = ((new Date(dateStr).getUTCDay() + 6) % 7) + 1;
  const constraint = dailyConstraints[weekday];
  const isBatchCookingDay =
    batchCookingDay != null && weekday === batchCookingDay;
  if (isBatchCookingDay) return "batch";
  if (constraint?.isBatchCooking) return "reheat";
  return "regular";
}

function totalCookTime(r: PlanningRecipeSummary): number {
  return (r.prepTime ?? 0) + (r.cookTime ?? 0);
}

/**
 * Pré-filtre les candidats par slot. Retourne le catalogue réduit + l'index des
 * candidats par slot. Si l'input est petit (≤ PREFILTER_SKIP_THRESHOLD), passe
 * tout en revue mais sans rétrécir.
 */
export function preFilterPlanning(input: PlanningInput): PrefilterResult {
  const {
    recipes,
    slotDates,
    dailyConstraints,
    batchCookingDay,
    alreadyAssigned,
    recentHistory,
  } = input;

  // Petit catalogue : on garde tout (mais on calcule quand même candidatesBySlot
  // pour fournir l'indice "Candidats" au prompt).
  const skipReduction = recipes.length <= PREFILTER_SKIP_THRESHOLD;

  // Exclusions globales : recettes déjà assignées dans le cycle courant.
  const alreadyAssignedIds = new Set<string>(
    (alreadyAssigned ?? []).map((a) => a.recipeId),
  );

  // No-repeat 7 jours glissants à partir de l'historique fourni par le client.
  const recentlyUsedIds = new Set<string>(
    (recentHistory ?? [])
      .filter((h) => (h.daysAgo ?? Infinity) < NO_REPEAT_WINDOW_DAYS)
      .map((h) => h.recipeId),
  );

  // Carte daysSinceLastUse pour le scoring (clampée à 60).
  const daysSinceLastUse = new Map<string, number>();
  for (const h of recentHistory ?? []) {
    const v = Math.min(60, Math.max(0, h.daysAgo ?? 60));
    const prev = daysSinceLastUse.get(h.recipeId);
    if (prev == null || v < prev) daysSinceLastUse.set(h.recipeId, v);
  }

  const candidatesBySlot: Record<number, string[]> = {};
  const unionIds = new Set<string>();

  for (let i = 0; i < slotDates.length; i++) {
    const kind = slotKindFor(i, slotDates, dailyConstraints, batchCookingDay);
    const weekday = ((new Date(slotDates[i]).getUTCDay() + 6) % 7) + 1;
    const constraint = dailyConstraints[weekday];
    const maxPrep = constraint?.maxPrepMinutes ?? 0;

    const scored: Array<{ id: string; score: number }> = [];
    for (const r of recipes) {
      // Filtre dur : déjà assigné dans le cycle ⇒ exclu (la continuité
      // batch→réchauffage est gérée côté validation post-IA, pas ici).
      if (alreadyAssignedIds.has(r.id)) continue;
      // Filtre dur : utilisé dans la fenêtre no-repeat 7 jours ⇒ exclu.
      if (recentlyUsedIds.has(r.id)) continue;
      // Filtre dur : durée préparation au-dessus de la limite du jour.
      if (maxPrep > 0 && r.prepTime != null && r.prepTime > maxPrep) continue;

      // Scoring (plus c'est haut, mieux c'est)
      let score = 0;
      // Fraîcheur (jamais cuisinée récemment = mieux)
      const dsu = daysSinceLastUse.get(r.id);
      score += dsu == null ? 30 : Math.min(60, dsu);
      // Bonus batch : sur le slot batch, on aime les recettes "consistantes"
      // (prep + cook plus longs ⇒ supposément batch-friendly).
      if (kind === "batch") {
        score += Math.min(20, Math.floor(totalCookTime(r) / 10));
      }
      // Bonus régulier : si le jour a une limite serrée, on favorise les
      // recettes avec un prepTime court.
      if (kind === "regular" && maxPrep > 0 && r.prepTime != null) {
        score += Math.max(0, 15 - Math.floor(r.prepTime / 5));
      }
      // Jitter déterministe (hash sur id+slot) pour casser les égalités sans
      // randomness non-reproductible.
      score += hashJitter(r.id, i);

      scored.push({ id: r.id, score });
    }

    scored.sort((a, b) => b.score - a.score);
    const top = scored.slice(0, TOP_N_PER_SLOT).map((s) => s.id);
    candidatesBySlot[i] = top;
    for (const id of top) unionIds.add(id);
  }

  if (skipReduction) {
    return {
      reducedRecipes: recipes,
      candidatesBySlot,
      applied: false,
    };
  }

  const reduced = recipes.filter((r) => unionIds.has(r.id));
  return {
    reducedRecipes: reduced,
    candidatesBySlot,
    applied: true,
  };
}

/** Pseudo-aléatoire stable basé sur un hash de chaîne. Renvoie un nombre dans [0, 5]. */
function hashJitter(id: string, slot: number): number {
  let h = 2166136261 ^ slot;
  for (let i = 0; i < id.length; i++) {
    h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  }
  return Math.abs(h % 6);
}
