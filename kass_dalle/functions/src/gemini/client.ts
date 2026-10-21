/**
 * Wrapper autour du SDK Gemini (`@google/genai`).
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

// Types seuls : effacés à la compilation, ils ne chargent pas le SDK. Le code
// du SDK n'est chargé qu'au premier appel, par `loadSdk()`.
import type {
  Content,
  GenerateContentConfig,
  GenerateContentResponse,
  GoogleGenAI,
  Part,
} from "@google/genai";
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
  /**
   * Jetons du résultat d'un outil (recherche Google) relus par le modèle,
   * facturés au tarif d'entrée. Absent tant qu'aucun appel ne passe d'outil.
   */
  toolUsePromptTokenCount?: number;
  /** Total rendu par l'API : entrée + sortie + raisonnement + outil. */
  totalTokenCount?: number;
}

/**
 * Jetons de raisonnement d'un appel.
 *
 * Le champ dédié fait foi quand il est présent. À défaut, le total les trahit :
 * ce que le total compte en plus de l'entrée, de la sortie et du résultat
 * d'outil ne peut être que du raisonnement. Ce repli couvre les versions du SDK qui ne remontent pas
 * encore le champ — sans lui, une montée de version silencieuse ferait
 * réapparaître le sous-comptage.
 */
export function thinkingTokensOf(usage: GeminiUsage | undefined): number {
  if (!usage) return 0;
  const declared = usage.thoughtsTokenCount ?? 0;
  const derived =
    (usage.totalTokenCount ?? 0) -
    (usage.promptTokenCount ?? 0) -
    (usage.candidatesTokenCount ?? 0) -
    (usage.toolUsePromptTokenCount ?? 0);
  return Math.max(0, declared, derived);
}

/**
 * Jetons d'entrée facturés d'un appel : le prompt, plus le résultat d'outil.
 *
 * Google facture le résultat de la recherche relu par le modèle
 * (`toolUsePromptTokenCount`) au tarif d'entrée. [thinkingTokensOf] le retire
 * déjà du raisonnement ; sans cette somme, il ne serait compté nulle part.
 */
export function inputTokensOf(usage: GeminiUsage | undefined): number {
  if (!usage) return 0;
  return (usage.promptTokenCount ?? 0) + (usage.toolUsePromptTokenCount ?? 0);
}

export interface GeminiInlineData {
  mimeType?: string;
  data?: string;
}

export interface GeminiResponsePart {
  text?: string;
  inlineData?: GeminiInlineData;
}

/** Sous-ensemble lu de `groundingMetadata` (recherche Google). */
export interface GeminiGroundingMetadata {
  groundingChunks?: { web?: { uri?: string; title?: string } }[];
  searchEntryPoint?: { renderedContent?: string };
  webSearchQueries?: string[];
}

export interface GeminiCandidate {
  content?: { parts?: GeminiResponsePart[] };
  finishReason?: string;
  groundingMetadata?: GeminiGroundingMetadata;
}

/** Une page web citée par la recherche Google. */
export interface GeminiGroundingSource {
  uri: string;
  title?: string;
}

/**
 * Ce que la recherche Google a apporté à une réponse.
 *
 * `searchEntryPointHtml` est le bloc « Suggestions Google » que les
 * conditions d'utilisation du grounding imposent d'afficher avec la réponse.
 */
export interface GeminiGrounding {
  sources: GeminiGroundingSource[];
  webSearchQueries: string[];
  searchEntryPointHtml?: string;
}

/** Réponse Gemini telle que la voit le reste du backend, SDK-agnostique. */
export interface GeminiResponse {
  /** Texte concaténé du premier candidat. Chaîne vide si la réponse n'en a pas. */
  text: string;
  candidates: GeminiCandidate[];
  usageMetadata?: GeminiUsage;
  /** Présent seulement quand le premier candidat porte un `groundingMetadata`. */
  grounding?: GeminiGrounding;
}

/** Ce que [toGeminiResponse] lit d'une réponse du SDK. */
export type GeminiSdkResponse = Pick<GenerateContentResponse, "candidates" | "usageMetadata">;

/**
 * Convertit une réponse du SDK vers [GeminiResponse].
 *
 * Le texte est reconstruit depuis les parts plutôt que via l'accesseur
 * `response.text` du SDK, qui ignore silencieusement les parts non textuelles
 * et journalise un avertissement à chaque réponse mixte (texte + image). Ici une réponse bloquée donne une chaîne
 * vide et `finishReason` reste lisible dans [GeminiResponse.candidates] :
 * l'appelant décide quoi en faire au lieu de subir un throw.
 */
