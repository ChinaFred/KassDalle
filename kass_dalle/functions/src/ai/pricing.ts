/**
 * Grille tarifaire des modèles d'IA du projet, tous fournisseurs confondus.
 *
 * Anciennement `gemini/pricing.ts`. Le fichier a changé de nom le jour où un
 * second fournisseur est entré : une table nommée « Gemini » qui contient les
 * tarifs Claude est le genre de mensonge de nommage qui finit par tromper
 * quelqu'un — et ici, ce quelqu'un lit un chiffre de coûts qu'il croit exact.
 *
 * ## Une seule grille, et pas de repli
 *
 * Les prix qui font foi vivent dans Firestore (`app_config/ai_pricing`),
 * modifiables depuis Admin → Moteur d'IA : un fournisseur change ses tarifs
 * bien plus souvent qu'on ne déploie, et attendre une livraison pour corriger
 * un prix, c'est accepter de chiffrer faux entre-temps.
 *
 * La table écrite ci-dessous ne sert qu'à **semer** ce document la première
 * fois. Elle n'est pas un secours : si la grille devient illisible, aucun prix
 * n'est deviné. Un tarif du code appliqué à la place du tarif réel serait un
 * prix périmé présenté comme exact — le chiffre s'afficherait, crédible et
 * faux, ce que tout ce module existe pour empêcher. Une panne se dit.
 *
 * Les appels passés pendant une panne sont enregistrés **sans montant** et
 * comptés à part : leurs jetons sont connus, leur coût ne l'est pas, et le
 * reporting le montre au lieu de les compter à zéro.
 *
 * Ce qui reste dupliqué avec le Dart (`features/admin/data/ai_pricing.dart`),
 * ce ne sont plus les prix — c'est la **résolution** d'un identifiant de modèle
 * et l'arithmétique du coût. La fixture `test-fixtures/ai_pricing.json` les
 * asservit, et fournit désormais la table aux tests des deux côtés.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";
import { logError, logInfo } from "../logging";

/**
 * Tarif promotionnel d'un modèle, borné dans le temps.
 *
 * `until` est une borne **exclue** : au premier instant de cette date, le tarif
 * catalogue reprend. Sans date, une promotion se transforme en tarif permanent
 * le jour où elle expire, et le reporting se met à sous-estimer sans que rien
 * ne le signale.
 */
export interface AiIntroductoryPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  untilIso: string;
}

export interface AiModelPricing {
  inputPerMillion: number;
  outputPerMillion: number;
  imageOutputPerUnit?: number;
  /**
   * Coût d'une image ANALYSÉE, à l'unité — distinct d'une image produite.
   *
   * Une image produite et une image analysée sont deux produits à deux prix ;
   * les faire passer par le même champ ferait mentir le reporting le jour où
   * l'un des deux bouge.
   */
  analyzedImagePerUnit?: number;
  /** Unités offertes par mois — déduites au mois, jamais sur la ligne d'appel. */
  freeUnitsPerMonth?: number;
  introductory?: AiIntroductoryPricing;
}

const DEFAULT_PRICING: AiModelPricing = {
  inputPerMillion: 0.3,
  outputPerMillion: 2.5,
  imageOutputPerUnit: 0,
};

