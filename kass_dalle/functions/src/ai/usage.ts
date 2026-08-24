/**
 * Point d'écriture unique de la consommation.
 *
 * Trois chemins écrivaient auparavant leur propre version de la même chose :
 * les appels de texte via le routeur, les appels d'image via `tokenUsage.ts`,
 * le scan de sécurité directement dans la callable. Chacun avec ses champs,
 * ses conventions et ses oublis — l'un ne posait pas de `provider`, l'autre pas
 * de `correlation_id`, le troisième n'alimentait pas le même agrégat par
 * utilisateur. Additionner ces trois écritures revenait à additionner trois
 * unités différentes.
 *
 * Tout passe désormais par `recordUsage`, qui écrit trois choses d'un coup :
 *
 *  1. `ai_usage/{auto}` — la ligne d'appel, pour l'audit et la réconciliation ;
 *  2. `token_usage/{uid}` — l'agrégat par utilisateur, schéma unique ;
 *  3. `ai_usage_monthly/{AAAA-MM}` — l'agrégat mensuel par poste, moteur et
 *     modèle, qui est ce que lisent les écrans ;
 *  4. `ai_daily_spend/{uid}_{AAAA-MM-JJ}` — la dépense du jour, que le plafond
 *     relit avant chaque appel.
 *
 * Le coût est calculé **ici et une seule fois**. Les écrans l'affichent, ils ne
 * le recalculent pas : deux grilles tarifaires appliquées au même appel finissent
 * toujours par diverger, et c'est le genre d'écart qui ne casse aucun écran.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_AI_USAGE, COLL_AI_USAGE_MONTHLY, COLL_TOKEN_USAGE } from "../config";
import { logError } from "../logging";
import { periodOf } from "../billing/periods";
import { estimateAiCostUsd, loadAiPricingTable } from "./pricing";
import { addToDailySpend } from "./budget";
import type { AiProvider } from "./types";

/** Fournisseur d'un appel — `internal` couvre ce qui n'est pas de l'inférence. */
export type UsageProvider = AiProvider | "internal";

export interface UsageEntry {
  /** Poste fonctionnel : la clé de tout le reporting. */
  feature: string;
  provider: UsageProvider;
  /** Identifiant de modèle, ou nom du service pour un poste interne. */
  model: string;
  userId?: string | null;
  correlationId?: string | null;
  inputTokens?: number;
  /** Jetons du texte rendu à l'appelant. */
  outputTokens?: number;
  /**
   * Jetons de raisonnement, facturés au tarif de sortie.
   *
   * Comptés dans le coût, gardés à part dans l'affichage : c'est la seule
   * manière de voir qu'un poste coûte cher parce qu'il fait réfléchir le
   * modèle, et non parce qu'il produit beaucoup.
   */
  thinkingTokens?: number;
  /**
   * Jetons de prompt passés par le cache — écrits, puis relus.
   *
   * Ce sont des jetons d'**entrée** que le fournisseur compte à part et
   * facture à un autre tarif : 1,25 fois l'entrée à l'écriture, un dixième à
   * la relecture. Les additionner à `inputTokens` chiffrerait faux ; les
   * ignorer ferait disparaître du comptage tout ce qui passe par le cache.
   */
  cacheCreationInputTokens?: number;
  cacheReadInputTokens?: number;
  imageOutputCount?: number;
  /**
   * Unités facturées à l'unité pour une image analysée.
   *
   * La modération d'images est facturée par unité de fonctionnalité, pas au
   * jeton : deux unités par image. Le prix vit dans la grille, comme les
   * autres — rien n'est figé ici.
   */
  analyzedImageUnits?: number;
  /**
   * Coût imposé, pour un poste dont le prix ne se déduit pas des jetons
   * (scan de sécurité facturé à l'unité, par exemple). Sinon, il est calculé
   * depuis la grille tarifaire.
   */
  costUsdOverride?: number | null;
  entityType?: string | null;
  entityId?: string | null;
  costBucket?: string;
  /**
   * Issue de l'appel.
   *
   * Un appel échoué compte pour un appel : le fournisseur l'a servi, ou a
   * commencé à le servir, et le facture. Il n'apporte aucun jeton — d'où un
   * coût nul — mais il doit rester visible, sans quoi le nombre d'appels de
   * l'écran ne peut pas se rapprocher de celui de la facture.
   */
  status?: "ok" | "error";
}

