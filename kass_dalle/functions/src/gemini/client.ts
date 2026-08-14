/**
 * Wrapper autour du SDK Gemini.
 *
 * Gère :
 *  - Instanciation du modèle (clé depuis Secret Manager au runtime)
 *  - Appels avec retry automatique sur QUOTA_EXCEEDED (jusqu'à la function timeout)
 *  - Logging structuré de chaque appel (durée, tokens, statut Gemini)
 *  - Conversion erreurs Gemini → GeminiStatus + remontée vers le pipeline
 *
 * **Ce fichier est le SEUL à importer le SDK.** Le reste du backend manipule
 * [GeminiResponse], une forme normalisée maison. Auparavant le type de réponse
 * du SDK fuitait dans 13 fichiers (27 accès à `result.response.*`), ce qui
 * rendait tout changement de SDK disproportionné. Pour changer de SDK, il ne
 * faut désormais toucher qu'ici.
 */

import {
  GoogleGenerativeAI,
  type GenerativeModel,
  type Part,
  type GenerateContentResult,
} from "@google/generative-ai";
import { GEMINI_MODEL } from "../config";
import { logDebug, logInfo, logError, type GeminiStatus, type ModuleType } from "../logging";

// ── Forme normalisée d'une réponse Gemini ────────────────────────────────────

export interface GeminiUsage {
  promptTokenCount?: number;
  /** Jetons du texte rendu — **hors** raisonnement. */
  candidatesTokenCount?: number;
  /**
   * Jetons de raisonnement, facturés au tarif de sortie.
   *
   * Gemini 2.5 Flash raisonne par défaut. Ces jetons n'apparaissent ni dans la
   * réponse ni dans `candidatesTokenCount`, mais Google les facture comme de
   * la sortie — au même prix, soit huit fois l'entrée. Les ignorer ne casse
   * aucun écran : cela divise simplement le coût affiché par le facteur qui
   * sépare le raisonnement du texte produit.
   */
  thoughtsTokenCount?: number;
  /** Total rendu par l'API : entrée + sortie + raisonnement. */
  totalTokenCount?: number;
}

/**
 * Jetons de raisonnement d'un appel.
 *
 * Le champ dédié fait foi quand il est présent. À défaut, le total les trahit :
 * ce que le total compte en plus de l'entrée et de la sortie ne peut être que
 * du raisonnement. Ce repli couvre les versions du SDK qui ne remontent pas
 * encore le champ — sans lui, une montée de version silencieuse ferait
 * réapparaître le sous-comptage.
 */
export function thinkingTokensOf(usage: GeminiUsage | undefined): number {
  if (!usage) return 0;
  const declared = usage.thoughtsTokenCount ?? 0;
  const derived =
    (usage.totalTokenCount ?? 0) -
    (usage.promptTokenCount ?? 0) -
    (usage.candidatesTokenCount ?? 0);
  return Math.max(0, declared, derived);
}

export interface GeminiInlineData {
  mimeType?: string;
  data?: string;
}

export interface GeminiResponsePart {
  text?: string;
  inlineData?: GeminiInlineData;
}

export interface GeminiCandidate {
  content?: { parts?: GeminiResponsePart[] };
  finishReason?: string;
}

/** Réponse Gemini telle que la voit le reste du backend, SDK-agnostique. */
export interface GeminiResponse {
  /** Texte concaténé du premier candidat. Chaîne vide si la réponse n'en a pas. */
  text: string;
  candidates: GeminiCandidate[];
  usageMetadata?: GeminiUsage;
}

/**
 * Convertit une réponse du SDK vers [GeminiResponse].
 *
 * Le texte est reconstruit depuis les parts plutôt que via l'accesseur
 * `response.text()` du SDK, qui lève une exception quand la réponse a été
 * bloquée par les filtres de sécurité. Ici une réponse bloquée donne une chaîne
 * vide et `finishReason` reste lisible dans [GeminiResponse.candidates] :
 * l'appelant décide quoi en faire au lieu de subir un throw.
 */
export function toGeminiResponse(result: GenerateContentResult): GeminiResponse {
  const candidates = (result.response.candidates ?? []) as GeminiCandidate[];
  const parts = candidates[0]?.content?.parts ?? [];
  const text = parts.map((part) => (typeof part.text === "string" ? part.text : "")).join("");
  return {
    text,
    candidates,
    usageMetadata: result.response.usageMetadata as GeminiUsage | undefined,
  };
}

