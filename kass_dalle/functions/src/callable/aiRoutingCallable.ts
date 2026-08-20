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

import {
  REGION,
  COLL_APP_CONFIG,
  ANTHROPIC_API_KEY,
  GEMINI_IMAGE_MODEL,
  GEMINI_IMAGE_MODEL_LABEL,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { requireAdmin } from "./_auth";
import type { AiProvider } from "../ai/types";
import { anthropicApiKey } from "../ai/anthropic";
import {
  AI_ROUTING_POLICY_DOC_ID,
  DEFAULT_AI_ROUTING_POLICY,
  getAiRoutingPolicy,
  type AiRoutingPolicy,
} from "../ai/router";
import {
  AI_PRICING_DOC_ID,
  builtinPricingTable,
  invalidateAiPricingCache,
  loadAiPricingTable,
  parsePricingEntry,
  pricingEntryToMap,
} from "../ai/pricing";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  // Le secret est monté ici sans qu'aucun appel Claude n'ait lieu : c'est ce
  // qui permet à l'écran d'affirmer que la clé est réellement disponible, au
  // lieu de le supposer. Une bascule sans effet est autrement indéchiffrable.
  secrets: [ANTHROPIC_API_KEY],
};

/**
 * Fournisseurs qu'une politique peut désigner pour un poste ordinaire.
 *
 * Cloud Vision n'y figure pas : il ne sert qu'un poste, la modération, dont
 * l'exécution ne passe pas par `callModel`. Ce poste déclare sa propre liste
 * (voir `providers` ci-dessous) et son sélecteur reste inactif.
 */
const PROVIDERS: readonly AiProvider[] = ["gemini", "anthropic"];

/**
 * Postes fonctionnels routables, avec leur libellé et leur famille.
 *
 * Un poste n'apparaît ici que si son code passe réellement par `callModel`.
 * Les seuls appels d'IA volontairement absents sont ceux qui **produisent** une
 * image : Claude n'en fabrique pas, les proposer à la bascule serait une
 * promesse fausse. Ils sont déclarés à part dans [IMAGE_GENERATION_FEATURES],
 * pour que l'écran les montre sans les rendre basculables.
 *
 * Liste explicite plutôt que texte libre : un poste mal orthographié dans une
 * politique ne produirait aucune erreur — il ne router­ait simplement jamais
 * rien, et on chercherait longtemps pourquoi la bascule « ne marche pas ».
 */
export const ROUTABLE_FEATURES: Array<{
  id: string;
  label: string;
  group: string;
  /**
   * Fournisseurs acceptables pour ce poste. Absent = les deux moteurs de
   * `PROVIDERS`. Un seul fournisseur rend le sélecteur inactif plutôt que de
   * masquer le poste : un poste absent de l'écran est un poste qu'il faudra
   * redéployer pour faire bouger.
   */
  providers?: readonly AiProvider[];
  /** Pourquoi le choix est verrouillé, affiché tel quel. */
  lockedReason?: string;
}> = [
  // ── Import ────────────────────────────────────────────────────────────────
  // Les deux passes de la chaîne d'extraction. Elles remplacent
  // `classify_page` + `scan_extraction` + `document_extraction`, qui restent au
  // catalogue : les mois déjà comptabilisés doivent continuer de les nommer.
  { id: "transcription_page", label: "Transcription d'une page", group: "Import" },
  { id: "recipe_tagging", label: "Balisage et normalisation d'une recette", group: "Import" },
  { id: "scan_extraction", label: "Extraction d'un scan de page", group: "Import" },
  { id: "text_extraction", label: "Extraction depuis un texte libre", group: "Import" },
  { id: "classify_page", label: "Classification d'une page", group: "Import" },
  { id: "document_extraction", label: "Extraction d'un document non-recette", group: "Import" },
  { id: "book_cover", label: "Lecture d'une couverture de livre", group: "Import" },

  // ── Illustrations ─────────────────────────────────────────────────────────
  {
    id: "detect_main_photo",
    label: "Détection de la photo principale",
    group: "Illustrations — détection",
  },
  {
    id: "detect_illustrations",
    label: "Détection des illustrations",
    group: "Illustrations — détection",
  },
  {
    id: "detect_illustrations_crop",
    label: "Détection — seconde passe sur recadrage",
    group: "Illustrations — détection",
  },
  {
    id: "detect_illustrations_grid",
    label: "Détection — repli pleine page",
    group: "Illustrations — détection",
  },
  {
    id: "detect_grid_dims",
    label: "Détection — dimensions d'une grille",
    group: "Illustrations — détection",
  },

  // ── Rédaction ─────────────────────────────────────────────────────────────
  { id: "generate", label: "Génération d'une recette", group: "Rédaction" },
  { id: "refine", label: "Modification d'une recette", group: "Rédaction" },
  { id: "polish_cooklang", label: "Relecture d'un CookLang", group: "Rédaction" },
  { id: "polish_markdown", label: "Relecture d'un document Markdown", group: "Rédaction" },
  { id: "suggest_tags", label: "Suggestion de tags", group: "Rédaction" },
  { id: "plating_coach", label: "Conseil de dressage", group: "Rédaction" },
  {
    id: "storage_advice",
    label: "Conservation et réchauffage",
    group: "Rédaction",
  },

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
  {
    id: "estimate_fry_absorption",
    label: "Huile absorbée à la friture",
    group: "Nutrition",
  },

  // ── Modération ────────────────────────────────────────────────────────────
  // Un seul moteur admis aujourd'hui. Le poste figure quand même ici : le
  // jour où un second devient acceptable, il se choisit depuis cet écran, sans
  // déploiement.
  {
    id: "image_moderation",
    label: "Modération d'une image",
    group: "Modération",
    providers: ["vision"],
    lockedReason:
      "Seul Cloud Vision rend un verdict reproductible ; un blocage doit pouvoir se rejouer.",
  },
  {
    id: "image_moderation_batch",
    label: "Modération d'un lot d'images",
    group: "Modération",
    providers: ["vision"],
    lockedReason:
      "Seul Cloud Vision rend un verdict reproductible ; un blocage doit pouvoir se rejouer.",
  },
];