/** Utilisateur retenu quand l'appel n'est rattaché à personne. */
const UNATTRIBUTED = "system_unattributed";

/** Période `AAAA-MM` d'une date, en UTC — la même que la réconciliation. */
export function usagePeriod(date: Date): string {
  return periodOf(date);
}

/**
 * Une clé de map Firestore ne peut contenir ni `.` ni `/` ni `~` ni `*` ni `[`
 * ni `]`. Les identifiants de modèle (`gemini-2.5-flash`, `claude-sonnet-5`)
 * passent tels quels aujourd'hui, mais un `gemini-1.5-pro-002.1` casserait
 * l'écriture — et une écriture d'agrégat qui échoue fait disparaître un mois
 * entier du reporting, pas seulement une ligne.
 */
export function sanitizeMapKey(value: string): string {
  const cleaned = value.replace(/[.$/[\]~*#]/g, "_").trim();
  return cleaned.length > 0 ? cleaned : "inconnu";
}

/**
 * Ce qu'un appel ajoute à l'agrégat du mois.
 *
 * Sortie de `recordUsage` pour une seule raison : la FORME de cet objet est ce
 * qui s'est cassé, et une forme se teste sans base de données.
 *
 * Les compteurs étaient écrits avec des clés pointées — `by_user.abc.cost_usd`.
 * `set()` du SDK Admin ne lit pas les points comme un chemin : il a créé
 * pendant des mois des champs dont le NOM contenait des points, à côté des
 * cartes que les écrans lisent. Les deux ont grandi séparément dans le même
 * document. L'écran affichait 5 € là où le mois en portait 38, et les deux
 * chiffres étaient sincères — ils ne parlaient pas de la même chose.
 *
 * Rien ne le signalait : ni Firestore, ni les règles, ni un test. D'où
 * `aggregateKeyPaths`, et le cas qui interdit le point dans une clé.
 */
export function buildMonthlyAggregate(args: {
  period: string;
  feature: string;
  provider: string;
  model: string;
  userKey: string;
  failed: boolean;
  priced: boolean;
  inputTokens: number;
  outputTokens: number;
  thinkingTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  imageOutputCount: number;
  /**
   * Unités d'image ANALYSÉE facturées par cet appel.
   *
   * Comptées ici parce qu'elles sont la seule quantité dont dépend une
   * franchise mensuelle : sans compteur, personne ne sait combien d'unités le
   * mois a consommées, et les unités offertes ne peuvent pas être déduites.
   */
  analyzedImageUnits: number;
  costIncrement: number;
}): Record<string, unknown> {
  const {
    period,
    feature,
    provider,
    model,
    userKey,
    failed,
    priced,
    inputTokens,
    outputTokens,
    thinkingTokens,
    cacheWriteTokens,
    cacheReadTokens,
    imageOutputCount,
    analyzedImageUnits,
    costIncrement,
  } = args;

  return {
    period,
    updated_at: FieldValue.serverTimestamp(),
    total_calls: FieldValue.increment(1),
    total_failed_calls: FieldValue.increment(failed ? 1 : 0),
    // Ces appels ont consommé des jetons dont le coût reste inconnu. Sans
    // ce compteur, un mois traversé par une panne de grille afficherait un
    // total plus bas — et parfaitement crédible.
    total_unpriced_calls: FieldValue.increment(priced ? 0 : 1),
    total_input_tokens: FieldValue.increment(inputTokens),
    total_output_tokens: FieldValue.increment(outputTokens),
    total_thinking_tokens: FieldValue.increment(thinkingTokens),
    // Comptés au mois et par moteur, pas par poste : la question qu'ils
    // servent à trancher — « du prompt passe-t-il par le cache ? » — se
    // pose au niveau du moteur. Les ventiler par poste gonflerait le
    // document sans rien apprendre de plus.
    total_cache_creation_input_tokens: FieldValue.increment(cacheWriteTokens),
    total_cache_read_input_tokens: FieldValue.increment(cacheReadTokens),
    total_image_outputs: FieldValue.increment(imageOutputCount),
    // Une image PRODUITE et une image ANALYSÉE sont deux produits à deux prix.
    // Ce compteur porte la seconde, et lui seul permet de déduire au mois les
    // unités qu'un fournisseur offre.
    total_analyzed_image_units: FieldValue.increment(analyzedImageUnits),
    total_cost_usd: FieldValue.increment(costIncrement),
    // Des cartes IMBRIQUÉES, et non des clés pointées.
    //
    // `set()` du SDK Admin ne lit pas les points comme un chemin : la clé
    // `by_user.abc.cost_usd` crée un champ dont le NOM contient des points,
    // à côté de la carte `by_user` que les écrans lisent. Les deux ont
    // cohabité dans le même document — 618 champs plats qui grossissaient,
    // et des cartes figées au dernier passage de la reconstruction. L'écran
    // affichait 5 € quand le mois en portait 38, sans qu'aucune erreur ne
    // sorte : les deux chiffres étaient sincères, ils ne parlaient pas de
    // la même chose.
    //
    // `FieldValue.increment` fonctionne à n'importe quelle profondeur, du
    // moment que le chemin est fait d'objets et non d'une clé pointée.
    by_feature: {
      [feature]: {
        calls: FieldValue.increment(1),
        input_tokens: FieldValue.increment(inputTokens),
        output_tokens: FieldValue.increment(outputTokens),
        thinking_tokens: FieldValue.increment(thinkingTokens),
        image_outputs: FieldValue.increment(imageOutputCount),
        analyzed_image_units: FieldValue.increment(analyzedImageUnits),
        cost_usd: FieldValue.increment(costIncrement),
        // La ventilation par moteur DANS le poste est ce qui permet de juger
        // une bascule : sans elle, on voit le coût monter sans savoir lequel
        // des deux moteurs le fait monter.
        by_provider: {
          [provider]: {
            calls: FieldValue.increment(1),
            cost_usd: FieldValue.increment(costIncrement),
            input_tokens: FieldValue.increment(inputTokens),
            output_tokens: FieldValue.increment(outputTokens),
            thinking_tokens: FieldValue.increment(thinkingTokens),
          },
        },
      },
    },
    by_provider: {
      [provider]: {
        calls: FieldValue.increment(1),
        input_tokens: FieldValue.increment(inputTokens),
        output_tokens: FieldValue.increment(outputTokens),
        thinking_tokens: FieldValue.increment(thinkingTokens),
        cache_creation_input_tokens: FieldValue.increment(cacheWriteTokens),
        cache_read_input_tokens: FieldValue.increment(cacheReadTokens),
        cost_usd: FieldValue.increment(costIncrement),
      },
    },
    by_model: {
      [model]: {
        calls: FieldValue.increment(1),
        cost_usd: FieldValue.increment(costIncrement),
        // La franchise se déduit PAR MODÈLE : c'est le fournisseur qui offre,
        // et il l'offre sur un produit, pas sur un poste fonctionnel. Compter
        // les unités ailleurs obligerait à les recomposer pour les déduire.
        analyzed_image_units: FieldValue.increment(analyzedImageUnits),
      },
    },
    by_user: {
      [userKey]: {
        calls: FieldValue.increment(1),
        cost_usd: FieldValue.increment(costIncrement),
        // Le poste DANS le compte : c'est ce qui répond à « qui dépense, et
        // à quoi ? ».
        by_feature: {
          [feature]: {
            calls: FieldValue.increment(1),
            cost_usd: FieldValue.increment(costIncrement),
          },
        },
      },
    },
  };
}

/**
 * Tous les chemins de clés d'un objet, en notation pointée.
 *
 * Sert au test qui interdit le point DANS une clé. La notation pointée est ici
 * la sortie, jamais l'entrée : c'est exactement la confusion qui a produit le
 * défaut.
 */
export function aggregateKeyPaths(value: unknown, prefixe = ""): string[] {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [];
  // Une sentinelle `FieldValue` est un objet, mais pas une carte : elle n'a pas
  // de clés à explorer, et les siennes ne sont pas des champs Firestore.
  if (value.constructor && value.constructor.name !== "Object") return [];

  const chemins: string[] = [];
  for (const [cle, sous] of Object.entries(value as Record<string, unknown>)) {
    const chemin = prefixe ? `${prefixe}.${cle}` : cle;
    chemins.push(chemin);
    chemins.push(...aggregateKeyPaths(sous, chemin));
  }
  return chemins;
}

export interface RecordedUsage {
  /** `null` quand la grille tarifaire était indisponible au moment de l'appel. */
  costUsd: number | null;
  totalTokens: number;
  period: string;
}

/**
 * Enregistre un appel : ligne d'audit, agrégat utilisateur, agrégat mensuel.
 *
 * Aucun seuil, aucun court-circuit : un appel sans jeton connu (un modèle qui
 * ne renvoie pas ses métadonnées, une réponse tronquée) est enregistré avec
 * zéro jeton. L'ancien code retournait sans rien écrire dans ce cas, si bien
 * qu'un appel réellement facturé par le fournisseur pouvait n'apparaître nulle
 * part — l'écart était ensuite imputé à « non attribué » sans que personne ne
 * sache d'où il venait.
 */
export async function recordUsage(entry: UsageEntry): Promise<RecordedUsage> {
  const db = getFirestore();
  const now = new Date();
  const period = usagePeriod(now);

  const inputTokens = Math.max(0, Math.round(entry.inputTokens ?? 0));
  const outputTokens = Math.max(0, Math.round(entry.outputTokens ?? 0));
  const thinkingTokens = Math.max(0, Math.round(entry.thinkingTokens ?? 0));
  const cacheWriteTokens = Math.max(0, Math.round(entry.cacheCreationInputTokens ?? 0));
  const cacheReadTokens = Math.max(0, Math.round(entry.cacheReadInputTokens ?? 0));
  const imageOutputCount = Math.max(0, Math.round(entry.imageOutputCount ?? 0));
  const analyzedImageUnits = Math.max(0, Math.round(entry.analyzedImageUnits ?? 0));
  // Les jetons de cache comptent dans le total : ce sont des jetons de prompt
  // réellement facturés, pas une métadonnée. Les omettre ferait apparaître un
  // appel plus léger qu'il ne l'a été.
  const totalTokens =
    inputTokens + outputTokens + thinkingTokens + cacheWriteTokens + cacheReadTokens;

  // Le raisonnement est facturé au tarif de sortie : c'est la même ligne sur
  // la facture. Il entre donc dans le calcul avec la sortie, et n'est séparé
  // que pour l'affichage.
  //
  // Sans grille lisible, le coût reste **inconnu**. Le chiffrer au tarif du
  // code produirait un montant périmé présenté comme exact : l'appel est donc
  // enregistré sans montant, compté à part, et l'incident est écrit.
  let costUsd: number | null = null;
  if (entry.costUsdOverride != null && Number.isFinite(entry.costUsdOverride)) {
    costUsd = entry.costUsdOverride;
  } else {
    try {
      costUsd = estimateAiCostUsd({
        model: entry.model,
        inputTokens,
        outputTokens: outputTokens + thinkingTokens,
        // Chacun son tarif : l'écriture de cache coûte plus qu'une entrée, la
        // relecture bien moins. Les ranger avec l'entrée les chiffrerait faux
        // dans les deux sens à la fois.
        cacheCreationInputTokens: cacheWriteTokens,
        cacheReadInputTokens: cacheReadTokens,
        imageOutputCount,
        analyzedImageUnits,
        at: now,
        // Grille en vigueur : un tarif corrigé depuis Admin chiffre l'appel
        // suivant, sans attendre un déploiement.
        table: await loadAiPricingTable(),
      });
    } catch (err) {
      await logError({
        message: "Appel non chiffré : grille tarifaire indisponible",
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { feature: entry.feature, model: entry.model },
      });
    }
  }
  const priced = costUsd != null;
  // Les compteurs monétaires n'avancent pas d'un appel non chiffré : ajouter
  // zéro le ferait passer pour gratuit.
  const costIncrement = costUsd ?? 0;

  const trimmedUserId = (entry.userId ?? "").trim();
  const effectiveUserId = trimmedUserId.length > 0 ? trimmedUserId : UNATTRIBUTED;
  const feature = sanitizeMapKey(entry.feature);
  const model = sanitizeMapKey(entry.model);
  const provider = entry.provider;

  // 1. La ligne d'appel — c'est elle que relit la réconciliation.
  await db.collection(COLL_AI_USAGE).add({
    uid: effectiveUserId,
    feature: entry.feature,
    provider,
    model: entry.model,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    thinking_tokens: thinkingTokens,
    cache_creation_input_tokens: cacheWriteTokens,
    cache_read_input_tokens: cacheReadTokens,
    total_tokens: totalTokens,
    image_output_count: imageOutputCount,
    // Écrit sur la ligne, et pas seulement consommé pour calculer le montant.
    // Sans lui, une reconstruction qui rechiffre relisait un appel Cloud Vision
    // sans ses unités : le coût de la modération tombait à zéro, et le mois
    // reconstruit se lisait comme un mois sans modération.
    analyzed_image_units: analyzedImageUnits,
    estimated_cost_usd: costUsd,
    // Faux ne veut rien dire ici : le champ n'existe que sur les appels
    // passés pendant une panne de grille, et c'est lui qui les rend
    // retrouvables pour un rechiffrage ultérieur.
    ...(priced ? {} : { pricing_unavailable: true }),
    status: entry.status ?? "ok",
    cost_bucket: entry.costBucket ?? "production",
    correlation_id: entry.correlationId ?? null,
    entity_type: entry.entityType ?? null,
    entity_id: entry.entityId ?? null,
    period,
    timestamp: FieldValue.serverTimestamp(),
  });

  // 2. L'agrégat par utilisateur — même schéma pour tous les types d'appel.
  if (trimmedUserId.length > 0) {
    await db
      .collection(COLL_TOKEN_USAGE)
      .doc(trimmedUserId)
      .set(
        {
          total_tokens: FieldValue.increment(totalTokens),
          total_cost_usd: FieldValue.increment(costIncrement),
          updated_at: FieldValue.serverTimestamp(),
          [`features.${feature}.input`]: FieldValue.increment(inputTokens),
          [`features.${feature}.output`]: FieldValue.increment(outputTokens),
          [`features.${feature}.thinking`]: FieldValue.increment(thinkingTokens),
          [`features.${feature}.total`]: FieldValue.increment(totalTokens),
          [`features.${feature}.image_outputs`]: FieldValue.increment(imageOutputCount),
          [`features.${feature}.cost_usd`]: FieldValue.increment(costIncrement),
          [`features.${feature}.count`]: FieldValue.increment(1),
        },
        { merge: true },
      );
  }

  // 3. L'agrégat mensuel — un document par mois, lu tel quel par les écrans.
  await db
    .collection(COLL_AI_USAGE_MONTHLY)
    .doc(period)
    .set(
      buildMonthlyAggregate({
        period,
        feature,
        provider,
        model,
        userKey: effectiveUserId,
        failed: entry.status === "error",
        priced,
        inputTokens,
        outputTokens,
        thinkingTokens,
        cacheWriteTokens,
        cacheReadTokens,
        imageOutputCount,
        analyzedImageUnits,
        costIncrement,
      }),
      { merge: true },
    );

  // 4. La dépense du jour — ce que le plafond relit avant l'appel suivant.
  //
  // Écrite ici, avec le reste, parce que c'est ici que le coût est connu. Un
  // appel non chiffré n'ajoute aucun montant mais compte pour un appel : c'est
  // ce qui permet au plafond de tenir même quand la grille tarifaire est en
  // panne et que plus rien n'a de prix.
  if (trimmedUserId.length > 0) {
    try {
      await addToDailySpend({ userId: trimmedUserId, costUsd, at: now });
    } catch (err) {
      // Best-effort : un compteur de plafond qui n'a pas pu s'incrémenter ne
      // doit pas faire échouer un appel déjà payé. Mais il rend le plafond
      // trop permissif d'un appel, et cela doit se voir.
      await logError({
        message: "Dépense du jour non incrémentée : le plafond en est faussé d'autant",
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: trimmedUserId,
        extra: { feature: entry.feature },
      });
    }
  }

  return { costUsd, totalTokens, period };
}