const PRICING_TABLE: Record<string, AiModelPricing> = {
  // ── Google Gemini ────────────────────────────────────────────────────────
  "gemini-2.5-flash": { inputPerMillion: 0.3, outputPerMillion: 2.5, imageOutputPerUnit: 0 },
  // Ancien modèle image du projet, conservé pour les mois déjà consommés : leurs
  // lignes portent cet identifiant, et sans l'entrée elles se reliraient au
  // tarif par défaut, images comprises — c'est-à-dire à zéro.
  "gemini-2.5-flash-image": {
    inputPerMillion: 0.3,
    outputPerMillion: 2.5,
    imageOutputPerUnit: 0.04,
  },
  "gemini-2.5-pro": { inputPerMillion: 1.25, outputPerMillion: 10.0, imageOutputPerUnit: 0 },
  "gemini-2.0-flash": { inputPerMillion: 0.1, outputPerMillion: 0.4, imageOutputPerUnit: 0 },
  "gemini-1.5-flash": { inputPerMillion: 0.075, outputPerMillion: 0.3, imageOutputPerUnit: 0 },
  "gemini-1.5-pro": { inputPerMillion: 1.25, outputPerMillion: 5.0, imageOutputPerUnit: 0 },
  // Nano Banana 2 Lite — modèle image courant (`GEMINI_IMAGE_MODEL`).
  // 0,0336 $ l'image 1K : 1120 jetons de sortie facturés 30 $ le million.
  "gemini-3.1-flash-lite-image": {
    inputPerMillion: 0.25,
    outputPerMillion: 1.5,
    imageOutputPerUnit: 0.0336,
  },

  // ── Anthropic Claude ─────────────────────────────────────────────────────
  // Tarifs catalogue au 12 août 2026.
  //
  // Le tarif d'introduction de Sonnet 5 était volontairement ignoré, au motif
  // qu'une surestimation valait mieux qu'une sous-estimation. Une marge de
  // sécurité posée sur un instrument de mesure ne le sécurise pas : elle le
  // casse. Il a donc été inscrit — sur la foi d'une facture d'août lue en
  // cours de mois, comparée à une estimation complète. Deux mesures prises à
  // des instants différents, ce que l'écran reproche maintenant lui-même.
  //
  // Août clos et ventilé par modèle disait l'inverse : un prix unitaire facturé
  // SUPÉRIEUR au tarif catalogue, donc aucune promotion. Cette lecture était
  // fausse : l'agrégat d'août portait alors deux comptabilités parallèles.
  //
  // Septembre 2026, relu ligne à ligne dans `ai_usage` et comparé au rapport de
  // coûts d'Anthropic du 26 septembre : Sonnet 5 revient à 1,91 $ l'entrée et
  // 9,05 $ la sortie par million de jetons comptés, Opus 5 à 4,66 $ et 22,30 $.
  // Les deux modèles s'écartent de 5 à 11 % de leur tarif dans le même sens, ce
  // qui est un retard de relevé. Sonnet 5 vaut donc 2 $ / 10 $. La page des tarifs
  // d'Anthropic le confirme : ce prix est devenu le prix courant, le relèvement à
  // 3 $ / 15 $ prévu le 1er septembre n'a pas eu lieu.
  //
  // La graine garde 3 $ / 15 $ et sa promotion, et c'est volontaire : la fixture
  // `ai_pricing.json` les verrouille pour éprouver le MÉCANISME d'une promotion
  // datée, et cette table ne sert qu'à semer la grille au premier démarrage. La
  // grille en vigueur vit dans Firestore : Sonnet 5 s'y corrige depuis
  // Admin → Moteur d'IA (2 / 10, promotion décochée), puis Admin → Coûts →
  // « Reconstruire les agrégats » avec « Rechiffrer aussi les appels ».
  "claude-opus-5": { inputPerMillion: 5.0, outputPerMillion: 25.0, imageOutputPerUnit: 0 },
  "claude-opus-4-8": { inputPerMillion: 5.0, outputPerMillion: 25.0, imageOutputPerUnit: 0 },
  "claude-sonnet-5": {
    inputPerMillion: 3.0,
    outputPerMillion: 15.0,
    imageOutputPerUnit: 0,
    introductory: {
      inputPerMillion: 2.0,
      outputPerMillion: 10.0,
      untilIso: "2026-09-01T00:00:00Z",
    },
  },
  "claude-sonnet-4-6": { inputPerMillion: 3.0, outputPerMillion: 15.0, imageOutputPerUnit: 0 },
  "claude-haiku-4-5": { inputPerMillion: 1.0, outputPerMillion: 5.0, imageOutputPerUnit: 0 },

  // ── Google Cloud Vision ──────────────────────────────────────────────────
  // Facturé à l'unité, pas au jeton : deux unités par image (SafeSearch et
  // Label sont deux fonctionnalités). Les mille premières unités du mois sont
  // offertes — la déduction se fait AU MOIS, pas sur la ligne d'appel, pour
  // que deux appels simultanés ne se disputent pas un compteur.
  "cloud-vision-safesearch": {
    inputPerMillion: 0,
    outputPerMillion: 0,
    imageOutputPerUnit: 0,
    analyzedImagePerUnit: 0.0015,
    freeUnitsPerMonth: 1000,
  },
};

