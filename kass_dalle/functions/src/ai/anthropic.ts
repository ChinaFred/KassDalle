/**
 * Client Claude (Anthropic).
 *
 * **Ce fichier est le SEUL à importer `@anthropic-ai/sdk`**, exactement comme
 * `gemini/client.ts` est le seul à importer le SDK Google. Le reste du backend
 * ne connaît que `ModelCallResult` : c'est ce qui rend un second moteur
 * ajoutable sans que la chaîne nutrition, l'import ou le reporting aient à
 * savoir lequel a répondu.
 *
 * Choix de paramètres pour ce projet :
 *  - `thinking: adaptive`, avec un effort choisi PAR POSTE et `low` par défaut.
 *    L'estimation nutritionnelle est un rappel de connaissances, pas un problème
 *    de raisonnement, et les jetons de réflexion se facturent au tarif de
 *    sortie. Transcrire une page de livre est l'exact contraire : ce réglage
 *    valait pour la nutrition et a été hérité, en silence, par une tâche de
 *    lecture minutieuse.
 *  - `output_config.format` quand l'appelant fournit un schéma : Claude garantit
 *    alors la forme du JSON. C'est la principale raison d'être ici — les trois
 *    derniers correctifs de la chaîne nutrition venaient tous d'une réponse mal
 *    formée.
 *  - Ni `temperature` ni `top_p` : rejetés par les modèles récents.
 *  - Haiku 4.5 part SANS raisonnement et sans `effort` : il refuse les deux
 *    (voir `requestShapeFor`).
 */

import Anthropic from "@anthropic-ai/sdk";

import { logDebug, logError, logInfo } from "../logging";
import {
  ModelCallError,
  type ModelCallContext,
  type ModelCallResult,
  type ModelOutputSchema,
  type ModelPart,
} from "./types";

/** Modèle Claude par défaut du projet. */
export const ANTHROPIC_MODEL = "claude-sonnet-5";

/** Plafond de sortie : large pour un lot d'ingrédients, loin des délais HTTP. */
const DEFAULT_MAX_TOKENS = 8_000;

let cachedClient: Anthropic | null = null;
let cachedApiKey: string | null = null;

function getClient(apiKey: string): Anthropic {
  if (cachedClient && cachedApiKey === apiKey) return cachedClient;
  cachedClient = new Anthropic({ apiKey });
  cachedApiKey = apiKey;
  return cachedClient;
}

/**
 * Clé Claude disponible dans l'environnement d'exécution.
 *
 * Lue depuis `process.env` plutôt que via `defineSecret` tant que le secret
 * n'est pas créé : un secret déclaré et attaché mais absent de Secret Manager
 * fait échouer **tout** le déploiement, y compris les fonctions qui n'en ont
 * pas besoin. Tant que la clé n'est pas posée, cette fonction rend `null`, le
 * routeur reste sur Gemini, et rien ne casse.
 */
export function anthropicApiKey(): string | null {
  const key = (process.env.ANTHROPIC_API_KEY ?? "").trim();
  return key.length > 0 ? key : null;
}

/** Types d'images acceptés par l'API Anthropic. */
const SUPPORTED_IMAGE_MIME_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"] as const;

/** Types de documents acceptés par l'API Anthropic. */
const SUPPORTED_DOCUMENT_MIME_TYPES = ["application/pdf"] as const;

/**
 * Claude sait-il lire toutes ces entrées ?
 *
 * Le projet importe aussi du DOCX et des images exotiques (HEIC) que Gemini
 * accepte et que Claude refuse. Router un tel appel vers Claude ne produirait
 * qu'un aller-retour perdu suivi d'un repli : autant le savoir avant d'appeler,
 * et servir directement avec le moteur qui sait lire le fichier.
 */
export function anthropicSupportsParts(parts: ModelPart[]): boolean {
  return parts.every((part) => {
    if (part.kind === "text") return true;
    if (part.kind === "image") {
      return (SUPPORTED_IMAGE_MIME_TYPES as readonly string[]).includes(part.mimeType);
    }
    return (SUPPORTED_DOCUMENT_MIME_TYPES as readonly string[]).includes(part.mimeType);
  });
}