/**
 * Postes qui **produisent** une image, et que rien ne peut router.
 *
 * Ils sont exposés à l'écran sans commutateur. L'écran affichait jusqu'ici cinq
 * postes de *détection* sous le titre « Illustrations », tous basculables vers
 * Claude : on pouvait raisonnablement en conclure que la retouche d'image
 * partait chez Claude, ce qu'aucun modèle Anthropic ne sait faire. Le silence
 * sur ces trois postes était la vraie incohérence — pas leur absence de la
 * bascule.
 *
 * Les nommer ici ne crée pas un troisième fournisseur : ils sont Gemini, comme
 * la colonne de gauche, simplement sur un modèle différent du modèle de texte.
 */
export const IMAGE_GENERATION_FEATURES: Array<{ id: string; label: string }> = [
  { id: "generate_recipe_illustration", label: "Illustration d'une recette" },
  { id: "plating_image", label: "Visuel d'une étape de dressage" },
  { id: "enhance_illustration", label: "Amélioration d'une photo" },
];

// ── Grille tarifaire ─────────────────────────────────────────────────────────

/**
 * Grille en vigueur, et ce qui la distingue du repli en dur.
 *
 * L'écran doit pouvoir montrer qu'un tarif a été corrigé à la main : sans
 * cette distinction, un prix modifié depuis Admin est indiscernable d'un prix
 * livré avec le code, et personne ne sait plus lequel fait foi.
 */
export const getAiPricingFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req, "grille_tarifaire_lecture");
  const builtin = builtinPricingTable();
  const effective = await loadAiPricingTable();

  const models = Object.keys(effective).sort();
  return {
    models: models.map((model) => {
      const entry = effective[model];
      const base = builtin[model];
      return {
        model,
        ...pricingEntryToMap(entry),
        // Vrai quand la valeur ne vient pas du code : soit un modèle ajouté
        // depuis l'écran, soit un tarif du code réécrit par-dessus.
        overridden:
          base == null ||
          base.inputPerMillion !== entry.inputPerMillion ||
          base.outputPerMillion !== entry.outputPerMillion ||
          (base.imageOutputPerUnit ?? 0) !== (entry.imageOutputPerUnit ?? 0),
        builtin: base != null,
      };
    }),
  };
});

interface SetAiPricingRequest {
  model?: string;
  /** Absent ou `null` : le tarif retourne à la valeur livrée avec le code. */
  pricing?: {
    input_per_million?: number;
    output_per_million?: number;
    image_output_per_unit?: number;
    introductory?: {
      input_per_million?: number;
      output_per_million?: number;
      until_iso?: string;
    } | null;
  } | null;
}

