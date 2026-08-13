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
 * Postes fonctionnels routables, avec leur libellé et leur famille.
 *
 * Un poste n'apparaît ici que si son code passe réellement par `callModel`.
 * Les seuls appels d'IA volontairement absents sont ceux qui **produisent** une
 * image (`enhance_illustration`, `generate_recipe_illustration`) : Claude n'en
 * fabrique pas, les proposer à la bascule serait une promesse fausse.
 *
 * Liste explicite plutôt que texte libre : un poste mal orthographié dans une
 * politique ne produirait aucune erreur — il ne router­ait simplement jamais
 * rien, et on chercherait longtemps pourquoi la bascule « ne marche pas ».
 */
export const ROUTABLE_FEATURES: Array<{ id: string; label: string; group: string }> = [
  // ── Import ────────────────────────────────────────────────────────────────
  { id: "scan_extraction", label: "Extraction d'un scan de page", group: "Import" },
  { id: "text_extraction", label: "Extraction depuis un texte libre", group: "Import" },
  { id: "classify_page", label: "Classification d'une page", group: "Import" },
  { id: "document_extraction", label: "Extraction d'un document non-recette", group: "Import" },
  { id: "book_cover", label: "Lecture d'une couverture de livre", group: "Import" },

  // ── Illustrations ─────────────────────────────────────────────────────────
  { id: "detect_main_photo", label: "Détection de la photo principale", group: "Illustrations" },
  { id: "detect_illustrations", label: "Détection des illustrations", group: "Illustrations" },
  {
    id: "detect_illustrations_crop",
    label: "Détection — seconde passe sur recadrage",
    group: "Illustrations",
  },
  {
    id: "detect_illustrations_grid",
    label: "Détection — repli pleine page",
    group: "Illustrations",
  },
  { id: "detect_grid_dims", label: "Détection — dimensions d'une grille", group: "Illustrations" },

  // ── Rédaction ─────────────────────────────────────────────────────────────
  { id: "generate", label: "Génération d'une recette", group: "Rédaction" },
  { id: "refine", label: "Modification d'une recette", group: "Rédaction" },
  { id: "polish_cooklang", label: "Relecture d'un CookLang", group: "Rédaction" },
  { id: "polish_markdown", label: "Relecture d'un document Markdown", group: "Rédaction" },
  { id: "suggest_tags", label: "Suggestion de tags", group: "Rédaction" },
  { id: "plating_coach", label: "Conseil de dressage", group: "Rédaction" },

  // ── Recherche ─────────────────────────────────────────────────────────────
  { id: "search", label: "Recherche dans la collection", group: "Recherche" },
  { id: "web_search_query", label: "Formulation d'une requête web", group: "Recherche" },

  // ── Planning ──────────────────────────────────────────────────────────────
  { id: "planning", label: "Suggestion de planning", group: "Planning" },
  {
    id: "planning_concept",
    label: "Conception d'une recette pour un créneau",
    group: "Planning",
  },

  // ── Courses ───────────────────────────────────────────────────────────────
  { id: "shopping_list", label: "Consolidation d'une liste de courses", group: "Courses" },
  { id: "shopping_products_refresh", label: "Produits d'achat d'une recette", group: "Courses" },

  // ── Nutrition ─────────────────────────────────────────────────────────────
  {
    id: "nutrition_ingredients_enrichment_batch",
    label: "Estimation par lots",
    group: "Nutrition",
  },
  {
    id: "nutrition_ingredients_enrichment",
    label: "Estimation d'un ingrédient",
    group: "Nutrition",
  },
  {
    id: "inline_ingredient_per100g_enrichment_batch",
    label: "Lot pendant la normalisation",
    group: "Nutrition",
  },
  {
    id: "inline_ingredient_per100g_enrichment",
    label: "Rattrapage pendant la normalisation",
    group: "Nutrition",
  },
  {
    id: "nutrition_ingredients_enrichment_auto_batch",
    label: "Lot au déclencheur de recette",
    group: "Nutrition",
  },
  {
    id: "backfill_enrich_referentials_per100g_batch",
    label: "Lot du backfill administrateur",
    group: "Nutrition",
  },
  { id: "singularize_units", label: "Singularisation des unités", group: "Nutrition" },
  {
    id: "complete_ingredient_quantities",
    label: "Complétion des quantités manquantes",
    group: "Nutrition",
  },
  { id: "enrich_unit_weights", label: "Poids d'une unité inconnue", group: "Nutrition" },
  { id: "estimate_piece_weights", label: "Poids d'un ingrédient à la pièce", group: "Nutrition" },
  {
    id: "estimate_unit_couple_weights",
    label: "Poids d'une unité pour un ingrédient donné",
    group: "Nutrition",
  },
  {
    id: "detect_not_consumed",
    label: "Ingrédients non consommés (bain de friture, fumage)",
    group: "Nutrition",
  },
  {
    id: "detect_duplicate_ingredients",
    label: "Lignes reprenant un ingrédient déjà listé",
    group: "Nutrition",
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

export const setAiRoutingPolicyFn = onCall<SetAiRoutingPolicyRequest>(callableOpts, async (req) => {
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
});
