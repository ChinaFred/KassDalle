/**
 * Estimation par IA des valeurs nutritionnelles pour 100 g d'un ingrédient.
 *
 * Principe directeur : **une approximation raisonnable vaut mieux qu'une
 * absence de valeur**. Un ingrédient sans per100g disparaît purement et
 * simplement du calcul nutritionnel de la recette, sans que rien ne le dise à
 * l'utilisateur ; une estimation, elle, s'affiche et s'annonce comme telle.
 *
 * Deux points d'entrée :
 *   - `estimatePer100gBatchWithAI` : N ingrédients en un appel. C'est la
 *     voie normale — elle supprime le plafond « 5 ingrédients par recette » qui
 *     venait du coût d'un appel par ingrédient.
 *   - `estimatePer100gWithGemini` : un seul ingrédient, avec insistance. Sert de
 *     repli quand le lot n'a pas couvert un ingrédient.
 */

import { extractJsonObject } from "../gemini/client";
import { callModel } from "../ai/router";
import { textPart as modelTextPart } from "../ai/types";
import { normalizeNutrients } from "./nutrients";
import { logError, logInfo } from "../logging";

/** Schéma de la réponse attendue pour un ingrédient isolé. */
const PER100G_SINGLE_SCHEMA = {
  type: "object",
  properties: {
    per100g: {
      type: "object",
      properties: {
        kcal: { type: "number" },
        protein_g: { type: "number" },
        carbs_g: { type: "number" },
        sugar_g: { type: "number" },
        fiber_g: { type: "number" },
        fat_g: { type: "number" },
        saturated_fat_g: { type: "number" },
        sodium_mg: { type: "number" },
        salt_g: { type: "number" },
      },
      required: [
        "kcal", "protein_g", "carbs_g", "sugar_g",
        "fiber_g", "fat_g", "saturated_fat_g", "sodium_mg", "salt_g",
      ],
      additionalProperties: false,
    },
  },
  required: ["per100g"],
  additionalProperties: false,
} as const;

/** Nombre d'ingrédients envoyés dans un même appel Gemini. */
export const PER100G_BATCH_SIZE = 20;

/** Relances individuelles au plus, après le passage par lots. */
export const MAX_INDIVIDUAL_RETRIES = 8;

/**
 * Champs écrits à côté de `per100g` quand la valeur vient de l'IA.
 *
 * Les trois chemins d'enrichissement (normalisation, déclencheur, backfill)
 * écrivaient jusqu'ici des `quality_status` différents pour le même acte —
 * « pending_review » ici, « estimated_ai » là. L'écran d'administration et le
 * détail nutritionnel ne pouvaient donc pas distinguer une valeur estimée d'une
 * valeur vérifiée de façon fiable.
 */
export const AI_PER100G_MARKERS = {
  source: "gemini_estimated",
  quality_status: "estimated_ai",
  per100g_source: "ai_estimation",
} as const;

/** Kilocalories au-delà desquelles une estimation est forcément fausse (huile pure ≈ 900). */
const MAX_PLAUSIBLE_KCAL = 950;

const MACRO_KEYS = [
  "protein_g",
  "carbs_g",
  "sugar_g",
  "fiber_g",
  "fat_g",
  "saturated_fat_g",
] as const;

export function hasPer100gValues(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  for (const v of Object.values(record)) {
    if (typeof v === "number" && Number.isFinite(v) && v > 0) {
      return true;
    }
    if (typeof v === "string") {
      const parsed = Number(v.replace(",", "."));
      if (Number.isFinite(parsed) && parsed > 0) {
        return true;
      }
    }
  }
  return false;
}

export interface Per100gEnrichmentTarget {
  id: string;
  canonicalName: string;
  aliases: string[];
}