export function toAnthropicContent(parts: ModelPart[]): Anthropic.ContentBlockParam[] {
  return parts.map((part) => {
    // `undefined` disparaît au sérialisage JSON : un fragment qui ne demande
    // pas la mise en cache part donc sans `cache_control`, comme avant.
    const cache_control: Anthropic.CacheControlEphemeral | undefined = part.cache
      ? { type: "ephemeral" }
      : undefined;
    if (part.kind === "text") {
      return { type: "text", text: part.text, cache_control } satisfies Anthropic.TextBlockParam;
    }
    if (part.kind === "document") {
      return {
        type: "document",
        source: {
          type: "base64",
          media_type: "application/pdf",
          data: part.dataBase64,
        },
        cache_control,
      } satisfies Anthropic.DocumentBlockParam;
    }
    return {
      type: "image",
      source: {
        type: "base64",
        media_type: part.mimeType as (typeof SUPPORTED_IMAGE_MIME_TYPES)[number],
        data: part.dataBase64,
      },
      cache_control,
    } satisfies Anthropic.ImageBlockParam;
  });
}

type AnthropicEffort = NonNullable<ModelCallContext["effort"]>;

/**
 * Modèles qui refusent `thinking: { type: "adaptive" }` et `output_config.effort`.
 *
 * Haiku 4.5 répond 400 « adaptive thinking is not supported on this model »,
 * et le paramètre `effort` y lève aussi une erreur. Il accepterait un
 * raisonnement à budget fixe (`{ type: "enabled", budget_tokens }`), mais il
 * est choisi pour être le modèle rapide et bon marché d'un rappel de
 * connaissances : il part donc sans raisonnement du tout. Le 21 octobre 2026,
 * tous ses appels échouaient et se repliaient sur Gemini.
 *
 * Comparaison par préfixe : un identifiant daté (`claude-haiku-4-5-20251001`)
 * désigne le même modèle.
 */
const MODELS_WITHOUT_ADAPTIVE_THINKING = ["claude-haiku-4-5"] as const;

/** Ce que la requête Claude envoie en raisonnement et en effort, pour un modèle. */
export interface AnthropicRequestShape {
  /** `null` : le champ `thinking` n'est pas envoyé. */
  thinking: { type: "adaptive" } | null;
  /** `null` : `output_config.effort` n'est pas envoyé. */
  effort: AnthropicEffort | null;
  /** Effort demandé par le poste ou par Admin, mais non transmis au modèle. */
  droppedEffort: AnthropicEffort | null;
}

/**
 * Forme de la requête pour un modèle et un effort demandé (`low` par défaut).
 *
 * Fonction pure, testée seule (`tests/anthropicRequestShape.test.ts`) : un
 * paramètre refusé par un modèle fait échouer 100 % de ses appels.
 */
export function requestShapeFor(model: string, effort?: AnthropicEffort): AnthropicRequestShape {
  const requested = effort ?? "low";
  const id = model.trim().toLowerCase();
  const withoutThinking = MODELS_WITHOUT_ADAPTIVE_THINKING.some(
    (prefix) => id === prefix || id.startsWith(`${prefix}-`),
  );
  if (withoutThinking) {
    return { thinking: null, effort: null, droppedEffort: effort ?? null };
  }
  return { thinking: { type: "adaptive" }, effort: requested, droppedEffort: null };
}

/**
 * Schéma de sortie accepté par Claude : chaque objet porte
 * `additionalProperties: false`.
 *
 * L'API refuse tout schéma dont un objet ne le précise pas (400
 * « For 'object' type, 'additionalProperties' must be explicitly set to
 * false »). Le schéma de `planning_constraints` l'omettait, et chaque
 * traduction de consigne échouait. Les schémas des postes le posent
 * eux-mêmes ; cette passe le pose sur ceux qui l'oublient, à tous les
 * niveaux, pour qu'un oubli ne coûte plus un poste entier. Une valeur déjà
 * présente est gardée telle quelle. Le schéma reçu n'est pas modifié : la
 * fonction rend une copie.
 *
 * Gemini ne reçoit pas ce schéma (`buildGeminiRequest` n'envoie pas de
 * `responseSchema`) : la passe ne concerne que Claude.
 */
export function toStrictJsonSchema(schema: Record<string, unknown>): Record<string, unknown> {
  return strictSchema(schema) as Record<string, unknown>;
}

/** Mots-clés dont la valeur est une table nom → sous-schéma. */
const SCHEMA_MAP_KEYS = new Set(["properties", "patternProperties", "$defs", "definitions"]);
/** Mots-clés dont la valeur est un sous-schéma. */
const SCHEMA_KEYS = new Set(["items", "additionalProperties", "not", "contains"]);
/** Mots-clés dont la valeur est une liste de sous-schémas. */
const SCHEMA_LIST_KEYS = new Set(["anyOf", "oneOf", "allOf", "prefixItems"]);

