/**
 * Routage des appels d'IA entre fournisseurs.
 *
 * Un seul point d'entrée — `callModel` — décide quel moteur sert un poste
 * fonctionnel, enregistre la consommation au tarif du modèle qui a réellement
 * répondu, et se replie sur l'autre moteur si le premier échoue.
 *
 * La politique de routage vit dans Firestore (`app_config/ai_routing_policy`),
 * pas dans le code : basculer un poste d'un moteur à l'autre ne doit pas
 * demander un déploiement, sans quoi personne ne comparera jamais deux moteurs
 * sur des données réelles.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_APP_CONFIG, COLL_AI_USAGE, COLL_TOKEN_USAGE, GEMINI_MODEL } from "../config";
import { logError, logInfo } from "../logging";
import { callGemini, textPart as geminiTextPart } from "../gemini/client";
import { ANTHROPIC_MODEL, anthropicApiKey, callAnthropic } from "./anthropic";
import { estimateAiCostUsd } from "./pricing";
import {
  ModelCallError,
  type AiProvider,
  type ModelCallContext,
  type ModelCallResult,
  type ModelOutputSchema,
  type ModelPart,
} from "./types";

export const AI_ROUTING_POLICY_DOC_ID = "ai_routing_policy";

export interface AiRoutingPolicy {
  /** Fournisseur utilisé pour tout poste non listé dans `features`. */
  defaultProvider: AiProvider;
  /** Fournisseur par poste fonctionnel — la granularité d'une bascule. */
  features: Record<string, AiProvider>;
  /** Modèle Claude à utiliser quand le routage désigne Anthropic. */
  anthropicModel: string;
  /** Repli automatique sur l'autre moteur en cas d'échec technique. */
  fallbackEnabled: boolean;
}

/**
 * Politique par défaut : tout reste sur Gemini.
 *
 * Une migration se prépare, elle ne se décrète pas — le code déployé ne change
 * aucun comportement tant que personne n'a écrit la politique en base.
 */
export const DEFAULT_AI_ROUTING_POLICY: AiRoutingPolicy = {
  defaultProvider: "gemini",
  features: {},
  anthropicModel: ANTHROPIC_MODEL,
  fallbackEnabled: true,
};

function isProvider(value: unknown): value is AiProvider {
  return value === "gemini" || value === "anthropic";
}

let cachedPolicy: { value: AiRoutingPolicy; readAt: number } | null = null;
/** Durée de vie du cache mémoire — une bascule prend effet en moins d'une minute. */
const POLICY_TTL_MS = 60_000;

