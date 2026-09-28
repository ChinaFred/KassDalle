/**
 * Correction en un coup de la grille tarifaire — `app_config/ai_pricing`.
 *
 * `PRICING_CORRECTIONS` (`../ai/pricing`) porte des valeurs MESURÉES, à la
 * différence de la table d'amorçage qui ne fait que semer le document et peut
 * rester délibérément périmée (voir son commentaire — Sonnet 5). Ce backfill
 * applique cette table à la grille en vigueur : un modèle déjà au bon tarif
 * ressort « déjà correct », un modèle qui en dévie est corrigé et compté.
 *
 * Aucun appel d'IA, un seul document Firestore : ni pagination, ni point de
 * contrôle. Réentrant par nature — relancer après une première correction ne
 * trouve plus rien à corriger.
 */

import { onCall } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import {
  AI_PRICING_DOC_ID,
  PRICING_CORRECTIONS,
  invalidateAiPricingCache,
  parsePricingEntry,
  pricingEntryToMap,
  pricingNeedsCorrection,
} from "../ai/pricing";
import { logInfo } from "../logging";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

interface BackfillPricingResponse {
  corriges: number;
  dejaCorrects: number;
  details: Array<{ model: string; avant: string; apres: string }>;
}

export const backfillAiPricingFn = onCall(
  {
    region: REGION,
    timeoutSeconds: 30,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillPricingResponse> => {
    const ctx = await requireAdmin(req, "backfill_ai_pricing");
    const db = getFirestore();
    const doc = db.collection(COLL_APP_CONFIG).doc(AI_PRICING_DOC_ID);

    const snap = await doc.get();
    const currentModels = (snap.exists ? snap.data()?.models : {}) as
      Record<string, unknown> | undefined;

    const updates: Record<string, unknown> = {};
    const details: BackfillPricingResponse["details"] = [];
    let corriges = 0;
    let dejaCorrects = 0;

    for (const [model, correction] of Object.entries(PRICING_CORRECTIONS)) {
      const current = parsePricingEntry(currentModels?.[model]);
      if (!pricingNeedsCorrection(current, correction)) {
        dejaCorrects += 1;
        continue;
      }
      updates[model] = pricingEntryToMap(correction);
      details.push({
        model,
        avant: current ? `${current.inputPerMillion} $ / ${current.outputPerMillion} $` : "absent",
        apres: `${correction.inputPerMillion} $ / ${correction.outputPerMillion} $`,
      });
      corriges += 1;
    }

    if (corriges > 0) {
      await doc.set(
        {
          models: updates,
          updated_at: FieldValue.serverTimestamp(),
          updated_by: ctx.userId,
        },
        { merge: true },
      );
      // Sans cette invalidation, la correction n'aurait pris effet qu'à
      // l'expiration du cache — un appel facturé juste après le backfill
      // aurait pu encore lire l'ancien tarif.
      invalidateAiPricingCache();
    }

    await logInfo({
      message: "Grille tarifaire — correction en un coup",
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      feature: "backfill_ai_pricing",
      extra: { corriges, dejaCorrects, details },
    });

    return { corriges, dejaCorrects, details };
  },
);