/**
 * Corrections vérifiées, appliquées une fois par `backfillAiPricingFn`.
 *
 * `PRICING_TABLE` ne sert qu'à semer le document au premier démarrage, et son
 * entrée Sonnet 5 reste volontairement à 3 $ / 15 $ pour éprouver le
 * MÉCANISME d'une promotion datée dans la fixture — voir le commentaire
 * au-dessus. Cette table-ci est l'inverse : chaque entrée est une valeur
 * MESURÉE, jamais un repli, écrite dans Firestore par un geste explicite
 * d'administrateur et jamais lue à la place de la grille en vigueur.
 *
 * Une correction reste ici après avoir été appliquée : le backfill compare la
 * grille en vigueur à cette table à chaque lancement, et une entrée déjà
 * corrigée ressort simplement « déjà correcte ». Elle ne se retire que le jour
 * où le tarif catalogue rejoint réellement cette valeur.
 */
export const PRICING_CORRECTIONS: Record<string, AiModelPricing> = {
  // Relu ligne à ligne dans `ai_usage` et comparé au rapport de coûts
  // d'Anthropic du 26 septembre 2026 : Sonnet 5 revient à 1,91 $ / 9,05 $ par
  // million de jetons comptés, contre un catalogue à 3 $ / 15 $ — un écart de
  // 5 à 11 % dans le même sens que celui d'Opus 5, donc un retard de relevé,
  // pas une promotion. La page tarifaire d'Anthropic confirme que le
  // relèvement à 3 $ / 15 $ prévu le 1er septembre 2026 n'a pas eu lieu :
  // Sonnet 5 vaut 2 $ / 10 $, sans date de fin.
  "claude-sonnet-5": { inputPerMillion: 2.0, outputPerMillion: 10.0, imageOutputPerUnit: 0 },
};

/** Identifiant du document Firestore portant la grille en vigueur. */
export const AI_PRICING_DOC_ID = "ai_pricing";

/**
 * Grille d'amorçage, telle qu'elle est écrite dans ce fichier.
 *
 * Sert à semer `app_config/ai_pricing` au premier démarrage, et de référence à
 * l'écran d'administration pour dire quels tarifs ont été modifiés depuis.
 * Elle n'est jamais appliquée à la place de la grille en vigueur.
 */
export function builtinPricingTable(): Record<string, AiModelPricing> {
  return { ...PRICING_TABLE };
}

/**
 * Lit une entrée de tarif depuis sa forme Firestore (snake_case).
 *
 * Une entrée dont les deux tarifs de jetons sont illisibles est rejetée : ce
 * modèle n'a alors plus de prix du tout, ce qui est vrai, plutôt qu'un modèle
 * facturé zéro parce qu'une saisie a mis du texte là où on attendait un nombre.
 */
export function parsePricingEntry(raw: unknown): AiModelPricing | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const num = (v: unknown): number | null =>
    typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;

  const input = num(o.input_per_million);
  const output = num(o.output_per_million);
  if (input == null || output == null) return null;

  const entry: AiModelPricing = {
    inputPerMillion: input,
    outputPerMillion: output,
    imageOutputPerUnit: num(o.image_output_per_unit) ?? 0,
    analyzedImagePerUnit: num(o.analyzed_image_per_unit) ?? 0,
    freeUnitsPerMonth: num(o.free_units_per_month) ?? 0,
  };

  const promoRaw = o.introductory;
  if (promoRaw && typeof promoRaw === "object") {
    const p = promoRaw as Record<string, unknown>;
    const pIn = num(p.input_per_million);
    const pOut = num(p.output_per_million);
    const until = typeof p.until_iso === "string" ? p.until_iso : "";
    // Une promotion sans date de fin lisible devient un tarif permanent le jour
    // où elle expire : on la refuse plutôt que de sous-estimer indéfiniment.
    if (pIn != null && pOut != null && Number.isFinite(Date.parse(until))) {
      entry.introductory = { inputPerMillion: pIn, outputPerMillion: pOut, untilIso: until };
    }
  }
  return entry;
}

