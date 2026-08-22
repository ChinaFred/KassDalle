/**
 * Où commence et où s'arrête la page — bac à sable.
 *
 * Deux méthodes ont été essayées avant celle-ci, et toutes deux ont échoué
 * pour la même raison.
 *
 * La première cherchait un gradient : le bord du document devait être la
 * première transition franche rencontrée. Sur une page imprimée, la première
 * transition est une ligne de texte.
 *
 * La seconde cherchait ce qui se détache du fond, couche par couche, en
 * mesurant clarté, saturation et densité de contours. Elle rendait la
 * serviette posée sous le livre — ou le sous-main, ou la nappe. Chaque réglage
 * qui corrigeait un cas en cassait un autre : un livre sur un bureau clair, une
 * feuille volante sur du bois, une double page sans rien dessous.
 *
 * Le point commun : **savoir où s'arrête une page est une question de sens, pas
 * de pixels.** Un humain ne mesure ni la saturation ni les contours ; il
 * reconnaît une page. C'est exactement ce qu'un modèle multimodal sait faire,
 * et rien d'autre dans la boîte à outils ne le sait.
 *
 * La géométrie, elle, reste au programme : le modèle rend quatre coins,
 * l'homographie fait le reste, à pleine résolution et en une seule
 * interpolation.
 */

import { callModel } from "../ai/router";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";

/** Un coin, en repère normalisé 0-1000, dans l'ordre [y, x]. */
export type Corner = [number, number];

/** Haut-gauche, haut-droit, bas-droit, bas-gauche — dans cet ordre. */
export type Quad = [Corner, Corner, Corner, Corner];

/** Ce que le modèle dit avoir cadré. */
export type PageKind = "page" | "double_page" | "feuille" | "autre";

export interface DetectedPage {
  quad: Quad;
  kind: PageKind;
  /** Confiance du modèle, entre 0 et 1. */
  confidence: number;
  /** Ce qu'il a vu, en une phrase. Sert à comprendre un cadrage douteux. */
  note: string;
}

const KINDS: readonly PageKind[] = ["page", "double_page", "feuille", "autre"];

const PAGE_PROMPT = String.raw`
TÂCHE : donner les quatre coins de la PAGE photographiée.

CE QUE TU REGARDES est une photographie prise à main levée. Quelqu'un a posé un
livre, un magazine ou une feuille quelque part, et l'a photographié. La page est
donc de travers, et il y a du décor autour.

CE QU'IL FAUT CADRER — le papier porteur du contenu, et lui seul :
- une page simple d'un livre ou d'un magazine → "page" ;
- les DEUX pages d'un livre ouvert, prises ensemble en un seul quadrilatère →
  "double_page" ;
- une feuille volante, imprimée ou manuscrite → "feuille".

CE QU'IL NE FAUT PAS CADRER — et c'est là que tout se joue :
- **ce qui est SOUS le livre** : une serviette, un torchon, une nappe, un
  sous-main, un plateau. Ces choses sont souvent claires, rectangulaires et
  plus grandes que le livre. Elles ressemblent à du papier. Elles n'en sont
  pas : rien n'est imprimé dessus, et le livre est POSÉ DESSUS. Ton cadre doit
  s'arrêter au bord du livre, pas au bord de ce qui le porte.
- **ce qui est AUTOUR** : la table, le canapé, le bureau, le sol, une main, un
  clavier, l'ombre du photographe.
- **ce qui est DANS la page** : une photographie imprimée, un dessin, un
  encadré. Ils font partie de la page ; ils ne sont pas la page.
- la tranche du livre, la couverture repliée sous la page, la page d'en face
  quand elle est franchement séparée et qu'une seule est photographiée.

MÉTHODE :
1. Trouve d'abord le CONTENU : le texte imprimé, les photos de la recette, les
   titres. C'est lui qui est sur la page.
2. Remonte jusqu'aux bords du papier qui le porte, marges comprises.
3. Vérifie que ce que tu cadres porte bien du contenu jusqu'à ses bords, à la
   marge près. Si ton cadre englobe une large bande vide et lisse, tu as
   attrapé le support : resserre.

COORDONNÉES — lis ceci en entier.

Repère NORMALISÉ, indépendant de la taille réelle de l'image :
  • le HAUT de l'image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • chaque coin s'écrit [y, x] — la VERTICALE D'ABORD.

Ni pixels, ni pourcentages, ni valeurs entre 0 et 1 : des entiers de 0 à 1000.

LES QUATRE COINS, PAS UN RECTANGLE. La page est photographiée de biais : c'est
un QUADRILATÈRE. Donne ses quatre coins réels, dans l'ordre haut-gauche,
haut-droit, bas-droit, bas-gauche — le sens des aiguilles d'une montre en
partant du coin supérieur gauche DE LA PAGE, et non de l'image. Ne redresse
rien toi-même, ne devine pas un rectangle : donne les coins tels que tu les
VOIS. C'est le programme qui redressera, et il le fera d'autant mieux que tes
coins collent au papier.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication.
{"quad":[[y,x],[y,x],[y,x],[y,x]],"kind":"page","confidence":0.9,"note":"page droite d'un magazine, posée sur un torchon clair"}

Si aucune page n'est visible :
{"quad":null,"kind":"autre","confidence":0,"note":"pourquoi"}
`;

