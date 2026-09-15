/**
 * Liste de courses — deux reprises de l'existant, une seule fonction.
 *
 * `mode: "aliases"` — le PRODUIT ACHETÉ de chaque ingrédient du référentiel.
 * « Beurre fondu » s'achète en beurre, « jaune d'œuf » en œufs : ce jugement
 * était rendu par le modèle quand il composait la liste, et l'addition qui l'a
 * remplacé ne le rend pas. Une fois pour toutes, par lots de quarante noms, le
 * modèle dit pour chaque ingrédient sans `shopping_product` ce qu'on achète.
 * Le champ vide veut dire « le nom est déjà le produit » : l'ingrédient n'est
 * pas redemandé. Poste de coût `backfill_shopping_aliases`. Aucun appel par
 * recette ensuite.
 *
 * `mode: "products"` — RECALCULE `shopping_products` sur toutes les recettes,
 * sans appel de modèle. Le déclencheur d'écriture ne recalcule que si les
 * ingrédients changent : après un changement de règle de regroupement, ou un
 * alias posé, les recettes existantes garderaient leurs anciennes lignes. Une
 * recette dont le résultat ne change pas n'est pas réécrite.
 *
 * Les deux modes sont réentrants, bornés par le délai et par un nombre de
 * documents par appel, et reprennent où l'appel précédent s'est arrêté — un
 * curseur par mode, le compte rendu du dernier passage posé à côté.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_NUTRITION_INGREDIENTS,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { deriveShoppingProducts, type ShoppingProduct } from "../nutrition/shoppingDerivation";
import { writeDocsMerged } from "../nutrition/firestoreBatch";
import {
  resolveShoppingAliasBatch,
  type ShoppingAliasCandidate,
} from "../nutrition/shoppingAliases";
import { shoppingAliasesOrNone, shoppingInputsOf } from "../triggers/recipeShoppingProducts";
import type { StoredIngredient } from "../triggers/recipeIngredients";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où chaque mode retient le dernier document examiné. */
export const SHOPPING_ALIASES_CHECKPOINT_DOC_ID = "shopping_aliases_backfill_checkpoint";
export const SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID = "shopping_products_backfill_checkpoint";

const ALIASES_FEATURE = "backfill_shopping_aliases";
const PRODUCTS_FEATURE = "shopping_products_backfill";

/** Ingrédients soumis au modèle en un appel. */
const ALIAS_BATCH = 40;
/** Ingrédients demandés au modèle par appel de la fonction, par défaut. */
const DEFAULT_MAX_ALIASES = 400;
/** Recettes recalculées par appel de la fonction, par défaut. */
const DEFAULT_MAX_RECIPES = 500;
const PAGE_SIZE = 200;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois lots difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

type Mode = "aliases" | "products";

interface BackfillShoppingRequest {
  mode?: Mode;
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Redemander aussi les ingrédients qui portent déjà un produit acheté. */
  force?: boolean;
}

interface BackfillShoppingResponse {
  mode: Mode;
  examinees: number;
  /** Mode alias : ingrédients qui portaient déjà le champ. */
  dejaRenseignes: number;
  /** Mode alias : un produit différent du nom a été posé. */
  renseignes: number;
  /** Mode alias : le nom est déjà le produit — champ vide posé. */
  inchanges: number;
  /** Mode alias : le modèle n'a rien dit pour cet ingrédient ; redemandé au prochain passage. */
  sansReponse: number;
  /** Mode recettes : `shopping_products` réécrit. */
  recalculees: number;
  /** Mode recettes : résultat identique, rien d'écrit. */
  identiques: number;
  /** Mode recettes : pas d'ingrédients, liste vide. */
  sansIngredients: number;
  /** Mode recettes : page qui n'est pas une recette. */
  horsRecette: number;
  echouees: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
}

function emptyResponse(mode: Mode): BackfillShoppingResponse {
  return {
    mode,
    examinees: 0,
    dejaRenseignes: 0,
    renseignes: 0,
    inchanges: 0,
    sansReponse: 0,
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
  };
}

interface Bounds {
  deadline: number;
  maxDocs: number;
  force: boolean;
}

// ── Mode alias ──────────────────────────────────────────────────────────────

/** Nom lisible d'un document du référentiel : son nom canonique, sinon son identifiant. */
function ingredientDisplayName(id: string, data: Record<string, unknown>): string {
  const canonical = typeof data.canonical_name === "string" ? data.canonical_name.trim() : "";
  return canonical || id.replace(/_/g, " ");
}

