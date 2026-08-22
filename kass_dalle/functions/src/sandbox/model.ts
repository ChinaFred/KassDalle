/**
 * Le choix du modèle, dans le bac à sable seulement.
 *
 * L'application choisit son moteur poste par poste, dans Admin → Moteur d'IA,
 * et son modèle Claude de la même façon. Elle n'a en revanche **aucun moyen de
 * choisir un modèle Gemini par poste** : `GEMINI_MODEL` est une constante
 * unique pour les cinquante postes. Comparer deux modèles sur une détection
 * imposerait donc de changer celui de toute l'application.
 *
 * Ce fichier donne au bac à sable son propre sélecteur, sans rien changer au
 * routage. Quand l'expérience nomme un fournisseur et un modèle, l'appel les
 * emprunte ; sinon il repasse par `callModel` et suit la politique comme
 * n'importe quel poste.
 *
 * Ce qui reste commun avec la production, et doit le rester :
 *
 * - **le plafond de dépense quotidien**, vérifié avant l'appel. Une expérience
 *   dépense l'argent du même compte ;
 * - **la comptabilité**, écrite après. Un modèle absent de la grille tarifaire
 *   sera compté sans montant, dans `total_unpriced_calls` — c'est le
 *   comportement voulu du projet : un coût manquant se voit, un coût faux non.
 *
 * Ce qui ne l'est pas : ni repli automatique sur l'autre moteur, ni retry sur
 * quota. Une expérience doit échouer visiblement, pas être secourue.
 */

import { GEMINI_API_KEY } from "../config";
import { anthropicApiKey, callAnthropic } from "../ai/anthropic";
import { assertWithinDailyBudget } from "../ai/budget";
import { callModel, recordModelUsage } from "../ai/router";
import { createGenerativeModel, thinkingTokensOf, toGeminiResponse } from "../gemini/client";
import type { ModelCallContext, ModelCallResult, ModelPart } from "../ai/types";

export type SandboxProvider = "gemini" | "anthropic";

export interface SandboxModelChoice {
  provider: SandboxProvider;
  model: string;
}

/**
 * Lit le choix de modèle d'une requête, `null` si l'expérience n'en impose pas.
 *
 * Le modèle n'est volontairement pas validé contre une liste : le bac à sable
 * sert justement à essayer un identifiant qui n'y figure pas encore. Un nom
 * inconnu fera échouer l'appel chez le fournisseur, avec son message, ce qui
 * est la réponse utile.
 */
export function readModelChoice(data: unknown): SandboxModelChoice | null {
  const source = (data ?? {}) as Record<string, unknown>;
  const provider = source.provider;
  const model = source.model;
  if (provider !== "gemini" && provider !== "anthropic") return null;
  if (typeof model !== "string" || !model.trim() || model.length > 64) return null;
  return { provider, model: model.trim() };
}

/**
 * Appelle le modèle demandé par l'expérience, ou celui de la politique.
 */
export async function askModel(args: {
  parts: ModelPart[];
  ctx: ModelCallContext;
  choice: SandboxModelChoice | null;
  maxTokens?: number;
}): Promise<ModelCallResult> {
  if (!args.choice) {
    return callModel({ parts: args.parts, ctx: args.ctx });
  }

  // Le plafond se vérifie ici parce qu'on court-circuite `callModel`, qui le
  // porte d'habitude. Sans cette ligne, le bac à sable serait le seul chemin
  // par lequel une dépense échappe au plafond du compte.
  await assertWithinDailyBudget(args.ctx.userId, args.ctx.feature);

  const result =
    args.choice.provider === "anthropic"
      ? await callChosenAnthropic(args.parts, args.ctx, args.choice.model, args.maxTokens)
      : await callChosenGemini(args.parts, args.ctx, args.choice.model);

  await recordModelUsage(result, args.ctx);
  return result;
}

async function callChosenAnthropic(
  parts: ModelPart[],
  ctx: ModelCallContext,
  model: string,
  maxTokens?: number,
): Promise<ModelCallResult> {
  const key = anthropicApiKey();
  if (!key) {
    throw new Error("Clé Anthropic absente de l'environnement de cette fonction.");
  }
  return callAnthropic({ apiKey: key, parts, ctx, model, maxTokens });
}

/**
 * Gemini, sur le modèle nommé par l'expérience.
 *
 * `callGemini` ne convient pas : il instancie toujours `GEMINI_MODEL`. On passe
 * donc par `createGenerativeModel`, qui existe pour ça — c'est le point de
 * sortie prévu du client Gemini, et il garde l'import du SDK confiné à son
 * fichier.
 */
async function callChosenGemini(
  parts: ModelPart[],
  ctx: ModelCallContext,
  model: string,
): Promise<ModelCallResult> {
  const geminiParts = parts.map((part) =>
    part.kind === "text"
      ? { text: part.text }
      : { inlineData: { mimeType: part.mimeType, data: part.dataBase64 } },
  );

  const generative = createGenerativeModel(GEMINI_API_KEY.value(), model);
  const raw = await generative.generateContent({
    contents: [{ role: "user", parts: geminiParts }],
  });
  const response = toGeminiResponse(raw);

  const input = response.usageMetadata?.promptTokenCount ?? 0;
  const output = response.usageMetadata?.candidatesTokenCount ?? 0;
  const thinking = thinkingTokensOf(response.usageMetadata);
  return {
    text: (response.text ?? "").trim(),
    provider: "gemini",
    model,
    usage: {
      inputTokens: input,
      outputTokens: output,
      thinkingTokens: thinking,
      totalTokens: response.usageMetadata?.totalTokenCount ?? input + output + thinking,
    },
    stopReason: response.candidates[0]?.finishReason,
  };
}
