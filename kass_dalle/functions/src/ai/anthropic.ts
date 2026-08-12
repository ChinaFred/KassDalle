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
 *  - `thinking: adaptive` avec `effort: low`. L'estimation nutritionnelle est un
 *    rappel de connaissances, pas un problème de raisonnement ; les jetons de
 *    réflexion se facturent en sortie, au tarif le plus cher.
 *  - `output_config.format` quand l'appelant fournit un schéma : Claude garantit
 *    alors la forme du JSON. C'est la principale raison d'être ici — les trois
 *    derniers correctifs de la chaîne nutrition venaient tous d'une réponse mal
 *    formée.
 *  - Ni `temperature` ni `top_p` : rejetés par les modèles récents.
 */

import Anthropic from "@anthropic-ai/sdk";

import { logError, logInfo } from "../logging";
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

function toAnthropicContent(parts: ModelPart[]): Anthropic.ContentBlockParam[] {
  return parts.map((part) => {
    if (part.kind === "text") {
      return { type: "text", text: part.text } satisfies Anthropic.TextBlockParam;
    }
    return {
      type: "image",
      source: {
        type: "base64",
        media_type: part.mimeType as "image/jpeg" | "image/png" | "image/gif" | "image/webp",
        data: part.dataBase64,
      },
    } satisfies Anthropic.ImageBlockParam;
  });
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
  model?: string;
  maxTokens?: number;
  outputSchema?: ModelOutputSchema;
  systemPrompt?: string;
}): Promise<ModelCallResult> {
  const model = args.model ?? ANTHROPIC_MODEL;
  const client = getClient(args.apiKey);
  const startedAt = Date.now();

  try {
    const response = await client.messages.create(
      {
        model,
        max_tokens: args.maxTokens ?? DEFAULT_MAX_TOKENS,
        thinking: { type: "adaptive" },
        output_config: {
          effort: "low",
          ...(args.outputSchema
            ? {
                format: {
                  type: "json_schema" as const,
                  schema: args.outputSchema.schema,
                },
              }
            : {}),
        },
        ...(args.systemPrompt ? { system: args.systemPrompt } : {}),
        messages: [{ role: "user", content: toAnthropicContent(args.parts) }],
      },
      args.ctx.timeoutMs ? { timeout: args.ctx.timeoutMs } : undefined,
    );

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

    const usage = {
      inputTokens: response.usage.input_tokens ?? 0,
      outputTokens: response.usage.output_tokens ?? 0,
      totalTokens: (response.usage.input_tokens ?? 0) + (response.usage.output_tokens ?? 0),
    };

    void logInfo({
      message: `Claude call OK (${args.ctx.feature})`,
      correlationId: args.ctx.correlationId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
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
      stopReason: response.stop_reason ?? undefined,
    };
  } catch (err) {
    if (err instanceof ModelCallError) throw err;

    // Surcharge, quota, coupure réseau : le routeur peut utilement retenter
    // ailleurs. Une requête malformée, non — la retenter donnerait la même
    // erreur sur l'autre moteur.
    const status = (err as { status?: number })?.status;
    const retryable = status == null || status === 429 || status >= 500;

    await logError({
      message: `Claude call failed (${args.ctx.feature})`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.ctx.correlationId,
      moduleType: args.ctx.moduleType,
      userId: args.ctx.userId,
      executionTimeMs: Date.now() - startedAt,
      provider: "anthropic",
      model,
      feature: args.ctx.feature,
      extra: { httpStatus: status ?? null, retryable },
    });

    throw new ModelCallError(
      err instanceof Error ? err.message : String(err),
      "anthropic",
      retryable,
      err,
    );
  }
}
