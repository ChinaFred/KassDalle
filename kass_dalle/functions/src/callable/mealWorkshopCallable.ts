/**
 * « Composer un repas avec l'IA » (Explorer) : les deux entrées HTTPS.
 *
 * `mealWorkshopTurnFn` sert un tour de conversation ; `mealWorkshopRecipeFn`
 * rédige la recette d'un plat figé. Toutes deux exigent un éditeur ou un
 * administrateur : l'atelier mène à des brouillons enregistrés, que le
 * lecteur ne crée pas. Mêmes options que `generateRecipeFn`.
 *
 * Ce fichier branche la logique de `gemini/mealWorkshop.ts` sur Firestore
 * (`meal_workshop_daily`) et traduit les erreurs pour le client. Les règles
 * qui comptent pour la facture :
 *
 *  - la place du jour est **réservée** dans une transaction avant l'appel,
 *    comme `web_search_daily` : deux tours simultanés ne passent pas tous les
 *    deux sur la dernière place ;
 *  - la place n'est **rendue** que si le tour échoue avant que le modèle ait
 *    répondu (plafond de dépense, moteur, quota du fournisseur) : rien n'a
 *    été facturé. Une réponse illisible a été facturée : elle compte ;
 *  - la rédaction d'un plat figé n'a pas de plafond propre : le budget d'IA
 *    du jour seul, par `callModel`.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_MEAL_WORKSHOP_DAILY,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireEditor, type AuthContext } from "./_auth";
import { toHttpsError } from "./_callableErrors";
import { readAiInputs } from "./_inputBounds";
import { BudgetExceededError, budgetMultiplierFor, spendDay } from "../ai/budget";
import {
  MEAL_WORKSHOP_QUOTA_REASON,
  MEAL_WORKSHOP_RECIPE_FEATURE,
  MEAL_WORKSHOP_RECIPE_UNREADABLE_REASON,
  MEAL_WORKSHOP_TURN_FEATURE,
  MEAL_WORKSHOP_UNREADABLE_REASON,
  MealWorkshopRecipeUnreadableError,
  MealWorkshopUnreadableError,
  generateMealWorkshopRecipe,
  mealWorkshopLimit,
  readConversationId,
  readMealWorkshopInput,
  readMealWorkshopRecipeInput,
  remainingTurns,
  runMealWorkshopTurn,
} from "../gemini/mealWorkshop";
import { logError, logWarn } from "../logging";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  // Les deux clés : un secret non déclaré n'est pas monté, et le routeur
  // replierait chaque poste routé vers Claude sur Gemini, silencieusement.
  secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
  memory: "512MiB" as const,
  timeoutSeconds: 300,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

/** Le plafond de tours du jour, tel que le client l'affiche. */
interface TurnQuota {
  limit: number;
  remaining: number;
}