/** Règles communes aux deux prompts — une seule formulation à maintenir. */
function estimationRules(): string[] {
  return [
    "Tu es un expert en nutrition et en composition des aliments.",
    "Retourne UNIQUEMENT du JSON valide, sans markdown ni commentaire.",
    "But : estimer la composition pour 100 g d'ingrédient brut standard.",
    "Champs autorisés (nombres >= 0) : kcal, protein_g, carbs_g, sugar_g, fiber_g, fat_g, saturated_fat_g, sodium_mg, salt_g.",
    "RÈGLES IMPÉRATIVES :",
    "- Donne TOUJOURS une estimation. N'omets aucun ingrédient demandé, ne réponds jamais « inconnu ».",
    "- kcal, protein_g, carbs_g et fat_g sont strictement positifs pour tout aliment réel.",
    "- 0 n'est acceptable que pour un nutriment réellement absent (fibres d'une viande, sucre d'une huile).",
    "- Nom proposant une alternative (« bacon ou pancetta », « beurre ou margarine ») : estime la MOYENNE des produits cités.",
    "- Nom vague ou générique : prends le produit le plus courant en cuisine française.",
    "- Qualificatif présent (fumé, frais, sec, demi-écrémé) : il change la composition, tiens-en compte.",
    "- Une approximation raisonnable vaut mieux qu'une absence de valeur : cette règle prime sur toutes les autres.",
  ];
}

/**
 * Nettoie et complète une estimation brute.
 *
 * Retourne `{}` si la valeur est invraisemblable — mieux vaut retenter que
 * d'écrire un chiffre absurde dans un référentiel qui alimente ensuite toutes
 * les recettes.
 */
export function sanitizePer100g(raw: Record<string, unknown>): Record<string, number> {
  const normalized = normalizeNutrients(raw);
  if (Object.keys(normalized).length === 0) return {};

  // Les calories manquantes se recalculent depuis les macronutriments : une
  // réponse partielle reste exploitable, et c'est toujours mieux que rien.
  if (!(normalized.kcal > 0)) {
    const rebuilt =
      (normalized.protein_g ?? 0) * 4 +
      (normalized.carbs_g ?? 0) * 4 +
      (normalized.fat_g ?? 0) * 9;
    if (rebuilt > 0) normalized.kcal = Math.round(rebuilt);
  }

  if (!(normalized.kcal > 0) || normalized.kcal > MAX_PLAUSIBLE_KCAL) return {};
  for (const key of MACRO_KEYS) {
    if ((normalized[key] ?? 0) > 100) return {};
  }
  return normalized;
}

function formatTarget(target: Per100gEnrichmentTarget): string {
  const aliases = target.aliases
    .map((a) => a.trim())
    .filter((a) => a.length > 0 && a.toLowerCase() !== target.canonicalName.toLowerCase())
    .slice(0, 5)
    .join(", ");
  return `- "${target.id}" : ${target.canonicalName}${aliases ? ` (aussi écrit : ${aliases})` : ""}`;
}

/**
 * Schéma de la réponse attendue pour un lot.
 *
 * Fourni au fournisseur qui sait le faire respecter — Claude garantit alors la
 * forme du JSON. Le format est une LISTE et non un objet indexé par
 * identifiant : un objet aux clés dynamiques n'est pas exprimable en JSON
 * Schema fermé, et c'est précisément la fermeture du schéma qui élimine les
 * réponses hors format.
 */
const PER100G_BATCH_SCHEMA = {
  type: "object",
  properties: {
    ingredients: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          kcal: { type: "number" },
          protein_g: { type: "number" },
          carbs_g: { type: "number" },
          sugar_g: { type: "number" },
          fiber_g: { type: "number" },
          fat_g: { type: "number" },
          saturated_fat_g: { type: "number" },
          sodium_mg: { type: "number" },
          salt_g: { type: "number" },
        },
        required: [
          "id", "kcal", "protein_g", "carbs_g", "sugar_g",
          "fiber_g", "fat_g", "saturated_fat_g", "sodium_mg", "salt_g",
        ],
        additionalProperties: false,
      },
    },
  },
  required: ["ingredients"],
  additionalProperties: false,
} as const;

