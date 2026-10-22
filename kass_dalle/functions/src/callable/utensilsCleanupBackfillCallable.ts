/**
 * Ustensiles — retire des recettes existantes les ustensiles écrits comme
 * ingrédients, puis supprime leurs fiches du référentiel nutrition. Aucun
 * appel de modèle.
 *
 * Entre v0.21.31 et v0.24.56, le balisage pouvait écrire « @papier
 * sulfurisé{} » : le nom entrait dans `ingredients`, dans `ingredients_index`,
 * puis dans le référentiel (`nutrition_ingredients/papier_sulfurise`). Depuis
 * v0.24.57, la liste fermée `nutrition/utensils.ts` l'empêche pour les
 * nouvelles recettes. Ce backfill reprend les anciennes.
 *
 * Deux phases :
 *  1. Recettes : `@nom{…}` devient `#nom{…}` dans `raw_cooklang` et
 *     `draft_cooklang` (`retagUtensils`), et les ustensiles sortent de
 *     `ingredients` et de `ingredients_index`. L'écriture réveille
 *     `onRecipeWritten`, qui recalcule nutrition, courses et allergènes comme
 *     après toute modification d'ingrédients.
 *  2. Fiches : une fois toutes les recettes parcourues, une fiche dont
 *     l'identifiant ou le nom canonique est un ustensile est supprimée, si
 *     plus aucune recette ne la cite dans `ingredients_index`. Une fiche
 *     encore citée reste, et part dans la liste « à revoir ».
 *
 * Essai à blanc (`dryRun`) : rien n'est écrit ni supprimé ; chaque recette et
 * chaque fiche qui seraient corrigées partent dans la liste « à revoir », avec
 * ce qui changerait. Son curseur est distinct de celui du passage réel.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import {
  COLL_NUTRITION_INGREDIENTS,
  COLL_RECIPES,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { isUtensil, retagUtensils } from "../nutrition/utensils";
import type { StoredIngredient } from "../triggers/recipeIngredients";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  namesList,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où le passage réel retient la dernière recette examinée. */
export const UTENSILS_CLEANUP_CHECKPOINT_DOC_ID = "utensils_cleanup_backfill_checkpoint";
/** Curseur de l'essai à blanc : il ne déplace jamais celui du passage réel. */
export const UTENSILS_CLEANUP_DRY_RUN_CHECKPOINT_DOC_ID =
  "utensils_cleanup_dry_run_backfill_checkpoint";

const FEATURE = "utensils_cleanup_backfill";

/** Recettes examinées par appel, par défaut. */
const DEFAULT_MAX_RECIPES = 2000;
const PAGE_SIZE = 200;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;
/** Plafond de valeurs d'un `array-contains-any` Firestore. */
const MAX_USAGE_VALUES = 30;