/**
 * Instancie un modèle génératif pour un modèle autre que [GEMINI_MODEL]
 * (génération et retouche d'images). Passe par ici pour que l'import du SDK
 * reste confiné à ce fichier.
 */
export function createGenerativeModel(apiKey: string, model: string): GenerativeModel {
  return new GoogleGenerativeAI(apiKey).getGenerativeModel({ model });
}

export class GeminiQuotaExceededError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GeminiQuotaExceededError";
  }
}

export class GeminiError extends Error {
  constructor(
    message: string,
    public readonly cause?: unknown,
  ) {
    super(message);
    this.name = "GeminiError";
  }
}

export interface GeminiCallContext {
  correlationId: string;
  feature: string;
  moduleType?: ModuleType;
  jobId?: string;
  userId?: string;
  stepIndex?: number;
  /** Timeout du call individuel en ms (par défaut 5 minutes). */
  timeoutMs?: number;
  /** Si true, l'appelant veut absorber les erreurs sans les remonter (renvoie null). */
  silentOnError?: boolean;
  /**
   * Plafond de jetons de raisonnement, `0` pour le désactiver.
   *
   * Absent, le modèle décide — c'est le comportement historique, et celui qui
   * fait la majeure partie de la facture de sortie.
   */
  thinkingBudget?: number | null;
}

/**
 * Vrai quand l'API a refusé le plafond de raisonnement lui-même.
 *
 * Un modèle qui ne gère pas ce réglage répond 400 en nommant le champ. Le
 * distinguer d'une vraie erreur évite de retenter sans fin un appel qui
 * échouerait de toute façon.
 */
function isThinkingRejection(err: unknown): boolean {
  const message = errorMessage(err).toLowerCase();
  return message.includes("thinking") || message.includes("thinkingconfig");
}

let cachedModel: GenerativeModel | null = null;
let cachedApiKey: string | null = null;

function getModel(apiKey: string): GenerativeModel {
  if (cachedModel && cachedApiKey === apiKey) return cachedModel;
  const genAi = new GoogleGenerativeAI(apiKey);
  cachedModel = genAi.getGenerativeModel({ model: GEMINI_MODEL });
  cachedApiKey = apiKey;
  return cachedModel;
}

/**
 * Appelle Gemini avec retry automatique sur quota dépassé.
 *
 * Stratégie : si on reçoit un 429 / QUOTA_EXCEEDED, on attend (backoff exponentiel
 * plafonné à 60s) et on retente. Le retry s'arrête quand la function approche
 * de son timeout (Cloud Tasks reprendra la main pour un nouveau retry).
 */
