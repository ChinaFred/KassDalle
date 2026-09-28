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

import { getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG, GEMINI_API_KEY, GEMINI_MODEL } from "../config";
import { logDebug, logError, logInfo, logWarn, newCallId } from "../logging";
import { callGemini, textPart as geminiTextPart, thinkingTokensOf } from "../gemini/client";
import {
  ANTHROPIC_MODEL,
  anthropicApiKey,
  anthropicSupportsParts,
  callAnthropic,
} from "./anthropic";
import { recordUsage } from "./usage";
import { assertWithinDailyBudget } from "./budget";
// `recordUsage` est aussi le nom d'un drapeau de `callModel` : l'import garde
// le nom de la fonction, l'option se lit toujours `args.recordUsage`.
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
  /** Modèle Claude par défaut quand le routage désigne Anthropic. */
  anthropicModel: string;
  /**
   * Modèle Claude PAR POSTE — l'emporte sur le défaut.
   *
   * Le fournisseur se choisissait poste par poste, le modèle non : basculer un
   * poste sur Claude imposait le même modèle à tous les autres. C'était le
   * mauvais grain, parce que les postes n'ont pas les mêmes exigences.
   *
   * Transcrire une page de livre demande de la précision et se paie cher à la
   * page ; estimer les calories d'une carotte est un rappel de connaissances,
   * répété quinze fois par recette. Un seul modèle pour les deux, c'est soit
   * payer Opus pour la carotte, soit lire le livre avec Haiku.
   */
  anthropicModels: Record<string, string>;
  /**
   * Effort de réflexion Claude PAR POSTE — l'emporte sur le réglage que le
   * code du poste pose lui-même (`ModelCallContext.effort`).
   *
   * Le modèle se choisissait déjà poste par poste ; l'effort restait une
   * constante de code (`TAGGING_EFFORT`, l'« high » de `transcription.ts`),
   * qui ne se changeait qu'en redéployant. Une mesure du 27 septembre 2026 a
   * montré que, pour la lecture de page, le levier qui économise vraiment est
   * le modèle — et que l'effort, lui, mérite d'être ajusté sans attendre un
   * déploiement, comme le modèle.
   *
   * Absent d'un poste, ce poste garde l'effort que son propre code demande :
   * ce champ ne fixe pas de défaut global, parce qu'aucun effort commun n'a de
   * sens — la nutrition veut `low`, la lecture de page veut `high`.
   */
  anthropicEfforts: Record<string, "low" | "medium" | "high">;
  /** Repli automatique sur l'autre moteur en cas d'échec technique. */
  fallbackEnabled: boolean;
  /**
   * Plafond de jetons de raisonnement pour Gemini, `null` pour laisser le
   * modèle décider.
   *
   * Le raisonnement est facturé au tarif de sortie. Sur un mois observé, il
   * représentait 2,1 millions de jetons sur les 2,4 millions de sortie
   * facturés — soit près de neuf dixièmes de la ligne la plus chère de la
   * facture Gemini. Beaucoup de postes n'en ont aucun besoin : classer une
   * page, deviner les dimensions d'une grille ou proposer des tags ne demande
   * pas de délibération.
   *
   * `0` le désactive. `null` (défaut) conserve le comportement du modèle :
   * ne rien changer sans décision explicite.
   */
  thinkingBudget: number | null;
  /** Plafond par poste — l'emporte sur le plafond global. */
  thinkingBudgets: Record<string, number>;
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
  anthropicModels: {},
  anthropicEfforts: {},
  fallbackEnabled: true,
  thinkingBudget: null,
  thinkingBudgets: {},
};

function isProvider(value: unknown): value is AiProvider {
  return value === "gemini" || value === "anthropic";
}

/** Un plafond de raisonnement lisible : entier positif ou zéro, sinon rien. */
function readBudget(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? Math.trunc(n) : null;
}

/**
 * Plafond applicable à un poste : le sien, à défaut le global.
 *
 * Exporté pour être testable seul — c'est un arbitrage qui coûte de l'argent
 * dans les deux sens : trop bas, le modèle répond moins bien ; absent, la
 * facture de sortie se multiplie.
 */
export function resolveThinkingBudget(policy: AiRoutingPolicy, feature: string): number | null {
  const perFeature = policy.thinkingBudgets[feature];
  if (perFeature != null) return readBudget(perFeature);
  return policy.thinkingBudget;
}

/**
 * Modèle Claude d'un poste : le sien s'il en a un, le défaut sinon.
 *
 * Exporté pour être testable seul. Ce choix décide à la fois de la qualité et
 * du prix — et le mauvais dans un sens ne se voit pas plus que dans l'autre :
 * un modèle trop petit rend une page abîmée qui a l'air correcte, un modèle
 * trop grand rend une facture qui a l'air normale.
 */
