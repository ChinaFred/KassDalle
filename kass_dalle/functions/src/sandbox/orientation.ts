/**
 * Dans quel sens est la page — bac à sable.
 *
 * Le redressement met la page à plat, il ne la met pas à l'endroit. Les quatre
 * coins rendus par le modèle décident quel côté devient le haut, et rien ne
 * garantit que ce soit le bon.
 *
 * ## La question a été reformulée, et c'est tout le sujet
 *
 * On demandait d'abord : « de combien de degrés faut-il tourner cette image ? »
 * Le modèle a répondu « zéro » avec 98 % de confiance devant une page couchée,
 * en décrivant un texte horizontal qui ne l'était pas. Ce n'est pas de la
 * distraction : on lui demandait de faire tourner une image dans sa tête, puis
 * de décrire le résultat. C'est du raisonnement spatial, et c'est exactement ce
 * qu'un modèle fait le moins bien — le même défaut que les quatre coins libres,
 * deux étapes plus haut.
 *
 * On lui envoie maintenant **une planche des quatre orientations**, marquées A,
 * B, C et D, et on demande : « dans laquelle sais-tu lire ? » Plus rien à faire
 * tourner, plus de degrés à calculer. De la reconnaissance, ce qu'il fait le
 * mieux.
 *
 * Le programme garde toute la géométrie : c'est lui qui compose la planche, lui
 * qui sait quelle lettre porte quelle rotation, et lui qui l'applique. Le
 * serveur ne connaît même pas les degrés — il rend une lettre.
 */

import { askModel, type SandboxModelChoice } from "./model";
import type { SandboxEngine } from "./page";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";

/** La case retenue sur la planche des quatre orientations. */
export type SheetChoice = "A" | "B" | "C" | "D";

/** Sur quoi le modèle s'est appuyé pour trancher. */
export type OrientationBasis = "texte" | "image" | "mise_en_page" | "aucun";

export interface DetectedOrientation {
  choice: SheetChoice;
  basis: OrientationBasis;
  /** Ce qui a permis de trancher, en une phrase. */
  note: string;
  confidence: number;
  engines: SandboxEngine[];
}

const CHOICES: readonly string[] = ["A", "B", "C", "D"];
const BASES: readonly string[] = ["texte", "image", "mise_en_page", "aucun"];

const ORIENTATION_PROMPT = String.raw`
TÂCHE : dire laquelle de ces quatre pages est à l'endroit.

CE QUE TU REGARDES est une planche de quatre cases, marquées A en haut à
gauche, B en haut à droite, C en bas à gauche et D en bas à droite. Chaque
lettre est écrite dans le bandeau blanc au-dessus de sa case.

Les quatre cases montrent **la même page**, tournée différemment. Une seule est
à l'endroit. Dis laquelle.

TROIS INDICES, dans cet ordre de fiabilité. Prends le premier qui répond.

**1. LE TEXTE** — l'indice le plus sûr. "basis" vaut "texte".
Dans une seule des quatre cases, le texte se lit normalement : les lignes
courent horizontalement, de gauche à droite, et les lettres sont à l'endroit.
Dans les trois autres il est couché ou retourné. Lis un titre, un paragraphe,
une légende, un numéro de page — n'importe quoi de lisible suffit à trancher.

**2. LA GRAVITÉ** — quand la page ne porte que des images. "basis" vaut "image".
Une photographie montre un monde qui obéit à la pesanteur. Dans la bonne case :
- ce qui REPOSE sur quoi est cohérent. Une assiette repose sur une table, un
  verre sur une nappe ; le support est EN DESSOUS de ce qu'il porte.
- les ombres portées tombent vers le bas, et l'objet touche son ombre par le bas.
- le liquide occupe le FOND d'un verre ou d'une assiette creuse, jamais le haut.
- une table photographiée en biais s'éloigne vers le HAUT de la case ; son bord
  proche est en bas.
- les mains, les bras, les couverts tenus entrent par le bas ou les côtés.
- une pile se construit du bas vers le haut, et sa base est plus large.

**3. LA MISE EN PAGE** — le dernier recours. "basis" vaut "mise_en_page".
Un numéro de page est en bas. Une légende est sous sa photo. Un titre est
au-dessus de son texte. Ces indices ne séparent pas toujours une page de son
retournement : baisse ta confiance en conséquence.

ATTENTION : deux des quatre cases sont l'exacte symétrie l'une de l'autre —
même structure, mêmes blocs, mêmes marges. Elles ne se distinguent qu'aux
LETTRES, ou à défaut à ce qui repose sur quoi. Ne te fie pas à la forme de la
page : une page plus large que haute peut très bien être à l'endroit.

Si vraiment rien ne tranche, réponds "A" avec une confiance basse et "basis" à
"aucun". La case A est la page telle qu'elle est arrivée : ne rien changer est
moins gênant que de la retourner pour rien.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier. Dans "observed", dis ce que tu as lu ou vu dans la case retenue.
{"observed":"dans la case C le titre « Gravlax » et les paragraphes se lisent normalement de gauche à droite ; dans A ils sont retournés","basis":"texte","choice":"C","confidence":0.95}
`;

function extractJsonObject(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  return match ? match[0] : cleaned;
}

/**
 * Dit quelle case de la planche est à l'endroit, ou `null` si la réponse est
 * illisible.
 *
 * `null` n'est pas « case A » : ne rien savoir et savoir qu'il n'y a rien à
 * faire sont deux états différents, et l'écran doit pouvoir les distinguer.
 */
export async function detectOrientation(args: {
  bytes: Buffer;
  mimeType: string;
  widthPx?: number;
  heightPx?: number;
  ctx: ModelCallContext;
  choice: SandboxModelChoice | null;
}): Promise<DetectedOrientation | null> {
  const { bytes, mimeType, ctx, choice } = args;

  const { result, requested } = await askModel({
    parts: [filePart(mimeType, bytes), textPart(ORIENTATION_PROMPT)],
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
  const picked = String(source?.choice ?? "")
    .trim()
    .toUpperCase();
  if (!CHOICES.includes(picked)) return null;

  const basisValue = String(source?.basis ?? "").toLowerCase();
  const confidence = Number(source?.confidence);

  return {
    choice: picked as SheetChoice,
    basis: (BASES.includes(basisValue) ? basisValue : "aucun") as OrientationBasis,
    note: String(source?.observed ?? "").slice(0, 240),
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    engines,
  };
}
