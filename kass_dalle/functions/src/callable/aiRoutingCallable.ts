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
  COLL_AI_ROUTING_PRESETS,
  COLL_USERS,
  ANTHROPIC_API_KEY,
  GEMINI_IMAGE_MODEL,
  GEMINI_IMAGE_MODEL_LABEL,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { requireAdmin } from "./_auth";
import type { AiProvider } from "../ai/types";
import { anthropicApiKey } from "../ai/anthropic";
import { AI_ROUTING_POLICY_DOC_ID, getAiRoutingPolicy, type AiRoutingPolicy } from "../ai/router";
import { logError, logInfo } from "../logging";
import {
  buildRoutingCatalog,
  normalizePresetName,
  presetNameKey,
  presetPolicyFromMap,
  presetPolicyToMap,
  readRoutingPolicy,
  RoutingPolicyError,
  SEEDED_PRESET_ID,
  SEEDED_PRESET_NAME,
  type RoutingPolicyReading,
} from "../ai/routingPresets";
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
/**
 * Modèles Claude proposés à l'écran, du plus soigneux au plus rapide.
 *
 * Liste explicite, et fermée : elle doit rester alignée sur la grille
 * tarifaire. Un identifiant hors grille se facturerait sans montant et
 * gonflerait `total_unpriced_calls` — un coût invisible, exactement ce que ce
 * projet refuse.
 *
 * `hint` dit à QUOI chaque modèle sert, parce que le choix ne se devine pas
 * depuis un identifiant : le mauvais choix ne se voit ni dans un sens ni dans
 * l'autre. Un modèle trop petit rend une page abîmée qui a l'air correcte, un
 * modèle trop grand rend une facture qui a l'air normale.
 */
/**
 * Efforts de réflexion Claude proposés à l'écran, du plus rapide au plus
 * appliqué.
 *
 * Le code de chaque poste garde le sien par défaut ; ce choix n'écrit une
 * exception que si l'administrateur en pose une explicitement (voir
 * `resolveAnthropicEffort`).
 */
export const ANTHROPIC_EFFORT_CHOICES: Array<{
  id: "low" | "medium" | "high";
  label: string;
  hint: string;
}> = [
  { id: "low", label: "Basse", hint: "Le moins de réflexion, le moins cher." },
  { id: "medium", label: "Moyenne", hint: "Un compromis, pas toujours moins cher que « basse »." },
  { id: "high", label: "Haute", hint: "Le plus de soin, le plus cher." },
];

export const ANTHROPIC_MODEL_CHOICES: Array<{ id: string; label: string; hint: string }> = [
  {
    id: "claude-opus-5",
    label: "Opus 5",
    hint: "Le plus soigneux, et le plus cher. Pour lire une page de livre au mot près.",
  },
  {
    id: "claude-sonnet-5",
    label: "Sonnet 5",
    hint: "L'équilibre par défaut. Convient à presque tous les postes.",
  },
  {
    id: "claude-haiku-4-5",
    label: "Haiku 4.5",
    hint: "Le plus rapide et le moins cher. Pour un rappel de connaissances répété.",
  },
];