/**
 * Estime les valeurs per100g de plusieurs ingrédients en un seul appel.
 *
 * Le moteur est choisi par la politique de routage (`app_config/ai_routing_policy`)
 * et non par ce fichier : la chaîne nutrition n'a pas à savoir qui répond, elle a
 * à savoir si la réponse est exploitable.
 *
 * Retourne une Map indexée par identifiant d'ingrédient. Les ingrédients que la
 * réponse ne couvre pas — ou couvre par une valeur invraisemblable — sont
 * simplement absents : l'appelant les repasse en estimation individuelle.
 */
export async function estimatePer100gBatchWithAI(params: {
  targets: Per100gEnrichmentTarget[];
  correlationId: string;
  userId?: string;
  feature?: string;
}): Promise<Map<string, Record<string, number>>> {
  const out = new Map<string, Record<string, number>>();
  if (params.targets.length === 0) return out;

  const feature = params.feature ?? "nutrition_ingredients_enrichment_batch";
  const prompt = [
    ...estimationRules(),
    "",
    "Ingrédients à estimer (identifiant : nom) :",
    ...params.targets.map(formatTarget),
    "",
    "Format strict attendu — une entrée par identifiant fourni, aucune de plus,",
    "et le champ `id` reprend l'identifiant EXACTEMENT tel qu'il est écrit ci-dessus :",
    '{"ingredients":[{"id":"<identifiant>","kcal":0,"protein_g":0,"carbs_g":0,"sugar_g":0,"fiber_g":0,"fat_g":0,"saturated_fat_g":0,"sodium_mg":0,"salt_g":0}]}',
  ].join("\n");

  const result = await callModel({
    parts: [modelTextPart(prompt)],
    ctx: {
      correlationId: params.correlationId,
      feature,
      moduleType: "DESIGN",
      timeoutMs: 90_000,
      userId: params.userId,
    },
    outputSchema: { name: "per100g_batch", schema: PER100G_BATCH_SCHEMA as unknown as Record<string, unknown> },
    usageMeta: {
      entityType: "nutrition_ingredient_batch",
      entityId: `${params.targets.length}_ingredients`,
    },
  });

  const text = result.text.trim();
  if (!text) {
    await logError({
      message: `estimatePer100gBatchWithAI: réponse vide pour ${params.targets.length} ingrédient(s)`,
      errorDescription: `${result.provider} a retourné une réponse vide`,
      correlationId: params.correlationId,
      extra: { ingredientIds: params.targets.map((t) => t.id) },
    });
    return out;
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
  } catch (err) {
    await logError({
      message: "estimatePer100gBatchWithAI: erreur parsing JSON",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: params.correlationId,
      extra: { rawText: text.slice(0, 600), ingredientIds: params.targets.map((t) => t.id) },
    });
    return out;
  }

  // Index tolérant : la réponse peut réutiliser le nom lisible plutôt que
  // l'identifiant. Sans cet index, une réponse correcte partait à la poubelle.
  const byLooseKey = new Map<string, Record<string, unknown>>();

  if (Array.isArray(parsed.ingredients)) {
    // Forme de la liste — celle que le schéma impose au fournisseur qui sait
    // le faire respecter. Chaque entrée porte son propre `id`.
    for (const item of parsed.ingredients) {
      if (!item || typeof item !== "object") continue;
      const entry = item as Record<string, unknown>;
      const id = typeof entry.id === "string" ? entry.id : "";
      if (!id) continue;
      byLooseKey.set(looseKey(id), entry);
    }
  } else {
    // Forme historique — un objet indexé par identifiant, parfois enveloppé
    // dans une clé « ingredients ». Conservée : un moteur sans schéma imposé
    // continue de répondre ainsi, et une réponse exploitable ne se jette pas.
    const root =
      parsed.ingredients && typeof parsed.ingredients === "object"
        ? (parsed.ingredients as Record<string, unknown>)
        : parsed;
    for (const [key, value] of Object.entries(root)) {
      if (!value || typeof value !== "object") continue;
      byLooseKey.set(looseKey(key), value as Record<string, unknown>);
    }
  }

  for (const target of params.targets) {
    const candidate =
      byLooseKey.get(looseKey(target.id)) ?? byLooseKey.get(looseKey(target.canonicalName));
    if (!candidate) continue;
    const values = sanitizePer100g(candidate);
    if (Object.keys(values).length === 0) continue;
    out.set(target.id, values);
  }

  await logInfo({
    message: `estimatePer100gBatchWithAI: ${out.size}/${params.targets.length} ingrédient(s) estimé(s)`,
    extra: {
      correlationId: params.correlationId,
      estimated: [...out.keys()],
      missing: params.targets.filter((t) => !out.has(t.id)).map((t) => t.id),
    },
  });

  return out;
}

