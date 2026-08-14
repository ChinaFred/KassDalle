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
 *     modèle, qui est ce que lisent les écrans.
 *
 * Le coût est calculé **ici et une seule fois**. Les écrans l'affichent, ils ne
 * le recalculent pas : deux grilles tarifaires appliquées au même appel finissent
 * toujours par diverger, et c'est le genre d'écart qui ne casse aucun écran.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_AI_USAGE, COLL_AI_USAGE_MONTHLY, COLL_TOKEN_USAGE } from "../config";
import { estimateAiCostUsd } from "./pricing";
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
  imageOutputCount?: number;
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
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
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

export interface RecordedUsage {
  costUsd: number;
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
  const imageOutputCount = Math.max(0, Math.round(entry.imageOutputCount ?? 0));
  const totalTokens = inputTokens + outputTokens + thinkingTokens;

  // Le raisonnement est facturé au tarif de sortie : c'est la même ligne sur
  // la facture. Il entre donc dans le calcul avec la sortie, et n'est séparé
  // que pour l'affichage.
  const costUsd =
    entry.costUsdOverride != null && Number.isFinite(entry.costUsdOverride)
      ? entry.costUsdOverride
      : estimateAiCostUsd({
          model: entry.model,
          inputTokens,
          outputTokens: outputTokens + thinkingTokens,
          imageOutputCount,
        });

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
    total_tokens: totalTokens,
    image_output_count: imageOutputCount,
    estimated_cost_usd: costUsd,
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
          total_cost_usd: FieldValue.increment(costUsd),
          updated_at: FieldValue.serverTimestamp(),
          [`features.${feature}.input`]: FieldValue.increment(inputTokens),
          [`features.${feature}.output`]: FieldValue.increment(outputTokens),
          [`features.${feature}.thinking`]: FieldValue.increment(thinkingTokens),
          [`features.${feature}.total`]: FieldValue.increment(totalTokens),
          [`features.${feature}.image_outputs`]: FieldValue.increment(imageOutputCount),
          [`features.${feature}.cost_usd`]: FieldValue.increment(costUsd),
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
      {
        period,
        updated_at: FieldValue.serverTimestamp(),
        total_calls: FieldValue.increment(1),
        total_failed_calls: FieldValue.increment(entry.status === "error" ? 1 : 0),
        total_input_tokens: FieldValue.increment(inputTokens),
        total_output_tokens: FieldValue.increment(outputTokens),
        total_thinking_tokens: FieldValue.increment(thinkingTokens),
        total_image_outputs: FieldValue.increment(imageOutputCount),
        total_cost_usd: FieldValue.increment(costUsd),
        [`by_feature.${feature}.calls`]: FieldValue.increment(1),
        [`by_feature.${feature}.input_tokens`]: FieldValue.increment(inputTokens),
        [`by_feature.${feature}.output_tokens`]: FieldValue.increment(outputTokens),
        [`by_feature.${feature}.thinking_tokens`]: FieldValue.increment(thinkingTokens),
        [`by_feature.${feature}.image_outputs`]: FieldValue.increment(imageOutputCount),
        [`by_feature.${feature}.cost_usd`]: FieldValue.increment(costUsd),
        // La ventilation par moteur DANS le poste est ce qui permet de juger
        // une bascule : sans elle, on voit le coût monter sans savoir lequel
        // des deux moteurs le fait monter.
        [`by_feature.${feature}.by_provider.${provider}.calls`]: FieldValue.increment(1),
        [`by_feature.${feature}.by_provider.${provider}.cost_usd`]:
          FieldValue.increment(costUsd),
        [`by_feature.${feature}.by_provider.${provider}.input_tokens`]:
          FieldValue.increment(inputTokens),
        [`by_feature.${feature}.by_provider.${provider}.output_tokens`]:
          FieldValue.increment(outputTokens),
        [`by_feature.${feature}.by_provider.${provider}.thinking_tokens`]:
          FieldValue.increment(thinkingTokens),
        [`by_provider.${provider}.calls`]: FieldValue.increment(1),
        [`by_provider.${provider}.input_tokens`]: FieldValue.increment(inputTokens),
        [`by_provider.${provider}.output_tokens`]: FieldValue.increment(outputTokens),
        [`by_provider.${provider}.thinking_tokens`]: FieldValue.increment(thinkingTokens),
        [`by_provider.${provider}.cost_usd`]: FieldValue.increment(costUsd),
        [`by_model.${model}.calls`]: FieldValue.increment(1),
        [`by_model.${model}.cost_usd`]: FieldValue.increment(costUsd),
        [`by_user.${effectiveUserId}.calls`]: FieldValue.increment(1),
        [`by_user.${effectiveUserId}.cost_usd`]: FieldValue.increment(costUsd),
      },
      { merge: true },
    );

  return { costUsd, totalTokens, period };
}