function readTurnCount(data: FirebaseFirestore.DocumentData | undefined): number {
  const n = data?.count;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

function logContext(ctx: AuthContext, feature: string) {
  return {
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature,
    moduleType: "SEARCH" as const,
  };
}

/**
 * Rend une place réservée. Un remboursement raté laisse le compteur plus
 * haut d'une unité : le plafond devient plus strict, jamais plus large.
 */
async function refundTurn(
  counter: FirebaseFirestore.DocumentReference,
  log: ReturnType<typeof logContext>,
): Promise<void> {
  try {
    await getFirestore().runTransaction(async (tx) => {
      const used = readTurnCount((await tx.get(counter)).data());
      if (used <= 0) return;
      tx.set(counter, { count: used - 1, updated_at: Timestamp.now() }, { merge: true });
    });
  } catch (err) {
    await logError({
      ...log,
      message: "Atelier repas : place non rendue après une erreur",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
  }
}

export const mealWorkshopTurnFn = onCall(opts, async (req) => {
  const ctx = await requireEditor(req, MEAL_WORKSHOP_TURN_FEATURE);
  const data = (req.data ?? {}) as Record<string, unknown>;
  // Bornes lues avant toute réservation et tout appel : un 21e tour ou un
  // message trop long est refusé sans consommer de place (tailles seules
  // journalisées, jamais le contenu).
  const { conversationId, input } = await readAiInputs(
    { ...ctx, feature: MEAL_WORKSHOP_TURN_FEATURE },
    (inputs) => ({
      conversationId: readConversationId(data.conversationId, inputs),
      input: readMealWorkshopInput(data, inputs),
    }),
  );
  const log = logContext(ctx, MEAL_WORKSHOP_TURN_FEATURE);
  const limit = mealWorkshopLimit(await budgetMultiplierFor(ctx.userId));
  const db = getFirestore();
  const day = spendDay(new Date());
  const counter = db.collection(COLL_MEAL_WORKSHOP_DAILY).doc(`${ctx.userId}_${day}`);

  // Réservation : `count + 1` si une place reste, `null` sinon.
  let used: number | null;
  try {
    used = await db.runTransaction(async (tx) => {
      const current = readTurnCount((await tx.get(counter)).data());
      if (current >= limit) return null;
      tx.set(
        counter,
        {
          uid: ctx.userId,
          day,
          count: FieldValue.increment(1),
          limit,
          updated_at: Timestamp.now(),
        },
        { merge: true },
      );
      return current + 1;
    });
  } catch (err) {
    await logError({
      ...log,
      message: "Atelier repas : réservation du tour impossible, aucun appel",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { conversationId, turn: input.turn },
    });
    throw await toHttpsError(err, { alreadyLogged: true });
  }
  if (used === null) {
    await logWarn({
      ...log,
      message: "Atelier repas : tour refusé, plafond du jour atteint",
      extra: { conversationId, turn: input.turn, limit },
    });
    throw new HttpsError("resource-exhausted", `Vous avez fait vos ${limit} tours d'aujourd'hui.`, {
      reason: MEAL_WORKSHOP_QUOTA_REASON,
      limit,
      remaining: 0,
    });
  }
  const quota: TurnQuota = { limit, remaining: remainingTurns(used, limit) };

  try {
    const result = await runMealWorkshopTurn({
      input,
      conversationId,
      ctx: { ...ctx, feature: MEAL_WORKSHOP_TURN_FEATURE, moduleType: "SEARCH" },
    });
    return { ...result, quota };
  } catch (err) {
    if (err instanceof MealWorkshopUnreadableError) {
      // Le modèle a répondu : facturé, la place reste prise. Déjà journalisé
      // par `runMealWorkshopTurn`, longueurs seules.
      throw new HttpsError("internal", err.message, {
        reason: MEAL_WORKSHOP_UNREADABLE_REASON,
        quota,
        turn: err.turn,
      });
    }
    // Rien n'a été facturé : la place est rendue. Un plafond d'IA est un
    // refus attendu, au message rédigé pour le membre — pas de ligne ERROR.
    await refundTurn(counter, log);
    const description = err instanceof Error ? err.message : String(err);
    if (err instanceof BudgetExceededError) {
      await logWarn({
        ...log,
        message: "Atelier repas : tour refusé par le plafond d'IA du jour, place rendue",
        errorDescription: description,
        extra: { conversationId, turn: input.turn, budget: err.reason },
      });
    } else {
      await logError({
        ...log,
        message: "Atelier repas : tour échoué avant la réponse du modèle, place rendue",
        errorDescription: description,
        extra: {
          conversationId,
          turn: input.turn,
          errorName: err instanceof Error ? err.name : typeof err,
        },
      });
    }
    throw await toHttpsError(err, { alreadyLogged: true });
  }
});

export const mealWorkshopRecipeFn = onCall(opts, async (req) => {
  const ctx = await requireEditor(req, MEAL_WORKSHOP_RECIPE_FEATURE);
  const data = (req.data ?? {}) as Record<string, unknown>;
  const input = await readAiInputs({ ...ctx, feature: MEAL_WORKSHOP_RECIPE_FEATURE }, (inputs) =>
    readMealWorkshopRecipeInput(data, inputs),
  );
  try {
    return await generateMealWorkshopRecipe(input, {
      ...ctx,
      feature: MEAL_WORKSHOP_RECIPE_FEATURE,
      moduleType: "DESIGN",
    });
  } catch (err) {
    if (err instanceof MealWorkshopRecipeUnreadableError) {
      // Facturé, déjà journalisé par `generateMealWorkshopRecipe`.
      throw new HttpsError("internal", err.message, {
        reason: MEAL_WORKSHOP_RECIPE_UNREADABLE_REASON,
      });
    }
    throw await toHttpsError(err);
  }
});