/** Rend une entrée sous sa forme Firestore. */
export function pricingEntryToMap(entry: AiModelPricing): Record<string, unknown> {
  return {
    input_per_million: entry.inputPerMillion,
    output_per_million: entry.outputPerMillion,
    image_output_per_unit: entry.imageOutputPerUnit ?? 0,
    analyzed_image_per_unit: entry.analyzedImagePerUnit ?? 0,
    free_units_per_month: entry.freeUnitsPerMonth ?? 0,
    introductory: entry.introductory
      ? {
          input_per_million: entry.introductory.inputPerMillion,
          output_per_million: entry.introductory.outputPerMillion,
          until_iso: entry.introductory.untilIso,
        }
      : null,
  };
}

/**
 * Une entrée de la grille en vigueur diffère-t-elle d'une correction vérifiée ?
 *
 * Compare tous les champs facturables, promotion comprise : une correction qui
 * ne fait que retirer une promotion expirée ne doit pas ressortir « déjà
 * correcte » alors que la promotion est encore là.
 */
export function pricingNeedsCorrection(
  current: AiModelPricing | null,
  correction: AiModelPricing,
): boolean {
  if (!current) return true;
  const promo = (p?: AiIntroductoryPricing): string =>
    p ? `${p.inputPerMillion}/${p.outputPerMillion}/${p.untilIso}` : "";
  return (
    current.inputPerMillion !== correction.inputPerMillion ||
    current.outputPerMillion !== correction.outputPerMillion ||
    (current.imageOutputPerUnit ?? 0) !== (correction.imageOutputPerUnit ?? 0) ||
    (current.analyzedImagePerUnit ?? 0) !== (correction.analyzedImagePerUnit ?? 0) ||
    (current.freeUnitsPerMonth ?? 0) !== (correction.freeUnitsPerMonth ?? 0) ||
    promo(current.introductory) !== promo(correction.introductory)
  );
}

/**
 * Tarif d'un identifiant de modèle dans une table donnée, correspondance exacte
 * d'abord, puis repli sur le préfixe LE PLUS LONG.
 *
 * Le repli rendait autrefois le premier préfixe rencontré. Comme
 * « gemini-2.5-flash » précède « gemini-2.5-flash-image » dans la table, une
 * révision datée d'un modèle d'image (« …-image-preview ») était résolue vers
 * le tarif texte : ses images étaient facturées zéro, et le reporting de coûts
 * restait crédible tout en étant faux. Le jumeau Dart portait le même défaut.
 */
export function pricingForModelIn(
  table: Record<string, AiModelPricing>,
  model: string,
): AiModelPricing {
  if (table[model]) return table[model];

  let best: AiModelPricing | null = null;
  let bestLength = -1;
  for (const [prefix, pricing] of Object.entries(table)) {
    if (model.startsWith(prefix) && prefix.length > bestLength) {
      best = pricing;
      bestLength = prefix.length;
    }
  }
  return best ?? DEFAULT_PRICING;
}

/** Tarif d'un modèle dans la grille d'amorçage — usage interne et tests. */
export function getPricingForModel(model: string): AiModelPricing {
  return pricingForModelIn(PRICING_TABLE, model);
}

/**
 * Tarif réellement en vigueur à une date donnée.
 *
 * `getPricingForModel` rend l'entrée de catalogue, promotion comprise ; c'est
 * ici qu'on décide laquelle des deux s'applique.
 */
export function effectivePricing(model: string, at: Date): AiModelPricing {
  return effectivePricingIn(PRICING_TABLE, model, at);
}

/** Idem, dans une grille donnée. */
export function effectivePricingIn(
  table: Record<string, AiModelPricing>,
  model: string,
  at: Date,
): AiModelPricing {
  const pricing = pricingForModelIn(table, model);
  const promo = pricing.introductory;
  if (!promo) return pricing;

  const until = Date.parse(promo.untilIso);
  // Une date de fin illisible ne doit pas offrir une promotion perpétuelle :
  // dans le doute, on facture au tarif catalogue.
  if (!Number.isFinite(until) || at.getTime() >= until) return pricing;

  return {
    inputPerMillion: promo.inputPerMillion,
    outputPerMillion: promo.outputPerMillion,
    imageOutputPerUnit: pricing.imageOutputPerUnit,
  };
}