/** Marques diacritiques laissées par la décomposition NFD. */
const DIACRITICS = new RegExp("[\\u0300-\\u036f]", "g");

/** Clé de rapprochement insensible à la casse, aux accents et à la ponctuation. */
function looseKey(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(DIACRITICS, "")
    .replace(/[^a-z0-9]+/g, "");
}

export async function estimatePer100gWithGemini(params: {
  ingredientId: string;
  canonicalName: string;
  aliases: string[];
  correlationId: string;
  userId?: string;
  feature?: string;
  /** Deuxième tentative : le prompt rappelle qu'une valeur est obligatoire. */
  insist?: boolean;
}): Promise<Record<string, number>> {
  const target: Per100gEnrichmentTarget = {
    id: params.ingredientId,
    canonicalName: params.canonicalName,
    aliases: params.aliases,
  };

  const prompt = [
    ...estimationRules(),
    ...(params.insist
      ? [
          "",
          "ATTENTION : une première tentative n'a produit aucune valeur exploitable.",
          "Cet ingrédient EXISTE et se mange : donne obligatoirement une estimation moyenne,",
          "quitte à choisir le produit du commerce le plus proche.",
        ]
      : []),
    "",
    `identifiant : ${target.id}`,
    `nom : ${target.canonicalName}`,
    `aussi écrit : ${target.aliases.slice(0, 8).join(", ") || "(aucun)"}`,
    "",
    "Format strict attendu :",
    '{"per100g":{"kcal":0,"protein_g":0,"carbs_g":0,"sugar_g":0,"fiber_g":0,"fat_g":0,"saturated_fat_g":0,"sodium_mg":0,"salt_g":0}}',
  ].join("\n");

  const feature = params.feature ?? "nutrition_ingredients_enrichment";
  const result = await callModel({
    parts: [modelTextPart(prompt)],
    ctx: {
      correlationId: params.correlationId,
      feature,
      moduleType: "DESIGN",
      timeoutMs: 45_000,
      userId: params.userId,
    },
    outputSchema: { name: "per100g_single", schema: PER100G_SINGLE_SCHEMA as unknown as Record<string, unknown> },
    usageMeta: {
      entityType: "nutrition_ingredient",
      entityId: params.ingredientId,
    },
  });

  const text = result.text.trim();
  if (!text) {
    await logError({
      message: `estimatePer100gWithGemini: réponse vide pour "${params.ingredientId}"`,
      errorDescription: `${result.provider} a retourné une réponse vide`,
      correlationId: params.correlationId,
    });
    return {};
  }

  try {
    const parsed = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
    const rawPer100g = (
      parsed.per100g && typeof parsed.per100g === "object" ? parsed.per100g : parsed
    ) as Record<string, unknown>;

    const values = sanitizePer100g(rawPer100g);
    if (Object.keys(values).length === 0) {
      await logError({
        message: `estimatePer100gWithGemini: estimation inexploitable pour "${params.ingredientId}"`,
        errorDescription: params.insist
          ? "Gemini n'a produit aucune valeur plausible malgré l'insistance"
          : "Gemini a répondu des valeurs nulles ou invraisemblables",
        correlationId: params.correlationId,
        extra: { rawResponse: text.slice(0, 400), insist: params.insist === true },
      });
      return {};
    }

    await logInfo({
      message: `estimatePer100gWithGemini: per100g estimé pour "${params.ingredientId}"`,
      extra: { correlationId: params.correlationId, per100g: values, insist: params.insist === true },
    });
    return values;
  } catch (err) {
    await logError({
      message: `estimatePer100gWithGemini: erreur parsing JSON pour "${params.ingredientId}"`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: params.correlationId,
      extra: { rawText: text.slice(0, 400) },
    });
    return {};
  }
}

