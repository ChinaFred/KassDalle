/**
 * Pilotage de la politique de routage IA.
 *
 * Basculer un poste fonctionnel d'un moteur à l'autre doit être un geste
 * d'administration, pas un déploiement : sans cela, personne ne comparera
 * jamais deux moteurs sur des données réelles — on comparerait des intentions.
 *
 * Lecture ouverte aux administrateurs, écriture réservée aux administrateurs.
 * Le poste `feature` est la même clé que celle du reporting de coûts : c'est ce
 * qui permet de lire, sur le même écran, ce qu'un moteur coûte et ce qu'il rend.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { REGION, COLL_APP_CONFIG, ANTHROPIC_API_KEY } from "../config";
import { requireAdmin } from "./_auth";
import { anthropicApiKey } from "../ai/anthropic";
import {
  AI_ROUTING_POLICY_DOC_ID,
  DEFAULT_AI_ROUTING_POLICY,
  getAiRoutingPolicy,
  type AiRoutingPolicy,
} from "../ai/router";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
  // Le secret est monté ici sans qu'aucun appel Claude n'ait lieu : c'est ce
  // qui permet à l'écran d'affirmer que la clé est réellement disponible, au
  // lieu de le supposer. Une bascule sans effet est autrement indéchiffrable.
  secrets: [ANTHROPIC_API_KEY],
};

const PROVIDERS = ["gemini", "anthropic"] as const;

/**
 * Postes fonctionnels routables, avec leur libellé.
 *
 * Liste explicite plutôt que texte libre : un poste mal orthographié dans une
 * politique ne produirait aucune erreur — il ne router­ait simplement jamais
 * rien, et on chercherait longtemps pourquoi la bascule « ne marche pas ».
 */
export const ROUTABLE_FEATURES: Array<{ id: string; label: string }> = [
  {
    id: "nutrition_ingredients_enrichment_batch",
    label: "Nutrition — estimation par lots",
  },
  {
    id: "nutrition_ingredients_enrichment",
    label: "Nutrition — estimation d'un ingrédient",
  },
  {
    id: "inline_ingredient_per100g_enrichment_batch",
    label: "Nutrition — lot pendant la normalisation",
  },
  {
    id: "inline_ingredient_per100g_enrichment",
    label: "Nutrition — rattrapage pendant la normalisation",
  },
  {
    id: "nutrition_ingredients_enrichment_auto_batch",
    label: "Nutrition — lot au déclencheur de recette",
  },
  {
    id: "backfill_enrich_referentials_per100g_batch",
    label: "Nutrition — lot du backfill administrateur",
  },
];

export const getAiRoutingPolicyFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req);
  const policy = await getAiRoutingPolicy();
  return {
    policy,
    // L'écran doit pouvoir dire « routé vers Claude mais la clé n'est pas
    // posée » : sans cette information, une bascule sans effet reste une
    // énigme pour celui qui l'a demandée.
    anthropicKeyPresent: anthropicApiKey() != null,
    routableFeatures: ROUTABLE_FEATURES,
  };
});

interface SetAiRoutingPolicyRequest {
  policy?: Partial<AiRoutingPolicy>;
}

export const setAiRoutingPolicyFn = onCall<SetAiRoutingPolicyRequest>(
  callableOpts,
  async (req) => {
    await requireAdmin(req);

    const next = req.data?.policy;
    if (!next) {
      throw new HttpsError("invalid-argument", "policy est requis.");
    }

    const defaultProvider = next.defaultProvider ?? DEFAULT_AI_ROUTING_POLICY.defaultProvider;
    if (!PROVIDERS.includes(defaultProvider)) {
      throw new HttpsError(
        "invalid-argument",
        `defaultProvider doit valoir ${PROVIDERS.join(" ou ")}.`,
      );
    }

    const knownFeatureIds = new Set(ROUTABLE_FEATURES.map((f) => f.id));
    const features: Record<string, string> = {};
    for (const [feature, provider] of Object.entries(next.features ?? {})) {
      if (!knownFeatureIds.has(feature)) {
        throw new HttpsError("invalid-argument", `Poste inconnu : ${feature}.`);
      }
      if (!PROVIDERS.includes(provider as (typeof PROVIDERS)[number])) {
        throw new HttpsError(
          "invalid-argument",
          `Fournisseur invalide pour ${feature} : ${provider}.`,
        );
      }
      features[feature] = provider;
    }

    const anthropicModel = (next.anthropicModel ?? DEFAULT_AI_ROUTING_POLICY.anthropicModel).trim();
    if (!anthropicModel) {
      throw new HttpsError("invalid-argument", "anthropicModel ne peut pas être vide.");
    }

    await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(AI_ROUTING_POLICY_DOC_ID)
      .set(
        {
          default_provider: defaultProvider,
          features,
          anthropic_model: anthropicModel,
          fallback_enabled: next.fallbackEnabled !== false,
          updated_at: FieldValue.serverTimestamp(),
          updated_by: req.auth?.uid ?? null,
        },
        { merge: true },
      );

    return {
      policy: {
        defaultProvider,
        features,
        anthropicModel,
        fallbackEnabled: next.fallbackEnabled !== false,
      },
      anthropicKeyPresent: anthropicApiKey() != null,
    };
  },
);