export const ROUTABLE_FEATURES: Array<{
  id: string;
  label: string;
  group: string;
  /**
   * Fournisseurs acceptables pour ce poste. Absent = les deux moteurs de
   * `PROVIDERS`. Un seul fournisseur fait afficher une puce à la place du
   * commutateur, plutôt que de masquer le poste : un poste absent de l'écran
   * est un poste qu'il faudra redéployer pour faire bouger.
   *
   * Ce champ n'est pas décoratif. `setAiRoutingPolicyFn` refuse la politique
   * ENTIÈRE si elle prête à un poste un fournisseur hors de cette liste : un
   * client qui l'ignore rend l'écran insauvegardable au premier « Tout
   * Claude ».
   */
  providers?: readonly AiProvider[];
  /** Pourquoi le choix est verrouillé, affiché tel quel. */
  lockedReason?: string;
}> = [
  // ── Import ────────────────────────────────────────────────────────────────
  // Les deux passes de la chaîne d'extraction, puis ce qui n'en relève pas :
  // un texte collé, une couverture de livre.
  //
  // `classify_page`, `scan_extraction` et `document_extraction` ont quitté
  // cette liste en même temps que le code qui les appelait. Ils restent au
  // catalogue comptable — les mois déjà comptabilisés doivent continuer de les
  // nommer — mais un poste qu'aucun appel n'emprunte n'a rien à faire ici : son
  // sélecteur promettait un réglage qui ne commandait rien.
  { id: "transcription_page", label: "Transcription d'une page", group: "Import" },
  { id: "recipe_tagging", label: "Balisage et normalisation d'une recette", group: "Import" },
  { id: "text_extraction", label: "Extraction depuis un texte libre", group: "Import" },
  { id: "book_cover", label: "Lecture d'une couverture de livre", group: "Import" },

  // ── Illustrations d'une page importée ─────────────────────────────────────
  //
  // Quatre postes pour une seule chaîne, et non un poste unique : le seul moyen
  // de savoir si le pré-contrôle rapporte plus qu'il ne coûte est de le compter
  // à part. Il arrête la chaîne sur les pages sans image — c'est-à-dire une
  // page de recette sur deux — et économise alors les trois autres.
  {
    id: "page_illustrations_precheck",
    label: "Pré-contrôle : la page porte-t-elle des images",
    group: "Extraction des illustrations d'une page",
  },
  {
    id: "page_illustrations_frame",
    label: "Cadrage de la page (boîte puis coins)",
    group: "Extraction des illustrations d'une page",
  },
  {
    id: "page_illustrations_orientation",
    label: "Sens de lecture de la page",
    group: "Extraction des illustrations d'une page",
  },
  {
    id: "page_illustrations_regions",
    label: "Zones imagées de la page",
    group: "Extraction des illustrations d'une page",
  },

  // ── Illustrations ─────────────────────────────────────────────────────────
  //
  // Un seul poste, et c'est une réduction : quatre autres vivaient ici. Le
  // repli « photo principale » ne partait plus depuis juillet, et la cascade
  // de subdivision — dimensions de grille, seconde passe, repli pleine page —
  // dépensait trois appels pour un résultat inchangé neuf fois sur dix. Ils
  // restent au catalogue comptable, qui doit continuer de nommer les mois
  // déjà facturés.
  {
    id: "detect_illustrations",
    label: "Détection des illustrations",
    group: "Illustrations — détection",
  },

  // ── Rédaction ─────────────────────────────────────────────────────────────
  { id: "generate", label: "Génération d'une recette", group: "Rédaction" },
  { id: "refine", label: "Modification d'une recette", group: "Rédaction" },
  { id: "polish_cooklang", label: "Relecture d'un CookLang", group: "Rédaction" },
  { id: "polish_markdown", label: "Relecture d'un document Markdown", group: "Rédaction" },
  { id: "suggest_tags", label: "Suggestion de tags", group: "Rédaction" },
  {
    id: "backfill_recipe_roles",
    label: "Rôle des recettes dans un repas (backfill)",
    group: "Planning",
  },
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
  {
    id: "planning_meal_ideas",
    label: "Idées de repas sur une consigne",
    group: "Planning",
  },

  // ── Courses ───────────────────────────────────────────────────────────────
  { id: "shopping_list", label: "Consolidation d'une liste de courses", group: "Courses" },
  { id: "shopping_products_refresh", label: "Produits d'achat d'une recette", group: "Courses" },
  {
    id: "backfill_shopping_aliases",
    label: "Produit acheté des ingrédients (backfill)",
    group: "Courses",
  },
  {
    id: "shopping_product_alias_auto",
    label: "Produit acheté d'un ingrédient neuf (import)",
    group: "Courses",
  },

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
  {
    id: "backfill_refresh_sodium_per100g_batch",
    label: "Lot de la reprise du sel",
    group: "Nutrition",
  },
  // Trois postes ont quitté ce groupe avec le code qui les appelait :
  // `singularize_units` — la dépluralisation est devenue déterministe ;
  // `complete_ingredient_quantities` — la complétion ne coûte plus d'appel ;
  // `detect_duplicate_ingredients` — la transcription du livre a supprimé la
  // cause des doublons. Ils restent au catalogue comptable.
  { id: "enrich_unit_weights", label: "Poids d'une unité inconnue", group: "Nutrition" },
  { id: "estimate_piece_weights", label: "Poids d'un ingrédient à la pièce", group: "Nutrition" },
  {
    id: "estimate_usual_portions",
    label: "Portion usuelle d'un ingrédient sans quantité",
    group: "Nutrition",
  },
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

  // ── Bac à sable ───────────────────────────────────────────────────────────
  // Une expérience coûte de l'argent réel. Elle est donc routable et imputée
  // comme les autres postes, sans quoi sa dépense s'afficherait sous sa clé
  // technique, rangée dans « Autres ».
  {
    id: "sandbox_detect_page",
    label: "Cadrage de la page dans une photo",
    group: "Bac à sable",
  },
  {
    id: "sandbox_detect_orientation",
    label: "Sens de lecture d'une page",
    group: "Bac à sable",
  },
  {
    id: "sandbox_detect_regions",
    label: "Détection des zones d'une page",
    group: "Bac à sable",
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
        //
        // Le tarif à l'unité et la franchise mensuelle comptent comme les
        // autres : sans eux, corriger le prix d'une image analysée ne posait
        // ni la mention « modifié » ni le bouton de retour. Le seul poste
        // facturé à l'unité était aussi le seul dont la correction ne se
        // voyait pas.
        overridden:
          base == null ||
          base.inputPerMillion !== entry.inputPerMillion ||
          base.outputPerMillion !== entry.outputPerMillion ||
          (base.imageOutputPerUnit ?? 0) !== (entry.imageOutputPerUnit ?? 0) ||
          (base.analyzedImagePerUnit ?? 0) !== (entry.analyzedImagePerUnit ?? 0) ||
          (base.freeUnitsPerMonth ?? 0) !== (entry.freeUnitsPerMonth ?? 0),
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
    /** Image ANALYSÉE, facturée à l'unité — Cloud Vision. */
    analyzed_image_per_unit?: number;
    /** Unités offertes par mois, déduites au mois et non sur l'appel. */
    free_units_per_month?: number;
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

/**
 * Ce que le serveur accepte aujourd'hui, monté une fois.
 *
 * Les trois tables ci-dessus décident ensemble de ce qu'une politique peut
 * dire. Les recopier à chaque lecture ferait diverger le contrôle de
 * l'écriture et celui du chargement d'une configuration.
 */
const ROUTING_CATALOG = buildRoutingCatalog({
  providers: PROVIDERS,
  features: ROUTABLE_FEATURES,
  models: ANTHROPIC_MODEL_CHOICES,
});

/** Lit une politique et rend l'erreur transportable jusqu'à l'écran. */
function readPolicyOrThrow(
  raw: Partial<AiRoutingPolicy> | null | undefined,
  onUnknown: "reject" | "drop",
): RoutingPolicyReading {
  try {
    return readRoutingPolicy(raw, ROUTING_CATALOG, { onUnknown });
  } catch (err) {
    if (err instanceof RoutingPolicyError) {
      throw new HttpsError("invalid-argument", err.message);
    }
    throw err;
  }
}

// ── Configurations enregistrées ──────────────────────────────────────────────

/** Une configuration telle que l'écran la reçoit. */
interface PresetView {
  id: string;
  name: string;
  policy: AiRoutingPolicy;
  /** Ce que la relecture a écarté : postes disparus, modèles hors grille. */
  stale: string[];
  updatedAt: string | null;
  /** Nom d'affichage de l'auteur, jamais son identifiant technique. */
  updatedBy: string | null;
}

/**
 * Libellés des comptes cités, en une lecture.
 *
 * Un identifiant Firebase ne dit rien à personne. Le résoudre coûte une
 * lecture par auteur distinct — il y a moins d'auteurs que de configurations.
 */
async function userLabels(uids: readonly string[]): Promise<Record<string, string>> {
  if (uids.length === 0) return {};
  const db = getFirestore();
  const snaps = await db.getAll(...uids.map((uid) => db.collection(COLL_USERS).doc(uid)));
  const labels: Record<string, string> = {};
  for (const snap of snaps) {
    const data = snap.data() ?? {};
    const label = (data.display_name as string) || (data.email as string) || "";
    if (label) labels[snap.id] = label;
  }
  return labels;
}

/**
 * Toutes les configurations, relues contre le catalogue du jour.
 *
 * La relecture est permissive : une configuration qui nomme un poste retiré
 * depuis reste chargeable, amputée de ce poste et accompagnée de la raison.
 * La refuser en bloc laisserait un état ancien inatteignable sans qu'aucun
 * message ne dise lequel des quarante-trois postes bloque.
 */
async function listPresets(): Promise<PresetView[]> {
  const snap = await getFirestore().collection(COLL_AI_ROUTING_PRESETS).get();

  const uids = [
    ...new Set(
      snap.docs
        .map((doc) => doc.get("updated_by"))
        .filter((uid): uid is string => typeof uid === "string" && uid.length > 0),
    ),
  ];
  const labels = await userLabels(uids);

  const presets = snap.docs.map((doc) => {
    const data = doc.data();
    const { policy, stale } = readRoutingPolicy(
      presetPolicyFromMap(data.policy as Record<string, unknown>),
      ROUTING_CATALOG,
      { onUnknown: "drop" },
    );
    const updatedAt = data.updated_at;
    const uid = typeof data.updated_by === "string" ? data.updated_by : null;
    return {
      id: doc.id,
      name: typeof data.name === "string" ? data.name : doc.id,
      policy,
      stale,
      updatedAt:
        updatedAt != null && typeof updatedAt.toDate === "function"
          ? (updatedAt.toDate() as Date).toISOString()
          : null,
      updatedBy: uid ? (labels[uid] ?? null) : null,
    };
  });

  presets.sort((a, b) => a.name.localeCompare(b.name, "fr"));
  return presets;
}

/**
 * Sème la politique en vigueur comme première configuration.
 *
 * L'écran arrive sur une installation où quarante-trois postes ont déjà été
 * réglés à la main. Sans ce geste, essayer une autre configuration
 * demanderait d'abord d'enregistrer l'état courant, et personne n'y penserait
 * avant de l'avoir perdu.
 *
 * Une seule fois : la marque posée sur le document de politique empêche la
 * configuration de revenir après une suppression volontaire.
 */
async function seedPresetsIfNeeded(policy: AiRoutingPolicy, uid: string | null): Promise<void> {
  const db = getFirestore();
  const presets = db.collection(COLL_AI_ROUTING_PRESETS);

  const existing = await presets.limit(1).get();
  if (!existing.empty) return;

  const policyDoc = db.collection(COLL_APP_CONFIG).doc(AI_ROUTING_POLICY_DOC_ID);
  const snap = await policyDoc.get();
  if (snap.exists && snap.get("presets_seeded_at") != null) return;

  await presets.doc(SEEDED_PRESET_ID).set({
    name: SEEDED_PRESET_NAME,
    name_key: presetNameKey(SEEDED_PRESET_NAME),
    policy: presetPolicyToMap(policy),
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
    updated_by: uid,
  });
  await policyDoc.set({ presets_seeded_at: FieldValue.serverTimestamp() }, { merge: true });
}

export const getAiRoutingPolicyFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req, "routage_ia_lecture");
  const policy = await getAiRoutingPolicy();

  // Les configurations ne sont pas le sujet de cet écran : leur panne ne doit
  // pas empêcher de régler le routage. Elle se dit, elle n'interrompt pas.
  let presets: PresetView[] = [];
  let presetsFailed = false;
  try {
    await seedPresetsIfNeeded(policy, req.auth?.uid ?? null);
    presets = await listPresets();
  } catch (err) {
    presetsFailed = true;
    await logError({
      message: "getAiRoutingPolicyFn: configurations de routage illisibles",
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: req.auth?.uid,
    });
  }

  return {
    policy,
    presets,
    presetsFailed,
    // L'écran doit pouvoir dire « routé vers Claude mais la clé n'est pas
    // posée » : sans cette information, une bascule sans effet reste une
    // énigme pour celui qui l'a demandée.
    anthropicKeyPresent: anthropicApiKey() != null,
    routableFeatures: ROUTABLE_FEATURES,
    anthropicModelChoices: ANTHROPIC_MODEL_CHOICES,
    anthropicEffortChoices: ANTHROPIC_EFFORT_CHOICES,
    imageGenerationFeatures: IMAGE_GENERATION_FEATURES,
    imageModel: GEMINI_IMAGE_MODEL,
    imageModelLabel: GEMINI_IMAGE_MODEL_LABEL,
  };
});