export function toGeminiResponse(result: GeminiSdkResponse): GeminiResponse {
  const candidates = (result.candidates ?? []) as GeminiCandidate[];
  const parts = candidates[0]?.content?.parts ?? [];
  const text = parts.map((part) => (typeof part.text === "string" ? part.text : "")).join("");
  const grounding = groundingOf(candidates[0]?.groundingMetadata);
  return {
    text,
    candidates,
    usageMetadata: result.usageMetadata as GeminiUsage | undefined,
    ...(grounding ? { grounding } : {}),
  };
}

/**
 * Normalise le `groundingMetadata` d'un candidat.
 *
 * Une source sans URI ne peut être ni affichée ni ouverte : elle est écartée.
 * Les doublons d'URI — une même page citée pour deux passages — n'en font qu'un.
 */
export function groundingOf(
  metadata: GeminiGroundingMetadata | undefined,
): GeminiGrounding | undefined {
  if (!metadata) return undefined;
  const seen = new Set<string>();
  const sources: GeminiGroundingSource[] = [];
  for (const chunk of metadata.groundingChunks ?? []) {
    const uri = chunk.web?.uri;
    if (!uri || seen.has(uri)) continue;
    seen.add(uri);
    sources.push(chunk.web?.title ? { uri, title: chunk.web.title } : { uri });
  }
  const html = metadata.searchEntryPoint?.renderedContent;
  return {
    sources,
    webSearchQueries: metadata.webSearchQueries ?? [],
    ...(html ? { searchEntryPointHtml: html } : {}),
  };
}

// ── Chargement du SDK ────────────────────────────────────────────────────────

type GenAiSdk = typeof import("@google/genai");

let sdkPromise: Promise<GenAiSdk> | null = null;

/**
 * SDK `@google/genai`, chargé au premier appel de modèle.
 *
 * Son import coûte une centaine de millisecondes, contre quelques-unes pour
 * l'ancien `@google/generative-ai`. Chargé au niveau module, il les ajouterait
 * au démarrage des cinquante fonctions du bundle, y compris celles qui
 * n'appellent jamais Gemini, et rapprocherait la découverte du déploiement de
 * son plafond de dix secondes. Un import raté n'est pas mémorisé : l'appel
 * suivant retente.
 */
function loadSdk(): Promise<GenAiSdk> {
  if (!sdkPromise) {
    sdkPromise = import("@google/genai").catch((err: unknown) => {
      sdkPromise = null;
      throw err;
    });
  }
  return sdkPromise;
}

/** Seul hôte autorisé pour les appels Gemini. */
export const GEMINI_API_BASE_URL = "https://generativelanguage.googleapis.com";

let cachedClient: GoogleGenAI | null = null;
let cachedApiKey: string | null = null;

/** Client SDK mémorisé par clé : la clé vient de Secret Manager au runtime. */
async function getClient(apiKey: string): Promise<GoogleGenAI> {
  if (cachedClient && cachedApiKey === apiKey) return cachedClient;
  const { GoogleGenAI: Client } = await loadSdk();
  // Hôte et mode figés : le SDK lirait sinon GOOGLE_GEMINI_BASE_URL et
  // GOOGLE_GENAI_USE_VERTEXAI dans l'environnement, et la clé partirait
  // vers l'hôte que ces variables désignent.
  cachedClient = new Client({
    apiKey,
    vertexai: false,
    httpOptions: { baseUrl: GEMINI_API_BASE_URL },
  });
  cachedApiKey = apiKey;
  return cachedClient;
}

/** Requête acceptée par [GeminiModelHandle.generateContent]. */
export interface GeminiModelRequest {
  contents: Content[];
  config?: GenerateContentConfig;
}

/** Modèle désigné par son nom, prêt à être appelé. */
export interface GeminiModelHandle {
  generateContent(request: GeminiModelRequest): Promise<GenerateContentResponse>;
}

/**
 * Désigne un modèle autre que [GEMINI_MODEL] (génération et retouche
 * d'images, bac à sable). Passe par ici pour que l'import du SDK reste
 * confiné à ce fichier.
 *
 * Ni réessai ni journal : ces appels ont leur propre traçabilité chez
 * l'appelant. Le SDK n'est chargé qu'au premier `generateContent`.
 */
export function createGenerativeModel(apiKey: string, model: string): GeminiModelHandle {
  return {
    async generateContent(request) {
      const client = await getClient(apiKey);
      return client.models.generateContent({ model, ...request });
    },
  };
}