/**
 * Multiplicateurs du cache de prompt, appliqués au **tarif d'entrée**.
 *
 * Anthropic ne facture pas les jetons de cache au prix d'une entrée ordinaire :
 * les écrire coûte 1,25 fois plus cher, les relire dix fois moins. Ils sont
 * comptés **en plus** de `input_tokens`, qui ne porte que le reste non mis en
 * cache — ne lire que ce dernier revient donc à ignorer purement et simplement
 * la partie mise en cache du prompt, sans qu'aucun écran ne s'en aperçoive.
 *
 * Le multiplicateur d'écriture vaut 1,25 pour une durée de vie de cinq minutes,
 * et 2 pour une heure. L'API rend le détail par durée dans un objet
 * `cache_creation` ; tant que le projet ne pose aucun `cache_control`, et donc
 * aucune durée d'une heure, le compteur agrégé et le tarif court suffisent.
 * Le jour où une durée d'une heure serait posée, il faudra lire ce détail :
 * l'écart serait silencieux, comme toujours ici.
 */
export const CACHE_WRITE_MULTIPLIER = 1.25;
export const CACHE_READ_MULTIPLIER = 0.1;

export function estimateAiCostUsd(args: {
  model: string;
  inputTokens: number;
  outputTokens: number;
  /** Jetons de prompt écrits dans le cache — facturés 1,25 fois l'entrée. */
  cacheCreationInputTokens?: number;
  /** Jetons de prompt servis depuis le cache — facturés un dixième de l'entrée. */
  cacheReadInputTokens?: number;
  imageOutputCount?: number;
  /** Unités facturées à l'unité pour une image analysée (Cloud Vision). */
  analyzedImageUnits?: number;
  /**
   * Instant de l'appel. Un appel se facture au tarif en vigueur **quand il a
   * eu lieu**, jamais au tarif du jour où on relit le rapport : sans cela, une
   * reconstruction d'agrégats après la fin d'une promotion réécrirait le passé.
   */
  at?: Date;
  /**
   * Grille à appliquer. Les appelants passent celle en vigueur, obtenue par
   * `loadAiPricingTable()` ; la table d'amorçage ne sert qu'aux tests.
   */
  table?: Record<string, AiModelPricing>;
}): number {
  const table = args.table ?? PRICING_TABLE;
  const pricing = effectivePricingIn(table, args.model, args.at ?? new Date());
  const images = args.imageOutputCount ?? 0;
  const analyzedUnits = args.analyzedImageUnits ?? 0;
  const cacheWrite = args.cacheCreationInputTokens ?? 0;
  const cacheRead = args.cacheReadInputTokens ?? 0;
  return (
    (args.inputTokens / 1e6) * pricing.inputPerMillion +
    (cacheWrite / 1e6) * pricing.inputPerMillion * CACHE_WRITE_MULTIPLIER +
    (cacheRead / 1e6) * pricing.inputPerMillion * CACHE_READ_MULTIPLIER +
    (args.outputTokens / 1e6) * pricing.outputPerMillion +
    images * (pricing.imageOutputPerUnit ?? 0) +
    analyzedUnits * (pricing.analyzedImagePerUnit ?? 0)
  );
}

// ── Franchise mensuelle ──────────────────────────────────────────────────────

/** Ce qu'un fournisseur a offert sur un modèle, pour un mois donné. */
export interface FreeTierCredit {
  model: string;
  /** Unités consommées dans le mois. */
  units: number;
  /** Unités offertes par le fournisseur chaque mois. */
  freeUnits: number;
  /** Unités effectivement couvertes — jamais plus que consommées. */
  coveredUnits: number;
  /** Avoir en dollars, à retrancher du mois. */
  creditUsd: number;
}