interface SetAiRoutingPolicyRequest {
  policy?: Partial<AiRoutingPolicy>;
}

export const setAiRoutingPolicyFn = onCall<SetAiRoutingPolicyRequest>(callableOpts, async (req) => {
  const ctx = await requireAdmin(req, "routage_ia_ecriture");

  const { policy } = readPolicyOrThrow(req.data?.policy, "reject");

  // Diagnostic temporaire (28 septembre 2026) : un modèle par poste effacé
  // depuis l'écran (retour au « défaut ») ne ressortait pas de la grille en
  // vigueur après enregistrement, malgré un écran qui affiche la réussite. Ce
  // journal compare ce qui arrive à ce qui est validé, pour trancher entre un
  // brouillon client qui n'a pas changé et une validation qui réintroduit une
  // clé. À retirer une fois la cause connue.
  await logInfo({
    message: "setAiRoutingPolicyFn: modèles et efforts reçus vs validés",
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature: "routage_ia_ecriture",
    extra: {
      recuAnthropicModels: req.data?.policy?.anthropicModels ?? null,
      valideAnthropicModels: policy.anthropicModels,
      recuAnthropicEfforts: req.data?.policy?.anthropicEfforts ?? null,
      valideAnthropicEfforts: policy.anthropicEfforts,
    },
  });

  await getFirestore()
    .collection(COLL_APP_CONFIG)
    .doc(AI_ROUTING_POLICY_DOC_ID)
    .set(
      {
        // Les sept champs sont écrits en entier, plafonds à `null` compris :
        // c'est ainsi qu'on revient au comportement du modèle après avoir posé
        // un plafond. Un champ simplement omis en fusion laisserait l'ancienne
        // valeur en place.
        ...presetPolicyToMap(policy),
        updated_at: FieldValue.serverTimestamp(),
        updated_by: req.auth?.uid ?? null,
      },
      { merge: true },
    );

  return { policy, anthropicKeyPresent: anthropicApiKey() != null };
});

