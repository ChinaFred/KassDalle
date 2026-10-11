/**
 * Liste de courses — recalcule `shopping_products` sur toutes les recettes,
 * sans appel de modèle.
 *
 * Le déclencheur d'écriture ne recalcule que si les ingrédients changent :
 * après un changement de règle de regroupement, les recettes existantes
 * garderaient leurs anciennes lignes. Une recette dont le résultat ne change
 * pas n'est pas réécrite.
 *
 * Réentrante, bornée par le délai et par un nombre de documents par appel, et
 * reprend où l'appel précédent s'est arrêté — curseur et compte rendu du
 * dernier passage posés à côté.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { deriveShoppingProducts, type ShoppingProduct } from "../nutrition/shoppingDerivation";
import { shoppingAliasesOrNone, shoppingInputsOf } from "../triggers/recipeShoppingProducts";
import type { StoredIngredient } from "../triggers/recipeIngredients";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import {
  BackfillReview,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient le dernier document examiné. */
export const SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID = "shopping_products_backfill_checkpoint";

const PRODUCTS_FEATURE = "shopping_products_backfill";

/** Recettes recalculées par appel de la fonction, par défaut. */
const DEFAULT_MAX_RECIPES = 500;
const PAGE_SIZE = 200;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois lots difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillShoppingRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

interface BackfillShoppingResponse {
  examinees: number;
  /** `shopping_products` réécrit. */
  recalculees: number;
  /** Résultat identique, rien d'écrit. */
  identiques: number;
  /** Pas d'ingrédients, liste vide. */
  sansIngredients: number;
  /** Page qui n'est pas une recette. */
  horsRecette: number;
  echouees: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
  /** Recettes sans ingrédient ou en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

function emptyResponse(): BackfillShoppingResponse {
  return {
    examinees: 0,
    recalculees: 0,
    identiques: 0,
    sansIngredients: 0,
    horsRecette: 0,
    echouees: 0,
    collectionParcourue: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

interface Bounds {
  deadline: number;
  maxDocs: number;
}

// ── Mode recettes ───────────────────────────────────────────────────────────

/** Forme comparable d'une liste de produits : ce qui est écrit, et rien d'autre. */
function productsSignature(products: unknown): string {
  if (!Array.isArray(products)) return "";
  return JSON.stringify(
    products.map((p) => {
      const record = (p && typeof p === "object" ? p : {}) as Record<string, unknown>;
      return {
        name: typeof record.name === "string" ? record.name : "",
        qty: typeof record.qty === "string" ? record.qty : "",
        unit: typeof record.unit === "string" ? record.unit : "",
      };
    }),
  );
}

async function runProductsMode(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  startAfter: string | null,
): Promise<{ response: BackfillShoppingResponse; cursor: string | null }> {
  const response = emptyResponse();
  const review = new BackfillReview();
  let cursor = startAfter;
  let consecutiveFailures = 0;
  let treated = 0;

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.collectionParcourue = true;
      break;
    }

    // Une lecture du référentiel pour la page entière, pas une par recette.
    const names = new Set<string>();
    for (const doc of page.docs) {
      const ingredients = (doc.get("ingredients") as StoredIngredient[] | undefined) ?? [];
      for (const i of ingredients) if (typeof i.name === "string") names.add(i.name);
    }
    const aliases = await shoppingAliasesOrNone(names, {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      recipeId: `page:${cursor ?? "debut"}`,
    });

    for (const doc of page.docs) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (treated >= bounds.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      const pageType = typeof data.page_type === "string" ? data.page_type : "recipe";
      if (pageType !== "recipe") {
        response.horsRecette += 1;
        cursor = doc.id;
        continue;
      }

      const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
      const products: ShoppingProduct[] =
        ingredients.length === 0
          ? []
          : deriveShoppingProducts(shoppingInputsOf(ingredients, aliases));
      if (ingredients.length === 0) {
        response.sansIngredients += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: "Recette sans ingrédient : liste de courses vide",
        });
      }

      try {
        if (productsSignature(products) === productsSignature(data.shopping_products)) {
          response.identiques += 1;
        } else {
          await doc.ref.update({
            shopping_products: products.map((p) => ({ name: p.name, qty: p.qty, unit: p.unit })),
          });
          response.recalculees += 1;
        }
        treated += 1;
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
        await logError("Produits d'achat — échec sur une recette", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: PRODUCTS_FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { recipeId: doc.id, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    await setBackfillCursor({
      db,
      docId: SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: PRODUCTS_FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      response.collectionParcourue = true;
      break;
    }
  }

  response.aRevoir = review.toJSON();
  return { response, cursor };
}

// ── Point d'entrée ──────────────────────────────────────────────────────────

export const backfillShoppingFn = onCall<BackfillShoppingRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillShoppingResponse> => {
    const ctx = await requireAdmin(req, PRODUCTS_FEATURE);
    const db = getFirestore();

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_RECIPES);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(5000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_RECIPES;
    const bounds: Bounds = {
      deadline: Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS,
      maxDocs,
    };
    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);

    const startAfter = await getBackfillCursor({
      db,
      docId: SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint,
      resetCheckpoint,
    });

    const { response, cursor } = await runProductsMode(db, ctx, bounds, startAfter);
    response.completed = response.collectionParcourue;

    // Le curseur revient au début quand tout est passé ; sinon il retient le
    // dernier document examiné. Le compte rendu part avec lui : l'écran le
    // relit à l'ouverture, pour qui a quitté la page avant la fin du passage.
    await setBackfillCursor({
      db,
      docId: SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID,
      lastDocId: response.collectionParcourue ? null : cursor,
      operation: PRODUCTS_FEATURE,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message: "Produits d'achat des recettes — recalcul",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: PRODUCTS_FEATURE,
      extra: { ...response, maxMinutes, maxDocs },
    });

    return response;
  },
);