function strictSchema(node: unknown): unknown {
  if (!node || typeof node !== "object" || Array.isArray(node)) return node;
  const source = node as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(source)) {
    if (SCHEMA_MAP_KEYS.has(key) && value && typeof value === "object" && !Array.isArray(value)) {
      out[key] = Object.fromEntries(
        Object.entries(value as Record<string, unknown>).map(([name, sub]) => [
          name,
          strictSchema(sub),
        ]),
      );
    } else if (SCHEMA_KEYS.has(key)) {
      out[key] = strictSchema(value);
    } else if (SCHEMA_LIST_KEYS.has(key) && Array.isArray(value)) {
      out[key] = value.map(strictSchema);
    } else {
      // `enum`, `const`, `required`, `description`… : des valeurs, pas des
      // sous-schémas.
      out[key] = value;
    }
  }
  const type = source.type;
  const isObject =
    type === "object" || (Array.isArray(type) && type.includes("object")) || "properties" in source;
  if (isObject && !("additionalProperties" in source)) {
    out.additionalProperties = false;
  }
  return out;
}

/**
 * Appelle Claude et rend une réponse normalisée.
 *
 * Lève `ModelCallError` sur échec — c'est le routeur, et lui seul, qui décide
 * s'il faut se replier sur l'autre moteur.
 */