export const setAiPricingFn = onCall<SetAiPricingRequest>(callableOpts, async (req) => {
  await requireAdmin(req, "grille_tarifaire_ecriture");

  const model = (req.data?.model ?? "").trim();
  if (!model) {
    throw new HttpsError("invalid-argument", "model est requis.");
  }

  const doc = getFirestore().collection(COLL_APP_CONFIG).doc(AI_PRICING_DOC_ID);
  const raw = req.data?.pricing;

  if (raw == null) {
    // Retour au tarif du code. Un modèle qui n'y figure pas disparaît de la
    // grille : c'est voulu, il n'aurait plus aucune valeur de référence.
    await doc.set(
      {
        models: { [model]: FieldValue.delete() },
        updated_at: FieldValue.serverTimestamp(),
        updated_by: req.auth?.uid ?? null,
      },
      { merge: true },
    );
    invalidateAiPricingCache();
    return { model, removed: true };
  }

  const parsed = parsePricingEntry(raw);
  if (!parsed) {
    throw new HttpsError(
      "invalid-argument",
      "Tarifs invalides : input_per_million et output_per_million doivent être des nombres positifs.",
    );
  }

  await doc.set(
    {
      models: { [model]: pricingEntryToMap(parsed) },
      updated_at: FieldValue.serverTimestamp(),
      updated_by: req.auth?.uid ?? null,
    },
    { merge: true },
  );
  // Sans cette invalidation, le tarif corrigé n'aurait pris effet qu'à
  // l'expiration du cache — et l'écran aurait affiché l'ancien juste après
  // l'enregistrement, ce qui donne à croire que rien n'a été pris en compte.
  invalidateAiPricingCache();

  return { model, pricing: pricingEntryToMap(parsed) };
});

export const getAiRoutingPolicyFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req, "routage_ia_lecture");
  const policy = await getAiRoutingPolicy();
  return {
    policy,
    // L'écran doit pouvoir dire « routé vers Claude mais la clé n'est pas
    // posée » : sans cette information, une bascule sans effet reste une
    // énigme pour celui qui l'a demandée.
    anthropicKeyPresent: anthropicApiKey() != null,
    routableFeatures: ROUTABLE_FEATURES,
    imageGenerationFeatures: IMAGE_GENERATION_FEATURES,
    imageModel: GEMINI_IMAGE_MODEL,
    imageModelLabel: GEMINI_IMAGE_MODEL_LABEL,
  };
});

interface SetAiRoutingPolicyRequest {
  policy?: Partial<AiRoutingPolicy>;
}

export const setAiRoutingPolicyFn = onCall<SetAiRoutingPolicyRequest>(callableOpts, async (req) => {
  await requireAdmin(req, "routage_ia_ecriture");

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
    const allowed = ROUTABLE_FEATURES.find((f) => f.id === feature)?.providers ?? PROVIDERS;
    if (!allowed.includes(provider as AiProvider)) {
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

  // Plafond de raisonnement : `null` laisse le modèle décider, `0` le coupe.
  // Un plafond démesuré ne protégerait de rien — la borne haute vaut celle du
  // modèle, au-delà l'API refuserait l'appel.
  const MAX_THINKING_BUDGET = 24576;
  const readBudget = (value: unknown, label: string): number | null => {
    if (value == null) return null;
    const n = Number(value);
    if (!Number.isFinite(n) || n < 0 || n > MAX_THINKING_BUDGET) {
      throw new HttpsError(
        "invalid-argument",
        `Plafond de raisonnement invalide pour ${label} : attendu entre 0 et ${MAX_THINKING_BUDGET}.`,
      );
    }
    return Math.trunc(n);
  };

  const thinkingBudget = readBudget(next.thinkingBudget, "le réglage global");
  const thinkingBudgets: Record<string, number> = {};
  for (const [feature, budget] of Object.entries(next.thinkingBudgets ?? {})) {
    if (!knownFeatureIds.has(feature)) {
      throw new HttpsError("invalid-argument", `Poste inconnu : ${feature}.`);
    }
    const value = readBudget(budget, feature);
    if (value != null) thinkingBudgets[feature] = value;
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
        // Écrit même à `null` : c'est ainsi qu'on revient au comportement du
        // modèle après avoir posé un plafond. Un champ simplement omis en
        // fusion laisserait l'ancienne valeur en place.
        thinking_budget: thinkingBudget,
        thinking_budgets: thinkingBudgets,
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
      thinkingBudget,
      thinkingBudgets,
    },
    anthropicKeyPresent: anthropicApiKey() != null,
  };
});