/**
 * Avoirs du mois, modèle par modèle.
 *
 * La franchise ne se déduit **jamais** sur une ligne d'appel : deux appels
 * simultanés se disputeraient un compteur, et deux lignes identiques
 * finiraient à deux prix. Elle ne se déduit pas davantage à l'écriture, pour
 * la même raison. Elle se calcule ici, une fois, à la lecture du mois — sur
 * des unités déjà comptées, que plus rien ne peut faire bouger.
 *
 * Les appels gardent donc leur montant brut, et c'est voulu : un appel a bien
 * coûté ce qu'il a coûté, c'est le MOIS qui reçoit un avoir. Le sens inverse —
 * répartir la remise sur les lignes — rendrait le premier appel du mois gratuit
 * et le mille-unième payant, pour un travail identique.
 *
 * Un mois dont les unités ne sont pas comptées ne reçoit aucun avoir. C'est
 * exact : on ne sait pas combien il en a consommé, et une franchise devinée
 * ferait afficher un mois moins cher qu'il ne l'a été.
 *
 * L'avoir est borné par ce qui a réellement été compté pour ce modèle. Sans
 * cette borne, un tarif corrigé en cours de mois pourrait rendre un avoir
 * supérieur à la dépense, et le mois s'afficherait en négatif.
 */
export function freeTierCredits(args: {
  table: Record<string, AiModelPricing>;
  /** Instant auquel lire la grille — la fin du mois concerné. */
  at: Date;
  /** Unités d'image analysée consommées, pour un identifiant de modèle. */
  unitsFor: (model: string) => number;
  /** Montant déjà compté pour ce modèle — borne haute de l'avoir. */
  costFor: (model: string) => number;
}): FreeTierCredit[] {
  const credits: FreeTierCredit[] = [];

  for (const model of Object.keys(args.table)) {
    const pricing = effectivePricingIn(args.table, model, args.at);
    const freeUnits = pricing.freeUnitsPerMonth ?? 0;
    const perUnit = pricing.analyzedImagePerUnit ?? 0;
    if (freeUnits <= 0 || perUnit <= 0) continue;

    const units = Math.max(0, args.unitsFor(model));
    if (units <= 0) continue;

    const coveredUnits = Math.min(units, freeUnits);
    const creditUsd = Math.min(coveredUnits * perUnit, Math.max(0, args.costFor(model)));
    if (creditUsd <= 0) continue;

    credits.push({ model, units, freeUnits, coveredUnits, creditUsd });
  }

  return credits.sort((a, b) => b.creditUsd - a.creditUsd);
}

// ── Grille en vigueur (Firestore, seule source) ──────────────────────────────

let cachedTable: { value: Record<string, AiModelPricing>; readAt: number } | null = null;
/** Durée de vie du cache mémoire — un tarif corrigé prend effet en une minute. */
const PRICING_TTL_MS = 60_000;

/** Vide le cache — réservé aux tests et à l'écriture d'un tarif. */
export function invalidateAiPricingCache(): void {
  cachedTable = null;
}

/** La grille n'a pas pu être lue : aucun prix n'est connu, aucun n'est inventé. */
export class AiPricingUnavailableError extends Error {
  constructor(cause: string) {
    super(`Grille tarifaire indisponible : ${cause}`);
    this.name = "AiPricingUnavailableError";
  }
}

/**
 * Grille en vigueur, lue dans `app_config/ai_pricing`.
 *
 * **Il n'y a pas de repli.** Un tarif du code appliqué à la place de la grille
 * serait un prix périmé présenté comme le prix réel : le chiffre s'afficherait,
 * crédible et faux, ce que tout ce module existe pour empêcher. Une grille
 * illisible est une panne, et une panne se dit.
 *
 * La table du code ne sert plus qu'une fois : à **semer** le document s'il
 * n'existe pas encore. Ce n'est pas un secours — après cette écriture, la
 * grille Firestore est seule à faire foi.
 */