// ── Configurations enregistrées : écriture ───────────────────────────────────

interface AiRoutingPresetsRequest {
  action?: "save" | "update" | "rename" | "delete";
  id?: string;
  name?: string;
  policy?: Partial<AiRoutingPolicy>;
}

/**
 * Refuse un nom déjà porté par une autre configuration.
 *
 * Deux entrées homonymes dans une liste déroulante ne se distinguent plus une
 * fois l'une choisie : on croit charger la sienne, on charge l'autre. La
 * comparaison se fait sur `name_key`, insensible à la casse.
 */
async function assertNameFree(name: string, exceptId: string | null): Promise<void> {
  const snap = await getFirestore()
    .collection(COLL_AI_ROUTING_PRESETS)
    .where("name_key", "==", presetNameKey(name))
    .get();
  const clash = snap.docs.find((doc) => doc.id !== exceptId);
  if (clash) {
    throw new HttpsError("already-exists", `Une configuration porte déjà le nom « ${name} ».`);
  }
}

async function requirePreset(id: string) {
  const ref = getFirestore().collection(COLL_AI_ROUTING_PRESETS).doc(id);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Cette configuration n'existe plus.");
  }
  return ref;
}

/**
 * Enregistre, met à jour, renomme ou supprime une configuration de routage.
 *
 * Une seule fonction déployée pour quatre gestes, aiguillée sur `action` : le
 * bundle porte déjà cinquante fonctions, et le budget de découverte du
 * déploiement est de dix secondes.
 *
 * Aucune de ces actions ne touche la politique en vigueur. Charger une
 * configuration se fait dans l'écran, qui remplit son brouillon ; c'est
 * `setAiRoutingPolicyFn` qui écrit, comme avant. Un chargement ne doit pas
 * pouvoir modifier quarante-trois postes sans que personne ait vu l'écart.
 */