export async function callGemini(
  apiKey: string,
  parts: Part[],
  ctx: GeminiCallContext,
): Promise<GeminiResponse> {
  const model = getModel(apiKey);
  const timeoutMs = ctx.timeoutMs ?? 5 * 60 * 1000;
  const deadline = Date.now() + timeoutMs;
  let attempt = 0;
  // Le plafond de raisonnement est abandonné dès que l'API le refuse : mieux
  // vaut une facture de sortie plus lourde qu'un poste qui ne répond plus.
  let thinkingBudget = ctx.thinkingBudget ?? null;

  while (true) {
    attempt++;
    const startedAt = Date.now();

    // Extrait le texte des parts pour traçabilité (les parts image ne sont pas loggées)
    const promptText = parts
      .map((p) =>
        "text" in p && typeof (p as unknown as Record<string, unknown>).text === "string"
          ? ((p as unknown as Record<string, unknown>).text as string)
          : "[part non-texte]",
      )
      .join("\n---\n");

    // L'ouverture d'un appel n'apprend rien que sa clôture ne dise, durée
    // comprise. En INFO, elle doublait le volume de l'écran pour rien.
    await logDebug(`Appel IA démarré (${ctx.feature})`, {
      correlationId: ctx.correlationId,
      moduleType: ctx.moduleType,
      jobId: ctx.jobId,
      userId: ctx.userId,
      stepIndex: ctx.stepIndex,
      provider: "gemini",
      model: GEMINI_MODEL,
      feature: ctx.feature,
      extra: { attempt, prompt: promptText },
    });

    try {
      // `thinkingConfig` n'est pas typé par cette version du SDK, qui transmet
      // néanmoins `generationConfig` tel quel à l'API. Le cast est le prix de
      // l'accès à un réglage qui pèse près de neuf dixièmes de la facture de
      // sortie ; le repli ci-dessous couvre le cas où l'API le refuserait.
      const request = {
        contents: [{ role: "user", parts }],
        ...(thinkingBudget != null
          ? { generationConfig: { thinkingConfig: { thinkingBudget } } }
          : {}),
      } as Parameters<GenerativeModel["generateContent"]>[0];

      const sdkResult = await withTimeout(
        model.generateContent(request),
        Math.min(timeoutMs, deadline - Date.now()),
      );
      const result = toGeminiResponse(sdkResult);

      const usage = result.usageMetadata;
      const elapsed = Date.now() - startedAt;
      await logInfo(`Appel IA terminé (${ctx.feature})`, {
        correlationId: ctx.correlationId,
        moduleType: ctx.moduleType,
        jobId: ctx.jobId,
        userId: ctx.userId,
        stepIndex: ctx.stepIndex,
        executionTimeMs: elapsed,
        geminiStatus: "SUCCESS",
        provider: "gemini",
        model: GEMINI_MODEL,
        feature: ctx.feature,
        extra: {
          inputTokens: usage?.promptTokenCount,
          outputTokens: usage?.candidatesTokenCount,
          thinkingTokens: thinkingTokensOf(usage),
          totalTokens: usage?.totalTokenCount,
          attempt,
        },
      });
      return result;
    } catch (err) {
      const status: GeminiStatus = classifyError(err);
      const elapsed = Date.now() - startedAt;

      // Un plafond de raisonnement refusé par l'API ne doit pas coûter le
      // poste : on retente sans lui, une seule fois, et l'incident reste
      // visible plutôt que d'être absorbé.
      if (thinkingBudget != null && isThinkingRejection(err)) {
        await logError(`Appel IA — plafond de raisonnement refusé, nouvel essai sans lui`, {
          correlationId: ctx.correlationId,
          moduleType: ctx.moduleType,
          userId: ctx.userId,
          provider: "gemini",
          model: GEMINI_MODEL,
          feature: ctx.feature,
          errorDescription: errorMessage(err),
          extra: { attempt, thinkingBudget },
        });
        thinkingBudget = null;
        continue;
      }

      if (status === "QUOTA_EXCEEDED" && Date.now() < deadline - 5000) {
        const backoffMs = Math.min(60_000, 2_000 * Math.pow(2, attempt - 1));
        await logError(`Appel IA — quota dépassé, nouvelle tentative dans ${backoffMs} ms`, {
          correlationId: ctx.correlationId,
          moduleType: ctx.moduleType,
          jobId: ctx.jobId,
          userId: ctx.userId,
          stepIndex: ctx.stepIndex,
          executionTimeMs: elapsed,
          geminiStatus: status,
          provider: "gemini",
          model: GEMINI_MODEL,
          feature: ctx.feature,
          errorDescription: errorMessage(err),
          extra: { attempt, backoffMs },
        });
        await sleep(backoffMs);
        continue;
      }

      await logError(`Appel IA échoué (${ctx.feature})`, {
        correlationId: ctx.correlationId,
        moduleType: ctx.moduleType,
        jobId: ctx.jobId,
        userId: ctx.userId,
        stepIndex: ctx.stepIndex,
        executionTimeMs: elapsed,
        geminiStatus: status,
        provider: "gemini",
        model: GEMINI_MODEL,
        feature: ctx.feature,
        errorDescription: errorMessage(err),
        extra: { attempt },
      });

      if (status === "QUOTA_EXCEEDED") {
        throw new GeminiQuotaExceededError(errorMessage(err));
      }
      throw new GeminiError(errorMessage(err), err);
    }
  }
}

function classifyError(err: unknown): GeminiStatus {
  const msg = errorMessage(err).toLowerCase();
  if (msg.includes("429") || msg.includes("quota") || msg.includes("resource_exhausted")) {
    return "QUOTA_EXCEEDED";
  }
  return "ERROR";
}

export function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Gemini call timeout after ${ms}ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** Crée un Part de type "inline data" pour transmettre un fichier (image/PDF) à Gemini. */
export function dataPart(mimeType: string, bytes: Buffer): Part {
  return {
    inlineData: {
      mimeType,
      data: bytes.toString("base64"),
    },
  };
}

/** Crée un Part de type texte. */
export function textPart(text: string): Part {
  return { text };
}

/**
 * Extrait un objet JSON depuis une réponse Gemini, en supprimant les fences
 * markdown éventuels (\`\`\`json … \`\`\`).
 */
export function extractJsonObject(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  return match ? match[0] : cleaned;
}

/** Variante pour les réponses qui doivent être un tableau JSON. */
export function extractJsonArray(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\[[\s\S]*\]/);
  return match ? match[0] : cleaned;
}