/**
 * Estime les per100g d'une liste d'ingrédients, sans plafond de nombre.
 *
 * Déroulé : lots de [PER100G_BATCH_SIZE] ingrédients, puis rattrapage
 * individuel insistant pour ceux que le lot n'a pas couverts. C'est le point
 * d'entrée unique des trois chemins d'enrichissement.
 *
 * Ne lève jamais : un lot en échec laisse ses ingrédients au rattrapage, et un
 * rattrapage en échec laisse l'ingrédient absent du résultat — toujours avec
 * une trace d'erreur, jamais en silence.
 */
export async function estimatePer100gForTargets(params: {
  targets: Per100gEnrichmentTarget[];
  correlationId: string;
  userId?: string;
  feature?: string;
  /** Instant limite : au-delà, on arrête proprement plutôt que de se faire couper. */
  deadlineMs?: number;
}): Promise<Map<string, Record<string, number>>> {
  const estimated = new Map<string, Record<string, number>>();
  if (params.targets.length === 0) return estimated;

  const withinDeadline = (): boolean =>
    params.deadlineMs == null || Date.now() < params.deadlineMs;

  for (let i = 0; i < params.targets.length; i += PER100G_BATCH_SIZE) {
    if (!withinDeadline()) break;
    const chunk = params.targets.slice(i, i + PER100G_BATCH_SIZE);
    try {
      const batch = await estimatePer100gBatchWithAI({
        targets: chunk,
        correlationId: params.correlationId,
        userId: params.userId,
        feature: params.feature ? `${params.feature}_batch` : undefined,
      });
      for (const [id, values] of batch) estimated.set(id, values);
    } catch (err) {
      await logError({
        message: "estimatePer100gForTargets: lot en échec (rattrapage individuel)",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: params.correlationId,
        extra: { ingredientIds: chunk.map((t) => t.id) },
      });
    }
  }

  // Les relances sont individuelles, donc coûteuses en temps : une par appel.
  // Elles sont plafonnées pour qu'un référentiel massivement vide ne transforme
  // pas la passe en file d'attente de plusieurs minutes — l'échéance seule ne
  // suffit pas, elle n'est vérifiée qu'entre deux appels.
  const missed = params.targets
    .filter((t) => !estimated.has(t.id))
    .slice(0, MAX_INDIVIDUAL_RETRIES);
  for (const target of missed) {
    if (!withinDeadline()) break;
    try {
      const values = await estimatePer100gWithGemini({
        ingredientId: target.id,
        canonicalName: target.canonicalName,
        aliases: target.aliases,
        correlationId: params.correlationId,
        userId: params.userId,
        feature: params.feature,
        insist: true,
      });
      if (Object.keys(values).length > 0) estimated.set(target.id, values);
    } catch (err) {
      await logError({
        message: `estimatePer100gForTargets: rattrapage échoué pour "${target.id}"`,
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: params.correlationId,
      });
    }
  }

  return estimated;
}
