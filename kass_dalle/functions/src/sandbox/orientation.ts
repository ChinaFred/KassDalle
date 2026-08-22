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

/** Sur quoi le modèle s'est appuyé pour trancher. */
export type OrientationBasis = "texte" | "image" | "mise_en_page" | "aucun";

export interface DetectedOrientation {
  rotation: Rotation;
  basis: OrientationBasis;
  /** Ce qui a permis de trancher, en une phrase. */
  note: string;
  confidence: number;
  engines: SandboxEngine[];
}

const ROTATIONS: readonly number[] = [0, 90, 180, 270];
const BASES: readonly string[] = ["texte", "image", "mise_en_page", "aucun"];

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

TROIS INDICES, dans cet ordre de fiabilité. Prends le premier qui répond.

**1. LE TEXTE** — l'indice le plus sûr, quand il y en a. "basis" vaut "texte".
Un titre, un paragraphe, une légende sous une photo, un numéro de page, une
mention légale en petits caractères le long d'un bord. Dis dans quel sens il
court. C'est le SENS DE LECTURE qui tranche, pas la forme de la page : une page
plus large que haute peut très bien être à l'endroit.

**2. LA GRAVITÉ** — quand la page ne porte que des images. "basis" vaut "image".
Une photographie a un haut et un bas, et le monde qu'elle montre obéit à la
pesanteur. Cherche :
- ce qui REPOSE sur quoi. Une assiette repose sur une table, un verre sur une
  nappe, un gâteau sur un plat. Le support est EN DESSOUS de ce qu'il porte.
- les ombres portées. Elles tombent du côté opposé à la lumière, et l'objet
  touche sa propre ombre par le bas.
- le liquide. Il occupe le FOND d'un verre, d'une casserole, d'une assiette
  creuse — jamais le haut.
- la perspective d'une table photographiée en biais : elle s'éloigne vers le
  HAUT de l'image. Le bord proche de la table est en bas.
- les mains, les bras, les couverts tenus : ils entrent par le bas ou les côtés,
  presque jamais par le haut.
- une pile — de crêpes, de tranches, de livres — se construit du bas vers le
  haut, et sa base est plus large.

**3. LA MISE EN PAGE** — le dernier recours. "basis" vaut "mise_en_page".
Un numéro de page et une signature de bas de page sont EN BAS. Une légende est
sous sa photo. Un titre est au-dessus de son texte. Une marge de reliure est sur
un côté, jamais en haut ni en bas. Ces indices ne séparent pas toujours 0 de
180 : baisse ta confiance en conséquence.

Si vraiment rien ne tranche, réponds une rotation de 0 avec une confiance basse et
"basis" à "aucun". Ne devine pas au hasard : une page laissée droite est moins
gênante qu'une page retournée pour rien.

ATTENTION au piège le plus fréquent : **0 et 180 se ressemblent** tant qu'on ne
regarde que la structure. Une page à l'envers a exactement la même allure qu'une
page à l'endroit — mêmes blocs, mêmes marges, mêmes photos. Il faut regarder les
LETTRES, ou à défaut ce qui repose sur quoi. Compter les blocs ne suffit jamais.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier. Dans "observed", nomme l'indice qui a tranché.
{"observed":"aucun texte lisible ; les deux assiettes reposent sur une planche de bois dont le bord proche est en bas de l'image, et l'ombre du plat tombe vers le bas","basis":"image","rotation":0,"confidence":0.8}
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

  const basisValue = String(source?.basis ?? "").toLowerCase();
  const confidence = Number(source?.confidence);
  return {
    rotation: raw as Rotation,
    basis: (BASES.includes(basisValue) ? basisValue : "aucun") as OrientationBasis,
    note: String(source?.observed ?? "").slice(0, 240),
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    engines,
  };
}