export async function callAnthropic(args: {
  apiKey: string;
  parts: ModelPart[];
  ctx: ModelCallContext;
  /** Identifiant de cet appel — porté par ses lignes de journal et sa consommation. */
  callId: string;
  model?: string;
  maxTokens?: number;
  outputSchema?: ModelOutputSchema;
  systemPrompt?: string;
}): Promise<ModelCallResult> {
  const model = args.model ?? ANTHROPIC_MODEL;
  const client = getClient(args.apiKey);
  const startedAt = Date.now();
  const shape = requestShapeFor(model, args.ctx.effort);
  if (shape.droppedEffort) {
    // Un effort réglé dans Admin › Moteur d'IA, ou posé par le code du poste,
    // n'a pas d'effet sur ce modèle : la ligne le dit, sans bloquer l'appel.
    void logDebug({
      message: `Appel IA — effort « ${shape.droppedEffort} » non transmis, le modèle ne l'accepte pas (${args.ctx.feature})`,
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      callId: args.callId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      provider: "anthropic",
      model,
      feature: args.ctx.feature,
      extra: { droppedEffort: shape.droppedEffort },
    });
  }
  const outputConfig: Anthropic.OutputConfig = {
    ...(shape.effort ? { effort: shape.effort } : {}),
    ...(args.outputSchema
      ? {
          format: {
            type: "json_schema" as const,
            schema: toStrictJsonSchema(args.outputSchema.schema),
          },
        }
      : {}),
  };

  try {
    // Réponse EN FLUX, toujours.
    //
    // Le SDK refuse un appel non-streamé dès que `max_tokens` dépasse
    // 128 000 / 6 ≈ 21 333 : au-delà, il estime que la réponse POURRAIT
    // demander plus de dix minutes et lève « Streaming is required for
    // operations that may take longer than 10 minutes ». Ce n'est pas une
    // durée constatée, c'est une borne calculée depuis le plafond demandé —
    // la transcription d'une page, qui en réclame 24 000 pour ne pas tronquer
    // un JSON verbeux, échouait donc systématiquement avant même d'être
    // envoyée, et se repliait sur Gemini à chaque import.
    //
    // Baisser le plafond serait la mauvaise réponse : il ne réserve rien, il
    // borne. Le réduire ne rendrait pas l'appel plus rapide, il tronquerait
    // les pages longues. On streame donc, comme le SDK le demande, et
    // `finalMessage()` rend exactement l'objet que la suite attend — jetons,
    // `stop_reason` et blocs de contenu compris.
    const response = await client.messages
      .stream(
        {
          model,
          max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
          ...(shape.thinking ? { thinking: shape.thinking } : {}),
          ...(Object.keys(outputConfig).length > 0 ? { output_config: outputConfig } : {}),
          ...(args.systemPrompt ? { system: args.systemPrompt } : {}),
          messages: [{ role: "user", content: toAnthropicContent(args.parts) }],
        },
        args.ctx.timeoutMs ? { timeout: args.ctx.timeoutMs } : undefined,
      )
      .finalMessage();

    // Les classificateurs de sûreté peuvent décliner une requête : la réponse
    // est un HTTP 200 dont le contenu est vide. Lire `content[0]` sans vérifier
    // `stop_reason` casserait ici plutôt qu'au bon endroit.
    if (response.stop_reason === "refusal") {
      throw new ModelCallError(
        `Claude a décliné la requête (${response.stop_details?.category ?? "sans catégorie"})`,
        "anthropic",
        false,
      );
    }

    const text = response.content
      .map((block) => (block.type === "text" ? block.text : ""))
      .join("")
      .trim();

    // Les quatre compteurs, pas deux.
    //
    // `input_tokens` ne porte que le prompt NON mis en cache : la partie mise
    // en cache est comptée à part, en écriture puis en relecture, et facturée
    // à un autre tarif. N'en lire que deux revenait à jeter silencieusement
    // tout ce qui passe par le cache — un appel entièrement servi depuis le
    // cache s'enregistrait avec zéro jeton d'entrée, coût nul, sans anomalie
    // visible nulle part.
    //
    // Deux prompts posent `cache_control` depuis le 28 septembre 2026 —
    // `TRANSCRIPTION_PROMPT` et `TAGGING_PROMPT`, voir `textPart(..., {cache:
    // true})` dans `gemini/transcription.ts` et `gemini/tagging.ts`. Les
    // autres postes n'en posent aucun ; ces deux compteurs y restent à zéro.
    // Les lire, c'est pouvoir le vérifier plutôt que le supposer.
    const cacheCreationInputTokens = response.usage.cache_creation_input_tokens ?? 0;
    const cacheReadInputTokens = response.usage.cache_read_input_tokens ?? 0;
    const inputTokens = response.usage.input_tokens ?? 0;
    const outputTokens = response.usage.output_tokens ?? 0;
    const usage = {
      inputTokens,
      outputTokens,
      cacheCreationInputTokens,
      cacheReadInputTokens,
      totalTokens: inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens,
    };

    void logInfo({
      // Message neutre : le fournisseur est un label, pas du texte. Un message
      // qui nomme le moteur devient faux le jour où le poste bascule, et
      // duplique une information déjà filtrable.
      message: `Appel IA terminé (${args.ctx.feature})`,
      correlationId: args.ctx.correlationId,
      scanId: args.ctx.scanId,
      callId: args.callId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      jobId: args.ctx.jobId,
      stepIndex: args.ctx.stepIndex,
      executionTimeMs: Date.now() - startedAt,
      provider: "anthropic",
      model,
      feature: args.ctx.feature,
      extra: { stopReason: response.stop_reason, ...usage },
    });

    return {
      text,
      provider: "anthropic",
      model,
      usage,
      callId: args.callId,
      stopReason: response.stop_reason ?? undefined,
    };
  } catch (err) {
    if (err instanceof ModelCallError) throw err;

    // Tout échec technique autorise le repli, y compris un 400 ou un 401.
    //
    // La version précédente réservait le repli aux 429 et 5xx, en supposant
    // qu'une requête malformée le serait aussi sur l'autre moteur. C'est faux :
    // les deux fournisseurs n'ont pas le même contrat d'API, et un rejet propre
    // à Claude — schéma de sortie, paramètre non supporté, clé invalide — n'a
    // aucune raison d'être rejeté par Gemini. Conséquence observée : six
    // ingrédients restaient sans valeur alors que Gemini savait répondre.
    //
    // Le seul cas qui ne se rejoue pas ailleurs est le refus de CONTENU, levé
    // plus haut avec `retryable: false` : là, le second moteur déclinerait pour
    // les mêmes raisons, et insister n'aurait pas de sens.
    const status = (err as { status?: number })?.status;

    const description = err instanceof Error ? err.message : String(err);
    await logError({
      // La raison est dans le message, pas seulement dans le payload : un écran
      // de logs se lit en liste, et une erreur qu'il faut déplier pour
      // comprendre est une erreur qu'on ne comprend pas.
      message: `Appel IA échoué (${args.ctx.feature}) — ${status ?? "sans statut"} : ${description.slice(0, 300)}`,
      errorDescription: description,
      correlationId: args.ctx.correlationId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      jobId: args.ctx.jobId,
      stepIndex: args.ctx.stepIndex,
      executionTimeMs: Date.now() - startedAt,
      provider: "anthropic",
      model,
      feature: args.ctx.feature,
      extra: { httpStatus: status ?? null },
    });

    throw new ModelCallError(description, "anthropic", true, err);
  }
}