export async function loadAiPricingTable(): Promise<Record<string, AiModelPricing>> {
  if (cachedTable && Date.now() - cachedTable.readAt < PRICING_TTL_MS) {
    return cachedTable.value;
  }

  let snap;
  try {
    snap = await getFirestore().collection(COLL_APP_CONFIG).doc(AI_PRICING_DOC_ID).get();
  } catch (err) {
    const cause = err instanceof Error ? err.message : String(err);
    await logError({
      message: "Grille tarifaire : lecture impossible, aucun coût ne sera chiffré",
      errorDescription: cause,
    });
    throw new AiPricingUnavailableError(cause);
  }

  // Premier démarrage : la grille du code est écrite une fois, puis oubliée.
  if (!snap.exists) {
    const seed = builtinPricingTable();
    const models: Record<string, unknown> = {};
    for (const [model, entry] of Object.entries(seed)) {
      models[model] = pricingEntryToMap(entry);
    }
    try {
      await getFirestore()
        .collection(COLL_APP_CONFIG)
        .doc(AI_PRICING_DOC_ID)
        .set({ models, seeded_at: new Date().toISOString() }, { merge: true });
    } catch (err) {
      const cause = err instanceof Error ? err.message : String(err);
      await logError({
        message: "Grille tarifaire : amorçage impossible",
        errorDescription: cause,
      });
      throw new AiPricingUnavailableError(cause);
    }
    await logInfo("Grille tarifaire amorcée depuis la table du code", {
      extra: { models: Object.keys(seed).length },
    });
    cachedTable = { value: seed, readAt: Date.now() };
    return seed;
  }

  const raw = (snap.data()?.models ?? {}) as Record<string, unknown>;
  const table: Record<string, AiModelPricing> = {};
  const rejected: string[] = [];
  for (const [model, entry] of Object.entries(raw)) {
    const parsed = parsePricingEntry(entry);
    if (parsed) table[model] = parsed;
    else rejected.push(model);
  }

  if (rejected.length > 0) {
    // Une entrée mal saisie ne retombe sur rien : le modèle concerné n'a plus
    // de prix, et ses appels seront comptés sans montant plutôt qu'à un tarif
    // deviné.
    await logError({
      message: "Grille tarifaire : entrées illisibles, ces modèles n'ont plus de prix",
      errorDescription: `Modèles rejetés : ${rejected.join(", ")}`,
      extra: { rejected },
    });
  }

  // Un modèle connu du code et absent de la grille y est SEMÉ, jamais appliqué
  // depuis le code.
  //
  // L'amorçage n'avait lieu qu'à la création du document. Tout modèle ajouté
  // ensuite n'atteignait donc jamais la grille — Cloud Vision est arrivé deux
  // jours après l'amorçage et n'y a jamais figuré. Ses appels se résolvaient
  // sur le tarif par défaut, qui compte des jetons : pour un modèle facturé à
  // l'unité, cela vaut zéro. La modération d'images a été chiffrée 0,00 $
  // pendant six jours, sans que `total_unpriced_calls` bronche — le compteur
  // ne connaît que les grilles illisibles, pas les grilles incomplètes.
  //
  // Ce n'est pas le repli que ce module refuse, et la différence tient en un
  // mot : on ÉCRIT dans Firestore, puis on relit Firestore. Une entrée déjà
  // présente mais illisible n'est jamais recouverte — elle reste sans prix, et
  // ses appels sans montant. Seul le silence complet est comblé.
  //
  // Effet de bord voulu : « Revenir au tarif du code » fait enfin ce que son
  // libellé promet. L'entrée supprimée réapparaît au tarif d'amorçage, au lieu
  // de disparaître de l'écran en laissant le modèle au tarif par défaut.
  const missing = Object.entries(builtinPricingTable()).filter(([model]) => !(model in raw));
  if (missing.length > 0) {
    const models: Record<string, unknown> = {};
    for (const [model, entry] of missing) {
      models[model] = pricingEntryToMap(entry);
      table[model] = entry;
    }
    try {
      await getFirestore()
        .collection(COLL_APP_CONFIG)
        .doc(AI_PRICING_DOC_ID)
        .set({ models, completed_at: new Date().toISOString() }, { merge: true });
      await logInfo("Grille tarifaire complétée : modèles du code absents de la grille", {
        extra: { models: missing.map(([model]) => model) },
      });
    } catch (err) {
      // L'écriture manquée n'invalide pas la lecture : la table rendue porte
      // déjà ces modèles, au tarif d'amorçage, et l'écriture sera retentée au
      // prochain chargement. Les taire ici les laisserait au tarif par défaut,
      // qui est deviné — c'est le pire des deux.
      await logError({
        message: "Grille tarifaire : complétion impossible, elle sera retentée",
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { models: missing.map(([model]) => model) },
      });
    }
  }

  if (Object.keys(table).length === 0) {
    await logError({
      message: "Grille tarifaire vide : aucun modèle exploitable",
    });
    throw new AiPricingUnavailableError("aucun modèle exploitable");
  }

  cachedTable = { value: table, readAt: Date.now() };
  return table;
}