/**
 * Demande au modèle le produit acheté d'un lot d'ingrédients, et l'écrit.
 *
 * La résolution — prompt, repli sur un produit déjà connu du référentiel —
 * est partagée avec l'écriture automatique d'un ingrédient neuf
 * (`resolveShoppingAliasBatch`) : un seul endroit décide ce qu'on achète.
 * Ici s'ajoutent les compteurs du passage et l'écriture Firestore.
 */
async function askAliasesForBatch(
  batch: ShoppingAliasCandidate[],
  ctx: AuthContext,
  counters: BackfillShoppingResponse,
): Promise<void> {
  const resolutions = await resolveShoppingAliasBatch(batch, {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: ALIASES_FEATURE,
  });

  const updates = new Map<string, Record<string, unknown>>();
  for (const r of resolutions) {
    updates.set(r.id, {
      shopping_product: r.product,
      shopping_product_source: "ai_estimated",
      updated_at: FieldValue.serverTimestamp(),
    });
    if (r.product === "") counters.inchanges += 1;
    else counters.renseignes += 1;
  }
  counters.sansReponse += batch.length - resolutions.length;
  await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);
}

async function runAliasesMode(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  startAfter: string | null,
): Promise<{ response: BackfillShoppingResponse; cursor: string | null }> {
  const response = emptyResponse("aliases");
  let cursor = startAfter;
  let consecutiveFailures = 0;
  let asked = 0;
  let batch: ShoppingAliasCandidate[] = [];

  const flush = async (): Promise<void> => {
    if (batch.length === 0) return;
    const current = batch;
    batch = [];
    try {
      await askAliasesForBatch(current, ctx, response);
      consecutiveFailures = 0;
    } catch (e) {
      response.echouees += current.length;
      consecutiveFailures += 1;
      await logError("Produit acheté des ingrédients — échec d'un lot", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        geminiStatus: "ERROR",
        feature: ALIASES_FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { lot: current.map((p) => p.name), consecutiveFailures },
      });
    }
  };

  pages: for (;;) {
    let query = db.collection(COLL_NUTRITION_INGREDIENTS).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.collectionParcourue = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (asked >= bounds.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      if (!bounds.force && typeof data.shopping_product === "string") {
        response.dejaRenseignes += 1;
        cursor = doc.id;
        continue;
      }
      batch.push({ id: doc.id, name: ingredientDisplayName(doc.id, data) });
      asked += 1;
      cursor = doc.id;
      if (batch.length >= ALIAS_BATCH) await flush();
    }

    await flush();
    await setBackfillCursor({
      db,
      docId: SHOPPING_ALIASES_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: ALIASES_FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      response.collectionParcourue = true;
      break;
    }
  }
  await flush();

  return { response, cursor };
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
  const response = emptyResponse("products");
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
      if (ingredients.length === 0) response.sansIngredients += 1;

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
    const mode = req.data?.mode;
    if (mode !== "aliases" && mode !== "products") {
      throw new HttpsError("invalid-argument", "mode attendu : « aliases » ou « products »");
    }
    const feature = mode === "aliases" ? ALIASES_FEATURE : PRODUCTS_FEATURE;
    const checkpointDocId =
      mode === "aliases" ? SHOPPING_ALIASES_CHECKPOINT_DOC_ID : SHOPPING_PRODUCTS_CHECKPOINT_DOC_ID;
    const defaultMaxDocs = mode === "aliases" ? DEFAULT_MAX_ALIASES : DEFAULT_MAX_RECIPES;

    const ctx = await requireAdmin(req, feature);
    const db = getFirestore();

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? defaultMaxDocs);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(5000, Math.trunc(maxDocsRaw)))
      : defaultMaxDocs;
    const bounds: Bounds = {
      deadline: Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS,
      maxDocs,
      force: parseBoolean(req.data?.force, false),
    };
    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);

    const startAfter = await getBackfillCursor({
      db,
      docId: checkpointDocId,
      resumeFromCheckpoint,
      resetCheckpoint,
    });

    const { response, cursor } =
      mode === "aliases"
        ? await runAliasesMode(db, ctx, bounds, startAfter)
        : await runProductsMode(db, ctx, bounds, startAfter);
    response.completed = response.collectionParcourue;

    // Le curseur revient au début quand tout est passé ; sinon il retient le
    // dernier document examiné. Le compte rendu part avec lui : l'écran le
    // relit à l'ouverture, pour qui a quitté la page avant la fin du passage.
    await setBackfillCursor({
      db,
      docId: checkpointDocId,
      lastDocId: response.collectionParcourue ? null : cursor,
      operation: feature,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message:
        mode === "aliases"
          ? "Produit acheté des ingrédients — rattrapage"
          : "Produits d'achat des recettes — recalcul",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature,
      extra: { ...response, maxMinutes, maxDocs, force: bounds.force },
    });

    return response;
  },
);