/** Extrait le premier objet JSON d'une réponse de modèle. */
function extractJsonObject(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  return match ? match[0] : cleaned;
}

function clamp1000(value: unknown): number | null {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.min(1000, Math.max(0, Math.round(n)));
}

function parseQuad(raw: unknown): Quad | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const corners: Corner[] = [];
  for (const corner of raw) {
    if (!Array.isArray(corner) || corner.length !== 2) return null;
    const y = clamp1000(corner[0]);
    const x = clamp1000(corner[1]);
    if (y === null || x === null) return null;
    corners.push([y, x]);
  }
  return corners as Quad;
}

/** Aire du quadrilatère, dans le repère 0-1000 — un million pour la page pleine. */
function quadArea(quad: Quad): number {
  let sum = 0;
  for (let i = 0; i < 4; i++) {
    const [y1, x1] = quad[i];
    const [y2, x2] = quad[(i + 1) % 4];
    sum += x1 * y2 - x2 * y1;
  }
  return Math.abs(sum) / 2;
}

/**
 * Donne les quatre coins de la page photographiée, ou `null` s'il n'y en a pas.
 *
 * Le `null` est une réponse, pas une panne : une photo sans page est un cas
 * normal, et l'appelant a de quoi le dire à l'utilisateur.
 */
export async function detectPageQuad(args: {
  bytes: Buffer;
  mimeType: string;
  widthPx?: number;
  heightPx?: number;
  ctx: ModelCallContext;
}): Promise<DetectedPage | null> {
  const { bytes, mimeType, widthPx, heightPx, ctx } = args;

  const entete =
    widthPx && heightPx
      ? `L'image mesure ${widthPx} pixels de large et ${heightPx} de haut.\n\n`
      : "";

  const result = await callModel({
    parts: [filePart(mimeType, bytes), textPart(entete + PAGE_PROMPT)],
    ctx: { ...ctx, timeoutMs: 60_000, effort: "high" },
  });

  const text = result.text.trim();

  await logAiText({
    stage: "sandbox_detect_page",
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
      message: "Bac à sable : réponse de cadrage de page illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
    });
    return null;
  }

  const source = parsed as Record<string, unknown>;
  const quad = parseQuad(source?.quad);
  if (!quad) return null;

  // Une page qui couvre 2 % de l'image, ou 99 %, n'est pas une page : c'est un
  // détail attrapé au passage, ou le cadre entier rendu par défaut.
  const area = quadArea(quad);
  if (area < 20_000 || area > 995_000) return null;

  const kindValue = String(source?.kind ?? "").toLowerCase();
  const confidence = Number(source?.confidence);

  return {
    quad,
    kind: (KINDS as readonly string[]).includes(kindValue) ? (kindValue as PageKind) : "autre",
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    note: String(source?.note ?? "").slice(0, 200),
  };
}
