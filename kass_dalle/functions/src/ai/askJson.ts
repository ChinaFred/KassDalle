/**
 * Un appel d'IA qui rend du JSON.
 *
 * Huit fonctions de `nutrition/aiEnrichment.ts` répétaient la même séquence :
 * prompt écrit en ligne, `callModel`, extraction du JSON à la regex, `JSON.parse`,
 * validation à la main. L'extraction était réécrite cinq fois dans ce seul
 * fichier, avec des expressions légèrement différentes — `\{[\s\S]*?\}` ici,
 * `\{[\s\S]*\}` là. L'écart ne casse rien tant que le modèle répond proprement ;
 * il se voit le jour où il enrobe sa réponse.
 *
 * Ce module est le seul endroit où l'on décide comment lire une réponse.
 */

import { callModel } from "./router";
import { textPart } from "./types";
import type { ModelCallContext, ModelOutputSchema } from "./types";

/**
 * Extrait l'objet JSON d'une réponse de modèle.
 *
 * Les modèles enrobent volontiers leur JSON : phrase d'introduction, bloc
 * ```json, virgule finale. On cherche donc le premier `{` et le dernier `}`
 * plutôt qu'une correspondance non gourmande, qui s'arrêtait au premier `}`
 * rencontré et tronquait tout objet imbriqué.
 *
 * Exporté pour être testable seul : c'est la fonction dont les cinq variantes
 * divergeaient.
 */
export function extractJsonObject(raw: string): string | null {
  const text = raw.trim();
  if (!text) return null;

  // Bloc de code Markdown : on retire la clôture avant de chercher les accolades,
  // sinon un ``` final peut être pris pour du contenu.
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1].trim() : text;

  const start = candidate.indexOf("{");
  const end = candidate.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;

  return candidate.slice(start, end + 1);
}

/** Réponse illisible : distinguée d'un échec réseau, qui, lui, se réessaie. */
export class JsonAnswerError extends Error {
  constructor(
    message: string,
    readonly rawResponse: string,
  ) {
    super(message);
    this.name = "JsonAnswerError";
  }
}

/**
 * Pose une question au modèle et rend l'objet JSON de sa réponse.
 *
 * `validate` est la frontière entre « le modèle a répondu » et « la réponse est
 * exploitable » : elle reçoit du `unknown` et rend la forme attendue, ou `null`
 * si la réponse ne tient pas. Rien ne sort d'ici sans être passé par elle.
 */
export async function askJson<T>(args: {
  prompt: string;
  ctx: ModelCallContext;
  validate: (parsed: unknown) => T | null;
  outputSchema?: ModelOutputSchema;
  maxTokens?: number;
}): Promise<T> {
  const result = await callModel({
    parts: [textPart(args.prompt)],
    ctx: args.ctx,
    outputSchema: args.outputSchema,
    maxTokens: args.maxTokens,
  });

  const raw = result.text.trim();
  const json = extractJsonObject(raw);
  if (json === null) {
    throw new JsonAnswerError("aucun objet JSON dans la réponse du moteur", raw);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    throw new JsonAnswerError(
      `JSON invalide : ${err instanceof Error ? err.message : String(err)}`,
      raw,
    );
  }

  const validated = args.validate(parsed);
  if (validated === null) {
    throw new JsonAnswerError("réponse JSON de forme inattendue", raw);
  }
  return validated;
}
