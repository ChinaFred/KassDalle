/**
 * Dans quel sens est la page — bac à sable.
 *
 * Le redressement met la page à plat, il ne la met pas à l'endroit. Les quatre
 * coins rendus par le modèle décident quel côté devient le haut, et rien ne
 * garantit que ce soit le bon : une photo prise en tournant autour du livre, ou
 * une page cadrée en partant d'un autre coin, sort la tête en bas.
 *
 * ## Pourquoi le modèle, encore
 *
 * Distinguer 0° de 90° se ferait sans lui : les lignes de texte d'une page
 * droite se projettent en un peigne régulier sur l'axe vertical, et en rien du
 * tout sur l'horizontal. Mais **0° et 180° donnent exactement le même peigne**.
 * Séparer une page à l'endroit d'une page à l'envers demande de LIRE, et aucune
 * mesure de pixels ne lit.
 *
 * La rotation, elle, reste au programme, et elle ne coûte rien : un quart de
 * tour est une permutation de pixels, sans interpolation ni perte.
 */

import { askModel, type SandboxModelChoice } from "./model";
import type { SandboxEngine } from "./page";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";

/** Rotation à appliquer, en degrés dans le sens des aiguilles d'une montre. */
export type Rotation = 0 | 90 | 180 | 270;

export interface DetectedOrientation {
  rotation: Rotation;
  /** Ce qui a permis de trancher, en une phrase. */
  note: string;
  confidence: number;
  engines: SandboxEngine[];
}

const ROTATIONS: readonly number[] = [0, 90, 180, 270];

const ORIENTATION_PROMPT = String.raw`
TÂCHE : dire de combien il faut tourner cette image pour que la page soit à
l'endroit.

CE QUE TU REGARDES est une page déjà mise à plat : un livre, un magazine, une
feuille. Elle peut être à l'endroit, couchée sur un côté, ou complètement à
l'envers.

LA QUESTION, très précisément : de combien de degrés faut-il tourner cette
image DANS LE SENS DES AIGUILLES D'UNE MONTRE pour qu'on puisse la lire
normalement ?

Quatre réponses possibles, et seulement quatre : 0, 90, 180, 270.

- 0   : la page est déjà à l'endroit, le texte se lit de gauche à droite.
- 90  : le texte se lit de bas en haut. Le haut de la page est à GAUCHE de
        l'image. Un quart de tour horaire le remet en haut.
- 180 : la page est à l'envers, le texte est retourné.
- 270 : le texte se lit de haut en bas. Le haut de la page est à DROITE de
        l'image.

MÉTHODE, dans cet ordre :
1. Trouve du texte — un titre, un paragraphe, une légende, un numéro de page.
   Décris dans "observed" ce que tu as trouvé et dans quel sens il court.
2. Déduis-en la rotation. C'est le SENS DE LECTURE qui tranche, pas la forme de
   la page : une page plus large que haute peut très bien être à l'endroit.
3. S'il n'y a aucun texte lisible, sers-toi de ce que montrent les images —
   une assiette se regarde d'au-dessus, un plat posé sur une table a un haut et
   un bas — et baisse ta confiance en conséquence.

ATTENTION au piège le plus fréquent : 0 et 180 se ressemblent tant qu'on ne lit
pas. Une page à l'envers a exactement la même allure qu'une page à l'endroit :
mêmes blocs, mêmes marges, mêmes photos. Il faut regarder les LETTRES.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier.
{"observed":"le titre « Gravlax » et le texte de la recette courent de gauche à droite, le numéro de page est en bas","rotation":0,"confidence":0.95}
`;

function extractJsonObject(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  return match ? match[0] : cleaned;
}

/**
 * Dit de combien tourner la page, ou `null` si la réponse est illisible.
 *
 * `null` n'est pas 0° : ne rien savoir et savoir qu'il n'y a rien à faire sont
 * deux états différents, et l'écran doit pouvoir les distinguer.
 */
export async function detectOrientation(args: {
  bytes: Buffer;
  mimeType: string;
  widthPx?: number;
  heightPx?: number;
  ctx: ModelCallContext;
  choice: SandboxModelChoice | null;
}): Promise<DetectedOrientation | null> {
  const { bytes, mimeType, widthPx, heightPx, ctx, choice } = args;

  const entete =
    widthPx && heightPx
      ? `L'image mesure ${widthPx} pixels de large et ${heightPx} de haut.\n\n`
      : "";

  const { result, requested } = await askModel({
    parts: [filePart(mimeType, bytes), textPart(entete + ORIENTATION_PROMPT)],
    ctx: { ...ctx, timeoutMs: 60_000, effort: "high" },
    choice,
  });

  const text = result.text.trim();

  const engines: SandboxEngine[] = [
    {
      stage: "sandbox_detect_orientation",
      provider: result.provider,
      model: result.model,
      ...(requested ? { requested } : {}),
    },
  ];

  await logAiText({
    stage: "sandbox_detect_orientation",
    text,
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: ctx.feature,
    provider: result.provider,
    model: result.model,
    moduleType: "DESIGN",
  });

  let parsed: unknown;
  try {
    parsed = JSON.parse(extractJsonObject(text));
  } catch (err) {
    await logError({
      message: "Bac à sable : réponse d'orientation illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
    });
    return null;
  }

  const source = parsed as Record<string, unknown>;
  const raw = Number(source?.rotation);
  if (!ROTATIONS.includes(raw)) return null;

  const confidence = Number(source?.confidence);
  return {
    rotation: raw as Rotation,
    note: String(source?.observed ?? "").slice(0, 240),
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    engines,
  };
}