interface UtensilsCleanupRequest {
  dryRun?: boolean;
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface UtensilsCleanupResponse {
  essaiABlanc: boolean;
  examinees: number;
  /** Recettes réécrites (ou qui le seraient, à blanc). */
  corrigees: number;
  /** Rien à changer. */
  dejaPropres: number;
  echouees: number;
  /** Fiches du référentiel dont le nom est un ustensile. */
  fichesTrouvees: number;
  /** Fiches supprimées (ou qui le seraient, à blanc). */
  fichesSupprimees: number;
  /** Fiches laissées : une recette les cite encore. */
  fichesEncoreCitees: number;
  fichesEchouees: number;
  /** Toutes les recettes ont été parcourues : le curseur revient au début. */
  recettesParcourues: boolean;
  /** La phase des fiches a eu lieu en entier. */
  fichesParcourues: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  aRevoir: BackfillReviewList;
}

function emptyResponse(dryRun: boolean): UtensilsCleanupResponse {
  return {
    essaiABlanc: dryRun,
    examinees: 0,
    corrigees: 0,
    dejaPropres: 0,
    echouees: 0,
    fichesTrouvees: 0,
    fichesSupprimees: 0,
    fichesEncoreCitees: 0,
    fichesEchouees: 0,
    recettesParcourues: false,
    fichesParcourues: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

/** Ce qu'une recette deviendrait, et les ustensiles retirés. */
export interface RecipeCleanup {
  /** Champs à écrire ; vide quand la recette est déjà propre. */
  patch: Record<string, unknown>;
  /** Noms des ustensiles retirés, sans doublon, dans l'ordre rencontré. */
  removed: string[];
}

/** Noms écrits `@nom{…}` qui désignent un ustensile. */
function taggedUtensilNames(cooklang: string): string[] {
  const out: string[] = [];
  for (const m of cooklang.matchAll(/@([^{@#~\n]+)\{[^}]*\}/g)) {
    const name = m[1].trim();
    if (isUtensil(name)) out.push(name);
  }
  return out;
}

/**
 * Le nettoyage d'une recette, sans rien écrire : pure, testée seule.
 *
 * Un champ absent ou d'un autre type n'est pas touché.
 */
export function cleanupRecipe(data: Record<string, unknown>): RecipeCleanup {
  const patch: Record<string, unknown> = {};
  const removed: string[] = [];
  const note = (name: string) => {
    const clean = name.trim();
    if (clean && !removed.some((r) => r.toLowerCase() === clean.toLowerCase())) {
      removed.push(clean);
    }
  };

  for (const field of ["raw_cooklang", "draft_cooklang"] as const) {
    const text = data[field];
    if (typeof text !== "string") continue;
    const retagged = retagUtensils(text);
    if (retagged !== text) {
      patch[field] = retagged;
      taggedUtensilNames(text).forEach(note);
    }
  }

  if (Array.isArray(data.ingredients)) {
    const ingredients = data.ingredients as StoredIngredient[];
    const kept = ingredients.filter((i) => {
      const name = typeof i?.name === "string" ? i.name : "";
      if (!isUtensil(name)) return true;
      note(name);
      return false;
    });
    if (kept.length !== ingredients.length) patch.ingredients = kept;
  }

  if (Array.isArray(data.ingredients_index)) {
    const index = data.ingredients_index as unknown[];
    const kept = index.filter((n) => {
      if (typeof n !== "string" || !isUtensil(n)) return true;
      note(n);
      return false;
    });
    if (kept.length !== index.length) patch.ingredients_index = kept;
  }

  return { patch, removed };
}

/**
 * Valeurs cherchées dans `ingredients_index` pour une fiche : nom canonique,
 * identifiant lu comme un nom, puis alias — en minuscules, sans doublon, comme
 * l'index (`buildIngredientsIndex`). Même ordre que l'écran Ingrédients
 * nutrition (`ingredientUsageSearchValues`).
 */
export function sheetUsageValues(id: string, data: Record<string, unknown>): string[] {
  const names: string[] = [];
  if (typeof data.canonical_name === "string") names.push(data.canonical_name);
  names.push(id.replaceAll("_", " "));
  if (Array.isArray(data.aliases)) {
    for (const a of data.aliases) if (typeof a === "string") names.push(a);
  }
  const seen = new Set<string>();
  const out: string[] = [];
  for (const n of names) {
    const v = n.trim().toLowerCase();
    if (!v || seen.has(v)) continue;
    seen.add(v);
    out.push(v);
  }
  return out.slice(0, MAX_USAGE_VALUES);
}

/** Vrai quand la fiche désigne un ustensile, par son identifiant ou son nom canonique. */
export function isUtensilSheet(id: string, data: Record<string, unknown>): boolean {
  const canonical = typeof data.canonical_name === "string" ? data.canonical_name : "";
  return isUtensil(id.replaceAll("_", " ")) || (canonical !== "" && isUtensil(canonical));
}

interface Bounds {
  deadline: number;
  maxDocs: number;
}

// ── Phase 1 : recettes ──────────────────────────────────────────────────────

async function runRecipesPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  startAfter: string | null,
  dryRun: boolean,
  response: UtensilsCleanupResponse,
  review: BackfillReview,
  checkpointDocId: string,
): Promise<string | null> {
  let cursor = startAfter;
  let consecutiveFailures = 0;

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.recettesParcourues = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (response.examinees >= bounds.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      const { patch, removed } = cleanupRecipe(data);
      if (Object.keys(patch).length === 0) {
        response.dejaPropres += 1;
        cursor = doc.id;
        continue;
      }

      if (dryRun) {
        response.corrigees += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Essai à blanc : ${namesList(removed)} ${
            removed.length > 1 ? "seraient retirés" : "serait retiré"
          } des ingrédients`,
        });
        cursor = doc.id;
        continue;
      }

      try {
        await doc.ref.update(patch);
        response.corrigees += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec d'écriture : ${shortErrorMessage(e)}`,
        });
        await logError("Ustensiles — échec sur une recette", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { recipeId: doc.id, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    await setBackfillCursor({
      db,
      docId: checkpointDocId,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      response.recettesParcourues = true;
      break;
    }
  }

  return cursor;
}

// ── Phase 2 : fiches du référentiel ─────────────────────────────────────────

async function runSheetsPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  dryRun: boolean,
  response: UtensilsCleanupResponse,
  review: BackfillReview,
): Promise<void> {
  // Le référentiel compte quelques milliers de fiches : une lecture, sans
  // curseur. La phase est sautée tant qu'une recette peut encore citer une
  // fiche ; elle se rejoue entière au passage suivant si le délai l'arrête.
  const sheets = await db.collection(COLL_NUTRITION_INGREDIENTS).get();
  for (const doc of sheets.docs) {
    const data = doc.data() as Record<string, unknown>;
    if (!isUtensilSheet(doc.id, data)) continue;
    if (Date.now() > bounds.deadline) {
      response.stoppedByDeadline = true;
      return;
    }
    response.fichesTrouvees += 1;
    const label =
      typeof data.canonical_name === "string" && data.canonical_name.trim()
        ? data.canonical_name.trim()
        : doc.id;

    try {
      const values = sheetUsageValues(doc.id, data);
      const users = await db
        .collection(COLL_RECIPES)
        .where("ingredients_index", "array-contains-any", values)
        .limit(1)
        .get();
      // À blanc, les recettes n'ont pas été corrigées : une recette qui la
      // cite encore est celle que le passage réel corrigera d'abord.
      if (!users.empty && !dryRun) {
        response.fichesEncoreCitees += 1;
        const first = users.docs[0];
        review.add({
          kind: "ingredient",
          id: doc.id,
          label,
          reason: `Fiche gardée : encore citée par « ${recipeReviewLabel(
            first.id,
            first.data() as Record<string, unknown>,
          )} »`,
        });
        continue;
      }
      if (dryRun) {
        response.fichesSupprimees += 1;
        review.add({
          kind: "ingredient",
          id: doc.id,
          label,
          reason: "Essai à blanc : fiche d'ustensile, serait supprimée",
        });
        continue;
      }
      await doc.ref.delete();
      response.fichesSupprimees += 1;
    } catch (e) {
      response.fichesEchouees += 1;
      review.add({
        kind: "ingredient",
        id: doc.id,
        label,
        reason: `Échec de suppression : ${shortErrorMessage(e)}`,
      });
      await logError("Ustensiles — échec sur une fiche du référentiel", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { ingredientId: doc.id },
      });
    }
  }
  response.fichesParcourues = true;
}

// ── Point d'entrée ──────────────────────────────────────────────────────────

export const backfillUtensilsCleanupFn = onCall<UtensilsCleanupRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_RECIPES);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(5000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: UtensilsCleanupPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxDocs,
      // Par défaut à blanc : un appel sans l'argument n'écrit rien.
      dryRun: parseBoolean(req.data?.dryRun, true),
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "utensils_cleanup",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runUtensilsCleanupPass(ctx, options),
      summarize: summarizeUtensilsCleanup,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface UtensilsCleanupPassOptions {
  /** Instant de fin du passage ; la marge d'écriture du curseur est déduite ici. */
  deadlineMs: number;
  maxDocs: number;
  dryRun: boolean;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/**
 * Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`).
 *
 * Un essai à blanc qui trouve quelque chose le met dans « à revoir » : il ne
 * peut donc marquer le backfill terminé que s'il ne trouve rien à corriger.
 */
export function summarizeUtensilsCleanup(r: UtensilsCleanupResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Une écriture en échec se retente au passage suivant, sans appel de
    // modèle.
    unresolved: 0,
  };
}

export async function runUtensilsCleanupPass(
  ctx: AuthContext,
  options: UtensilsCleanupPassOptions,
): Promise<UtensilsCleanupResponse> {
  const db = getFirestore();
  const bounds: Bounds = {
    deadline: options.deadlineMs - DEADLINE_MARGIN_MS,
    maxDocs: options.maxDocs,
  };
  const checkpointDocId = options.dryRun
    ? UTENSILS_CLEANUP_DRY_RUN_CHECKPOINT_DOC_ID
    : UTENSILS_CLEANUP_CHECKPOINT_DOC_ID;
  const response = emptyResponse(options.dryRun);
  const review = new BackfillReview();

  const startAfter = await getBackfillCursor({
    db,
    docId: checkpointDocId,
    resumeFromCheckpoint: options.resumeFromCheckpoint,
    resetCheckpoint: options.resetCheckpoint,
  });

  const cursor = await runRecipesPhase(
    db,
    ctx,
    bounds,
    startAfter,
    options.dryRun,
    response,
    review,
    checkpointDocId,
  );

  // Les fiches ne partent qu'après le parcours de toutes les recettes : avant,
  // une recette non encore corrigée en citerait une, et la recréerait à sa
  // prochaine écriture.
  if (response.recettesParcourues) {
    await runSheetsPhase(db, ctx, bounds, options.dryRun, response, review);
  }

  response.completed =
    response.recettesParcourues && response.fichesParcourues && response.echouees === 0;

  // Le curseur revient au début quand toutes les recettes sont passées ; sinon
  // il retient la dernière examinée.
  await setBackfillCursor({
    db,
    docId: checkpointDocId,
    lastDocId: response.recettesParcourues ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  response.aRevoir = review.toJSON();

  await logInfo({
    message: options.dryRun
      ? "Ustensiles des recettes — essai à blanc"
      : "Ustensiles des recettes — nettoyage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