/**
 * Construit la requête d'un appel [callGemini].
 *
 * Isolée pour être vérifiée sans réseau : c'est ici que vivent le plafond de
 * raisonnement et l'outil de recherche Google.
 */
export function buildGeminiRequest(
  model: string,
  parts: Part[],
  options: { thinkingBudget?: number | null; googleSearch?: boolean } = {},
): GeminiModelRequest & { model: string } {
  const config: GenerateContentConfig = {};
  if (options.thinkingBudget != null) {
    config.thinkingConfig = { thinkingBudget: options.thinkingBudget };
  }
  if (options.googleSearch) {
    config.tools = [{ googleSearch: {} }];
  }
  return {
    model,
    contents: [{ role: "user", parts }],
    ...(Object.keys(config).length > 0 ? { config } : {}),
  };
}

export class GeminiQuotaExceededError extends Error {
  /** `logged` : déjà journalisée avec son contexte, `toHttpsError` ne la réécrit pas. */
  constructor(
    message: string,
    public readonly logged = false,
  ) {
    super(message);
    this.name = "GeminiQuotaExceededError";
  }
}

export class GeminiError extends Error {
  /** `logged` : déjà journalisée avec son contexte, `toHttpsError` ne la réécrit pas. */
  constructor(
    message: string,
    public readonly cause?: unknown,
    public readonly logged = false,
  ) {
    super(message);
    this.name = "GeminiError";
  }
}