export function resolveAnthropicModel(policy: AiRoutingPolicy, feature: string): string {
  const perFeature = policy.anthropicModels[feature];
  return typeof perFeature === "string" && perFeature.trim()
    ? perFeature.trim()
    : policy.anthropicModel;
}

function isEffort(value: unknown): value is "low" | "medium" | "high" {
  return value === "low" || value === "medium" || value === "high";
}

/**
 * Effort de réflexion imposé à un poste par la politique, ou `null` en
 * l'absence de réglage.
 *
 * `null` n'est pas un défaut à appliquer : c'est le signal que le poste garde
 * l'effort qu'il pose lui-même dans son propre code. Contrairement au modèle
 * (`resolveAnthropicModel`), il n'existe pas de repli global sensé — aucun
 * effort commun ne convient à la fois à la lecture d'une page et à un rappel
 * de calories.
 */
export function resolveAnthropicEffort(
  policy: AiRoutingPolicy,
  feature: string,
): "low" | "medium" | "high" | null {
  const perFeature = policy.anthropicEfforts[feature];
  return isEffort(perFeature) ? perFeature : null;
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

    const rawModels = (data.anthropic_models ?? {}) as Record<string, unknown>;
    const anthropicModels: Record<string, string> = {};
    for (const [feature, model] of Object.entries(rawModels)) {
      if (typeof model === "string" && model.trim()) anthropicModels[feature] = model.trim();
    }

    const rawBudgets = (data.thinking_budgets ?? {}) as Record<string, unknown>;
    const thinkingBudgets: Record<string, number> = {};
    for (const [feature, budget] of Object.entries(rawBudgets)) {
      const value = readBudget(budget);
      if (value != null) thinkingBudgets[feature] = value;
    }

    const rawEfforts = (data.anthropic_efforts ?? {}) as Record<string, unknown>;
    const anthropicEfforts: Record<string, "low" | "medium" | "high"> = {};
    for (const [feature, effort] of Object.entries(rawEfforts)) {
      if (isEffort(effort)) anthropicEfforts[feature] = effort;
    }

    const policy: AiRoutingPolicy = {
      defaultProvider: isProvider(data.default_provider)
        ? data.default_provider
        : DEFAULT_AI_ROUTING_POLICY.defaultProvider,
      features,
      anthropicModel:
        typeof data.anthropic_model === "string" && data.anthropic_model.trim()
          ? data.anthropic_model.trim()
          : DEFAULT_AI_ROUTING_POLICY.anthropicModel,
      anthropicModels,
      anthropicEfforts,
      fallbackEnabled: data.fallback_enabled !== false,
      thinkingBudget: readBudget(data.thinking_budget),
      thinkingBudgets,
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
  // Cloud Vision ne sert qu'un poste, la modération, dont l'exécution ne passe
  // pas par `callModel`. L'y laisser passer ferait appeler un client de texte
  // avec un fournisseur qui n'en est pas un.
  if (wanted === "vision") return "gemini";
  return wanted;
}

/**
 * Enregistre la consommation d'un appel, au tarif du modèle qui a répondu.
 *
 * L'ancien `recordTokenUsage` écrivait `GEMINI_MODEL` en dur : un appel Claude
 * y aurait été facturé au tarif Gemini, sans qu'aucun écran ne s'en aperçoive.
 * L'écriture elle-même vit maintenant dans `ai/usage.ts`, partagée par tous les
 * types d'appel — texte, image, et postes internes.
 */
export async function recordModelUsage(
  result: ModelCallResult,
  ctx: ModelCallContext,
  meta?: { entityType?: string; entityId?: string; costBucket?: string },
): Promise<void> {
  // Un appel sans jetons connus est enregistré quand même. Le court-circuit
  // qui existait ici (`if (totalTokens === 0) return;`) faisait disparaître du
  // reporting des appels réellement facturés par le fournisseur : ils
  // ressortaient plus tard en « non attribué », sans origine identifiable.
  await recordUsage({
    feature: ctx.feature,
    provider: result.provider,
    model: result.model,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
    inputTokens: result.usage.inputTokens,
    outputTokens: result.usage.outputTokens,
    thinkingTokens: result.usage.thinkingTokens ?? 0,
    cacheCreationInputTokens: result.usage.cacheCreationInputTokens ?? 0,
    cacheReadInputTokens: result.usage.cacheReadInputTokens ?? 0,
    imageOutputCount: result.usage.imageOutputCount ?? 0,
    entityType: meta?.entityType,
    entityId: meta?.entityId,
    costBucket: meta?.costBucket,
  });
}

/**
 * Clé Gemini, résolue par le routeur lui-même.
 *
 * Elle traversait auparavant toutes les signatures sous le nom `geminiApiKey`,
 * de l'entrée HTTPS jusqu'aux fonctions d'enrichissement. Depuis la bascule
 * multi-fournisseur, ce nom mentait : il était transporté jusqu'à des fonctions
 * dont le poste peut être servi par Claude, et laissait croire que la chaîne
 * était forcément Gemini.
 *
 * Le routeur est le seul endroit qui sait quel moteur répond ; c'est donc à lui
 * de lire la clé, exactement comme il le fait déjà pour Anthropic. Toute
 * fonction déclarant `secrets: [GEMINI_API_KEY]` peut appeler `.value()`.
 */
function geminiKey(): string {
  return GEMINI_API_KEY.value();
}

async function callProvider(args: {
  provider: AiProvider;
  parts: ModelPart[];
  ctx: ModelCallContext;
  /** Identifiant de cet appel — il relie ses lignes de journal à sa consommation. */
  callId: string;
  policy: AiRoutingPolicy;
  outputSchema?: ModelOutputSchema;
  maxTokens?: number;
}): Promise<ModelCallResult> {
  if (args.provider === "anthropic") {
    const key = anthropicApiKey();
    if (!key) {
      throw new ModelCallError("Clé Anthropic absente de l'environnement", "anthropic", false);
    }
    // Un effort réglé depuis Admin l'emporte sur celui du code ; en son
    // absence, le poste garde l'effort qu'il pose lui-même.
    const effortOverride = resolveAnthropicEffort(args.policy, args.ctx.feature);
    return callAnthropic({
      apiKey: key,
      parts: args.parts,
      ctx: effortOverride ? { ...args.ctx, effort: effortOverride } : args.ctx,
      callId: args.callId,
      model: resolveAnthropicModel(args.policy, args.ctx.feature),
      maxTokens: args.maxTokens,
      outputSchema: args.outputSchema,
    });
  }

  // Texte, images et documents passent tous par ce chemin : Gemini les accepte
  // indifféremment en `inlineData`. Seuls les postes qui produisent une image
  // (génération, retouche) restent hors routage — Claude n'en fabrique pas.
  const geminiParts = args.parts.map((part) =>
    part.kind === "text"
      ? geminiTextPart(part.text)
      : { inlineData: { mimeType: part.mimeType, data: part.dataBase64 } },
  );

  const result = await callGemini(geminiKey(), geminiParts, {
    correlationId: args.ctx.correlationId,
    scanId: args.ctx.scanId,
    callId: args.callId,
    feature: args.ctx.feature,
    moduleType: args.ctx.moduleType,
    userId: args.ctx.userId,
    jobId: args.ctx.jobId,
    stepIndex: args.ctx.stepIndex,
    timeoutMs: args.ctx.timeoutMs,
    thinkingBudget: resolveThinkingBudget(args.policy, args.ctx.feature),
  });

  const input = result.usageMetadata?.promptTokenCount ?? 0;
  const output = result.usageMetadata?.candidatesTokenCount ?? 0;
  const thinking = thinkingTokensOf(result.usageMetadata);
  return {
    text: (result.text ?? "").trim(),
    provider: "gemini",
    model: GEMINI_MODEL,
    callId: args.callId,
    usage: {
      inputTokens: input,
      outputTokens: output,
      thinkingTokens: thinking,
      totalTokens: result.usageMetadata?.totalTokenCount ?? input + output + thinking,
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
  outputSchema?: ModelOutputSchema;
  maxTokens?: number;
  /** Comptabilise la consommation (défaut : true). */
  recordUsage?: boolean;
  usageMeta?: { entityType?: string; entityId?: string; costBucket?: string };
}): Promise<ModelCallResult> {
  // Le plafond se vérifie ici, avant le moindre appel de fournisseur : c'est le
  // point de passage unique de tout ce qui coûte en texte, qu'il vienne d'une
  // callable ou du pipeline asynchrone. Placé dans les gardes HTTPS, il aurait
  // laissé passer tout ce que Cloud Tasks déclenche.
  await assertWithinDailyBudget(args.ctx.userId, args.ctx.feature);

  const policy = await getAiRoutingPolicy();
  const anthropicAvailable = anthropicApiKey() != null;
  let primary = resolveProvider(policy, args.ctx.feature, anthropicAvailable);

  // Une bascule sans effet doit se voir.
  //
  // Ce repli est volontairement silencieux dans `resolveProvider` : entre le
  // déploiement du code et la création du secret, servir Gemini est le
  // comportement attendu, pas un incident. Mais le même silence a masqué des
  // mois durant une fonction qui avait simplement oublié de déclarer le secret
  // — la politique était lue, appliquée, puis annulée à l'exécution, et
  // l'écran d'administration affirmait que la clé était présente parce qu'une
  // AUTRE fonction, elle, la déclarait. Un WARNING coûte une ligne de log et
  // rend la panne lisible en une requête.
  const wanted = policy.features[args.ctx.feature] ?? policy.defaultProvider;
  if (wanted === "anthropic" && !anthropicAvailable) {
    void logWarn({
      message: `callModel: « ${args.ctx.feature} » est routé vers Claude, mais la clé Anthropic n'est pas disponible dans cette fonction — servi par Gemini`,
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      feature: args.ctx.feature,
      provider: "gemini",
    });
  }

  // Un fichier que Claude ne sait pas lire (DOCX, HEIC…) part directement chez
  // Gemini. Le repli aurait produit le même résultat, au prix d'un appel perdu
  // et d'une erreur dans les logs qui ressemble à une panne alors que c'est un
  // choix de format.
  if (primary === "anthropic" && !anthropicSupportsParts(args.parts)) {
    void logDebug({
      message: `callModel: pièce jointe non lisible par Claude, « ${args.ctx.feature} » servi par Gemini`,
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      feature: args.ctx.feature,
      extra: {
        mimeTypes: args.parts
          .filter((part) => part.kind !== "text")
          .map((part) => (part as { mimeType: string }).mimeType),
      },
    });
    primary = "gemini";
  }

  const run = async (provider: AiProvider): Promise<ModelCallResult> => {
    // Un identifiant par TENTATIVE, et non par appel logique : un repli sur
    // l'autre moteur produit deux appels réellement facturés, deux lignes de
    // consommation et deux séries de lignes de journal. Leur donner le même
    // identifiant afficherait un seul appel dont le coût aurait doublé sans
    // raison lisible.
    const callId = newCallId();
    try {
      const result = await callProvider({
        provider,
        parts: args.parts,
        ctx: args.ctx,
        callId,
        policy,
        outputSchema: args.outputSchema,
        maxTokens: args.maxTokens,
      });
      if (args.recordUsage !== false) {
        await recordModelUsage(result, args.ctx, args.usageMeta);
      }
      return result;
    } catch (err) {
      // Un appel qui échoue après avoir atteint le fournisseur est facturé
      // quand même — un dépassement de délai côté client n'arrête pas le
      // calcul côté serveur. Ne rien écrire dans ce cas fait disparaître du
      // suivi une dépense bien réelle, et le repli sur l'autre moteur en
      // ajoute une seconde par-dessus. La ligne est enregistrée sans jetons :
      // le fournisseur ne les rend pas sur un échec, mais l'appel cesse d'être
      // invisible.
      if (args.recordUsage !== false) {
        await recordUsage({
          feature: args.ctx.feature,
          provider,
          model:
            provider === "anthropic"
              ? resolveAnthropicModel(policy, args.ctx.feature)
              : GEMINI_MODEL,
          userId: args.ctx.userId,
          correlationId: args.ctx.correlationId,
          scanId: args.ctx.scanId,
          callId,
          status: "error",
          entityType: args.usageMeta?.entityType,
          entityId: args.usageMeta?.entityId,
          costBucket: args.usageMeta?.costBucket,
        });
      }
      throw err;
    }
  };

  try {
    return await run(primary);
  } catch (err) {
    const secondary: AiProvider = primary === "anthropic" ? "gemini" : "anthropic";
    const canFallback =
      policy.fallbackEnabled &&
      (!(err instanceof ModelCallError) || err.retryable) &&
      (secondary === "gemini" || (anthropicApiKey() != null && anthropicSupportsParts(args.parts)));

    if (!canFallback) throw err;

    await logError({
      message: `callModel: ${primary} a échoué sur « ${args.ctx.feature} », repli sur ${secondary}`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      provider: primary,
      feature: args.ctx.feature,
      extra: { fallbackTo: secondary },
    });

    const result = await run(secondary);
    void logInfo({
      message: `callModel: repli réussi sur ${secondary} pour « ${args.ctx.feature} »`,
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      callId: result.callId,
      provider: result.provider,
      model: result.model,
      feature: args.ctx.feature,
      extra: { fallbackFrom: primary },
    });
    return result;
  }
}