export async function getAiRoutingPolicy(): Promise<AiRoutingPolicy> {
  if (cachedPolicy && Date.now() - cachedPolicy.readAt < POLICY_TTL_MS) {
    return cachedPolicy.value;
  }

  try {
    const snap = await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(AI_ROUTING_POLICY_DOC_ID)
      .get();

    if (!snap.exists) {
      cachedPolicy = { value: DEFAULT_AI_ROUTING_POLICY, readAt: Date.now() };
      return DEFAULT_AI_ROUTING_POLICY;
    }

    const data = snap.data() as Record<string, unknown>;
    const rawFeatures = (data.features ?? {}) as Record<string, unknown>;
    const features: Record<string, AiProvider> = {};
    for (const [feature, provider] of Object.entries(rawFeatures)) {
      if (isProvider(provider)) features[feature] = provider;
    }

    const policy: AiRoutingPolicy = {
      defaultProvider: isProvider(data.default_provider)
        ? data.default_provider
        : DEFAULT_AI_ROUTING_POLICY.defaultProvider,
      features,
      anthropicModel: typeof data.anthropic_model === "string" && data.anthropic_model.trim()
        ? data.anthropic_model.trim()
        : DEFAULT_AI_ROUTING_POLICY.anthropicModel,
      fallbackEnabled: data.fallback_enabled !== false,
    };

    cachedPolicy = { value: policy, readAt: Date.now() };
    return policy;
  } catch (err) {
    // Une politique illisible ne doit jamais interrompre un traitement : on
    // reste sur le comportement historique, mais l'incident reste visible.
    await logError({
      message: "getAiRoutingPolicy: lecture impossible, politique par défaut appliquée",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_AI_ROUTING_POLICY;
  }
}

/** Fournisseur retenu pour un poste, une fois la disponibilité vérifiée. */
export function resolveProvider(
  policy: AiRoutingPolicy,
  feature: string,
  anthropicAvailable: boolean,
): AiProvider {
  const wanted = policy.features[feature] ?? policy.defaultProvider;
  // Un routage vers un moteur dont la clé n'est pas posée n'est pas une erreur
  // de configuration à faire remonter à l'utilisateur : c'est l'état normal
  // avant l'activation. On sert avec l'autre moteur.
  if (wanted === "anthropic" && !anthropicAvailable) return "gemini";
  return wanted;
}

/**
 * Enregistre la consommation d'un appel, au tarif du modèle qui a répondu.
 *
 * L'ancien `recordTokenUsage` écrivait `GEMINI_MODEL` en dur : un appel Claude
 * y aurait été facturé au tarif Gemini, sans qu'aucun écran ne s'en aperçoive.
 */
export async function recordModelUsage(
  result: ModelCallResult,
  ctx: ModelCallContext,
  meta?: { entityType?: string; entityId?: string; costBucket?: string },
): Promise<void> {
  const { inputTokens, outputTokens, totalTokens } = result.usage;
  if (totalTokens === 0) return;

  const trimmedUserId = (ctx.userId ?? "").trim();
  const effectiveUserId = trimmedUserId.length > 0 ? trimmedUserId : "system_unattributed";
  const db = getFirestore();

  if (trimmedUserId.length > 0) {
    await db.collection(COLL_TOKEN_USAGE).doc(trimmedUserId).set(
      {
        total_tokens: FieldValue.increment(totalTokens),
        updated_at: FieldValue.serverTimestamp(),
        [`features.${ctx.feature}.input`]: FieldValue.increment(inputTokens),
        [`features.${ctx.feature}.output`]: FieldValue.increment(outputTokens),
        [`features.${ctx.feature}.total`]: FieldValue.increment(totalTokens),
        [`features.${ctx.feature}.count`]: FieldValue.increment(1),
      },
      { merge: true },
    );
  }

  await db.collection(COLL_AI_USAGE).add({
    uid: effectiveUserId,
    feature: ctx.feature,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    total_tokens: totalTokens,
    model: result.model,
    provider: result.provider,
    estimated_cost_usd: estimateAiCostUsd({
      model: result.model,
      inputTokens,
      outputTokens,
      imageOutputCount: result.usage.imageOutputCount ?? 0,
    }),
    cost_bucket: meta?.costBucket ?? "production",
    correlation_id: ctx.correlationId,
    entity_type: meta?.entityType ?? null,
    entity_id: meta?.entityId ?? null,
    timestamp: FieldValue.serverTimestamp(),
  });
}

async function callProvider(args: {
  provider: AiProvider;
  parts: ModelPart[];
  ctx: ModelCallContext;
  policy: AiRoutingPolicy;
  geminiApiKey: string;
  outputSchema?: ModelOutputSchema;
  maxTokens?: number;
}): Promise<ModelCallResult> {
  if (args.provider === "anthropic") {
    const key = anthropicApiKey();
    if (!key) {
      throw new ModelCallError("Clé Anthropic absente de l'environnement", "anthropic", false);
    }
    return callAnthropic({
      apiKey: key,
      parts: args.parts,
      ctx: args.ctx,
      model: args.policy.anthropicModel,
      maxTokens: args.maxTokens,
      outputSchema: args.outputSchema,
    });
  }

  // Gemini ne reçoit que du texte par ce chemin : les postes qui envoient des
  // images (extraction de scans) appellent encore `callGemini` directement et
  // migreront quand leur tour viendra.
  const geminiParts = args.parts.map((part) =>
    part.kind === "text"
      ? geminiTextPart(part.text)
      : { inlineData: { mimeType: part.mimeType, data: part.dataBase64 } },
  );

  const result = await callGemini(args.geminiApiKey, geminiParts, {
    correlationId: args.ctx.correlationId,
    feature: args.ctx.feature,
    moduleType: args.ctx.moduleType,
    userId: args.ctx.userId,
    timeoutMs: args.ctx.timeoutMs,
  });

  const input = result.usageMetadata?.promptTokenCount ?? 0;
  const output = result.usageMetadata?.candidatesTokenCount ?? 0;
  return {
    text: (result.text ?? "").trim(),
    provider: "gemini",
    model: GEMINI_MODEL,
    usage: {
      inputTokens: input,
      outputTokens: output,
      totalTokens: result.usageMetadata?.totalTokenCount ?? input + output,
    },
    stopReason: result.candidates[0]?.finishReason,
  };
}

/**
 * Appelle le modèle désigné par la politique pour ce poste, avec repli.
 *
 * Le repli n'est pas une politesse : sans lui, activer Claude sur un poste
 * transformerait le moindre incident fournisseur en perte de fonctionnalité
 * pour l'utilisateur. Il ne se déclenche que sur un échec technique — une
 * réponse déclinée par les classificateurs n'est pas retentée ailleurs.
 */
export async function callModel(args: {
  parts: ModelPart[];
  ctx: ModelCallContext;
  geminiApiKey: string;
  outputSchema?: ModelOutputSchema;
  maxTokens?: number;
  /** Comptabilise la consommation (défaut : true). */
  recordUsage?: boolean;
  usageMeta?: { entityType?: string; entityId?: string; costBucket?: string };
}): Promise<ModelCallResult> {
  const policy = await getAiRoutingPolicy();
  const primary = resolveProvider(policy, args.ctx.feature, anthropicApiKey() != null);

  const run = async (provider: AiProvider): Promise<ModelCallResult> => {
    const result = await callProvider({
      provider,
      parts: args.parts,
      ctx: args.ctx,
      policy,
      geminiApiKey: args.geminiApiKey,
      outputSchema: args.outputSchema,
      maxTokens: args.maxTokens,
    });
    if (args.recordUsage !== false) {
      await recordModelUsage(result, args.ctx, args.usageMeta);
    }
    return result;
  };

  try {
    return await run(primary);
  } catch (err) {
    const secondary: AiProvider = primary === "anthropic" ? "gemini" : "anthropic";
    const canFallback =
      policy.fallbackEnabled &&
      (!(err instanceof ModelCallError) || err.retryable) &&
      (secondary === "gemini" || anthropicApiKey() != null);

    if (!canFallback) throw err;

    await logError({
      message: `callModel: ${primary} a échoué sur « ${args.ctx.feature} », repli sur ${secondary}`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.ctx.correlationId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
    });

    const result = await run(secondary);
    void logInfo({
      message: `callModel: repli réussi sur ${secondary} pour « ${args.ctx.feature} »`,
      correlationId: args.ctx.correlationId,
      extra: { model: result.model },
    });
    return result;
  }
}