export interface GeminiCallContext {
  correlationId: string;
  feature: string;
  moduleType?: ModuleType;
  /** Scan de l'utilisateur auquel l'appel appartient, quand il en vient un. */
  scanId?: string;
  /** Identifiant de cet appel, quand il vient du routeur. */
  callId?: string;
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
  /**
   * Autorise le modèle à interroger Google Search (grounding). Les pages
   * citées reviennent dans [GeminiResponse.grounding].
   *
   * Un seul poste s'en sert : `web_recipe_search` (`gemini/webRecipeSearch.ts`).
   * La recherche est facturée à l'appel ancré, en plus des jetons : le poste
   * qui l'active passe `groundedSearchCount` à `recordUsage`, et compte le
   * résultat d'outil en entrée ([inputTokensOf]).
   */
  googleSearch?: boolean;
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

/** Temps minimal laissé à une tentative : en dessous, elle ne part pas. */
export const MIN_ATTEMPT_MS = 5_000;

/**
 * Pause avant de relancer un appel refusé pour quota, ou `null` s'il ne
 * reste pas de quoi faire une tentative de plus.
 *
 * Backoff exponentiel (2 s, 4 s, 8 s… plafonné à 60 s), raccourci pour que la
 * tentative suivante dispose encore de [MIN_ATTEMPT_MS]. Sans ce
 * raccourcissement, une pause de 60 s pouvait dépasser l'échéance de l'appel,
 * et la tentative suivante partait avec un délai négatif (« Gemini call
 * timeout after -4749ms », 21 octobre 2026).
 */
export function quotaRetryDelayMs(attempt: number, remainingMs: number): number | null {
  const available = remainingMs - MIN_ATTEMPT_MS;
  if (available <= 0) return null;
  return Math.min(60_000, 2_000 * Math.pow(2, attempt - 1), available);
}

/**
 * Appelle Gemini avec retry automatique sur quota dépassé.
 *
 * Stratégie : si on reçoit un 429 / QUOTA_EXCEEDED, on attend (backoff exponentiel
 * plafonné à 60s, voir [quotaRetryDelayMs]) et on retente. Le retry s'arrête quand
 * l'échéance de l'appel ne laisse plus de quoi tenter (Cloud Tasks reprendra la
 * main pour un nouveau retry). Un 402 (crédits épuisés) n'est jamais relancé.
 */
export async function callGemini(
  apiKey: string,
  parts: Part[],
  ctx: GeminiCallContext,
): Promise<GeminiResponse> {
  const timeoutMs = ctx.timeoutMs ?? 5 * 60 * 1000;
  const deadline = Date.now() + timeoutMs;
  let attempt = 0;
  // Le plafond de raisonnement est abandonné dès que l'API le refuse : mieux
  // vaut une facture de sortie plus lourde qu'un poste qui ne répond plus.
  let thinkingBudget = ctx.thinkingBudget ?? null;

  while (true) {
    attempt++;
    const startedAt = Date.now();

    // Aucune tentative ne part avec un délai nul ou négatif : l'échéance de
    // l'appel est atteinte, l'échec se dit tel quel.
    const remainingMs = deadline - startedAt;
    if (remainingMs <= 0) {
      const message = `Délai de l'appel Gemini épuisé avant la tentative ${attempt} (budget ${timeoutMs} ms)`;
      await logError(`Appel IA échoué (${ctx.feature}) — délai épuisé`, {
        correlationId: ctx.correlationId,
        scanId: ctx.scanId,
        callId: ctx.callId,
        moduleType: ctx.moduleType,
        jobId: ctx.jobId,
        userId: ctx.userId,
        stepIndex: ctx.stepIndex,
        geminiStatus: "ERROR",
        provider: "gemini",
        model: GEMINI_MODEL,
        feature: ctx.feature,
        errorDescription: message,
        extra: { attempt, timeoutMs },
      });
      throw new GeminiError(message, undefined, true);
    }

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
      scanId: ctx.scanId,
      callId: ctx.callId,
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
      // Le plafond de raisonnement pèse près de neuf dixièmes de la facture
      // de sortie ; le repli ci-dessous couvre le cas où l'API le refuserait.
      const request = buildGeminiRequest(GEMINI_MODEL, parts, {
        thinkingBudget,
        googleSearch: ctx.googleSearch,
      });

      // Le chargement du SDK, au premier appel de l'instance, entre dans le
      // délai de l'appel : il en fait partie pour l'appelant.
      // Le délai annule la requête HTTP : la connexion est fermée et la
      // réponse n'est plus attendue.
      const abort = new AbortController();
      request.config = { ...request.config, abortSignal: abort.signal };
      const sdkResult = await withTimeout(
        getClient(apiKey).then((client) => client.models.generateContent(request)),
        Math.max(1, Math.min(timeoutMs, deadline - Date.now())),
        abort,
      );
      const result = toGeminiResponse(sdkResult);

      const usage = result.usageMetadata;
      const elapsed = Date.now() - startedAt;
      await logInfo(`Appel IA terminé (${ctx.feature})`, {
        correlationId: ctx.correlationId,
        scanId: ctx.scanId,
        callId: ctx.callId,
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
          inputTokens: inputTokensOf(usage),
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
          scanId: ctx.scanId,
          callId: ctx.callId,
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

      const backoffMs =
        status === "QUOTA_EXCEEDED" ? quotaRetryDelayMs(attempt, deadline - Date.now()) : null;
      if (backoffMs != null) {
        await logError(`Appel IA — quota dépassé, nouvelle tentative dans ${backoffMs} ms`, {
          correlationId: ctx.correlationId,
          scanId: ctx.scanId,
          callId: ctx.callId,
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
        scanId: ctx.scanId,
        callId: ctx.callId,
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
        throw new GeminiQuotaExceededError(errorMessage(err), true);
      }
      throw new GeminiError(errorMessage(err), err, true);
    }
  }
}

/**
 * Crédits épuisés, quota dépassé ou autre erreur.
 *
 * `@google/genai` lève une `ApiError` dont `status` porte le code HTTP et dont
 * le message est le corps JSON de l'erreur (`{"error":{"code":429,…,
 * "status":"RESOURCE_EXHAUSTED"}}`). Le code fait foi quand il est là ; le
 * message couvre les erreurs sans code.
 *
 * Un 402 porte aussi `RESOURCE_EXHAUSTED` (« Your prepayment credits are
 * depleted »), mais il ne se résorbe pas en quelques secondes : il attend un
 * rechargement du compte. Classé `QUOTA_EXCEEDED`, il était relancé six fois,
 * avec des pauses de 2 à 60 s, avant que le repli sur Claude ne parte
 * (21 octobre 2026). `CREDITS_EXHAUSTED` échoue tout de suite.
 */
export function classifyError(err: unknown): GeminiStatus {
  const status = (err as { status?: unknown } | null)?.status;
  const msg = errorMessage(err).toLowerCase();
  if (status === 402 || /"code"\s*:\s*402\b/.test(msg) || msg.includes("prepayment credits")) {
    return "CREDITS_EXHAUSTED";
  }
  if (status === 429) return "QUOTA_EXCEEDED";
  if (/\b429\b/.test(msg) || msg.includes("quota") || msg.includes("resource_exhausted")) {
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

function withTimeout<T>(promise: Promise<T>, ms: number, abort?: AbortController): Promise<T> {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      const err = new Error(`Gemini call timeout after ${ms}ms`);
      abort?.abort(err);
      reject(err);
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
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