export const aiRoutingPresetsFn = onCall<AiRoutingPresetsRequest>(callableOpts, async (req) => {
  await requireAdmin(req, "configurations_routage");

  const action = req.data?.action;
  const uid = req.auth?.uid ?? null;
  const presets = getFirestore().collection(COLL_AI_ROUTING_PRESETS);

  const readName = (): string => {
    try {
      return normalizePresetName(req.data?.name);
    } catch (err) {
      if (err instanceof RoutingPolicyError) {
        throw new HttpsError("invalid-argument", err.message);
      }
      throw err;
    }
  };

  const readId = (): string => {
    const id = (req.data?.id ?? "").trim();
    if (!id) throw new HttpsError("invalid-argument", "id est requis.");
    return id;
  };

  switch (action) {
    case "save": {
      const name = readName();
      // Le contrôle strict, celui de l'écriture de la politique : une
      // configuration invalide doit être refusée quand on l'enregistre, pas
      // six semaines plus tard quand on la charge.
      const { policy } = readPolicyOrThrow(req.data?.policy, "reject");
      await assertNameFree(name, null);
      await presets.add({
        name,
        name_key: presetNameKey(name),
        policy: presetPolicyToMap(policy),
        created_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
        updated_by: uid,
      });
      break;
    }

    case "update": {
      const id = readId();
      const ref = await requirePreset(id);
      const { policy } = readPolicyOrThrow(req.data?.policy, "reject");
      await ref.set(
        {
          policy: presetPolicyToMap(policy),
          updated_at: FieldValue.serverTimestamp(),
          updated_by: uid,
        },
        { merge: true },
      );
      break;
    }

    case "rename": {
      const id = readId();
      const ref = await requirePreset(id);
      const name = readName();
      await assertNameFree(name, id);
      await ref.set(
        {
          name,
          name_key: presetNameKey(name),
          updated_at: FieldValue.serverTimestamp(),
          updated_by: uid,
        },
        { merge: true },
      );
      break;
    }

    case "delete": {
      const ref = await requirePreset(readId());
      await ref.delete();
      break;
    }

    default:
      throw new HttpsError("invalid-argument", `Action inconnue : ${action ?? "aucune"}.`);
  }

  // La liste part avec la réponse : sans elle, chaque geste demanderait un
  // second aller-retour, et l'écran afficherait un état d'avant l'écriture.
  return { presets: await listPresets() };
});
