/**
 * Où commence et où s'arrête la page — bac à sable.
 *
 * ## Ce qui a été essayé avant
 *
 * Deux méthodes sans modèle ont échoué. La première cherchait un gradient
 * franc : sur une page imprimée, la première transition rencontrée est une
 * ligne de texte. La seconde épluchait les couches en mesurant clarté,
 * saturation et densité de contours : elle rendait la serviette posée sous le
 * livre, et chaque réglage qui corrigeait un cas en cassait un autre.
 *
 * Savoir où s'arrête une page est une question de sens, pas de pixels. Un
 * humain ne mesure rien : il reconnaît une page. Seul un modèle multimodal
 * sait faire ça.
 *
 * ## Pourquoi deux passes
 *
 * Demander d'emblée quatre coins libres rendait un rectangle horizontal, plus
 * petit que la page, qui ne correspondait à aucun objet. Ce n'est pas un défaut
 * d'attention : un modèle est bien meilleur pour encadrer une chose que pour en
 * placer les quatre sommets. Sommé de rendre des coins, il rend quand même une
 * boîte — mal.
 *
 * On lui demande donc ce qu'il sait faire, deux fois de suite :
 *
 * 1. **La boîte.** Où est la page dans la photo, en rectangle droit. C'est la
 *    question sémantique : distinguer le papier de ce qui est posé dessous.
 * 2. **Les coins.** On recadre sur cette boîte, marge comprise, et on redemande
 *    les quatre sommets. La page remplit alors le cadre : placer ses coins
 *    devient une question locale, et non plus un repérage dans une scène.
 *
 * Les coordonnées de la seconde passe sont ramenées dans le repère de l'image
 * entière avant d'être rendues. L'appelant ne voit qu'un quadrilatère.
 */

import { askModel, type SandboxModelChoice } from "./model";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";

/** Un coin, en repère normalisé 0-1000, dans l'ordre [y, x]. */
export type Corner = [number, number];

/** Haut-gauche, haut-droit, bas-droit, bas-gauche — dans cet ordre. */
export type Quad = [Corner, Corner, Corner, Corner];

/** Boîte droite `[yMin, xMin, yMax, xMax]`, en 0-1000. */
export type Box = [number, number, number, number];

/** Ce que le modèle dit avoir cadré. */
export type PageKind = "page" | "double_page" | "feuille" | "autre";

/** Le moteur qui a répondu à une passe, tel qu'il a répondu. */
export interface SandboxEngine {
  stage: string;
  provider: string;
  model: string;
  /** Ce que la politique demandait, quand un repli a servi autre chose. */
  requested?: string;
}

export interface DetectedPage {
  quad: Quad;
  kind: PageKind;
  /** Confiance du modèle, entre 0 et 1. */
  confidence: number;
  /** Ce qu'il a vu, en une phrase. Sert à comprendre un cadrage douteux. */
  note: string;
  /** `true` si la seconde passe a échoué et que la boîte a servi de repli. */
  fromBoxOnly: boolean;
  /** Les moteurs réellement appelés, une entrée par passe. */
  engines: SandboxEngine[];
}

const KINDS: readonly PageKind[] = ["page", "double_page", "feuille", "autre"];

/** Marge ajoutée autour de la boîte avant le gros plan, en part de la boîte. */
const CROP_MARGIN = 0.08;

const BOX_PROMPT = String.raw`
TÂCHE : encadrer la PAGE photographiée, d'un rectangle droit.

CE QUE TU REGARDES est une photographie prise à main levée. Quelqu'un a posé un
livre, un magazine ou une feuille quelque part, et l'a photographié.

CE QU'IL FAUT ENCADRER — le papier porteur du contenu, ENTIER :
- une page simple d'un livre ou d'un magazine → "page" ;
- les DEUX pages d'un livre ouvert, prises ensemble → "double_page" ;
- une feuille volante, imprimée ou manuscrite → "feuille".

Le rectangle contient la page TOUT ENTIÈRE : ses quatre bords, ses marges
blanches, et tout ce qui est imprimé dessus — les photos comme le texte. Si la
page est de travers, le rectangle droit qui la contient déborde forcément un peu
sur les côtés : c'est normal et c'est voulu. Mieux vaut un peu trop large que
trop court.

CE QU'IL NE FAUT PAS ENCADRER — et c'est là que tout se joue :
- **ce qui est SOUS le livre** : une serviette, un torchon, une nappe, un
  sous-main, un plateau. Ces choses sont souvent claires, rectangulaires et plus
  grandes que le livre. Elles ressemblent à du papier. Elles n'en sont pas :
  rien n'est imprimé dessus, et le livre est POSÉ DESSUS.
- **ce qui est AUTOUR** : la table, le canapé, le bureau, le sol, une main, un
  clavier, l'ombre du photographe.
- **une PARTIE de la page** : ni la seule photo du plat, ni le seul bloc de
  texte. La page est un tout, et le rectangle va d'un bord du papier à l'autre.

MÉTHODE, dans cet ordre :
1. Décris ce que tu vois : quel objet porte le contenu, ce qu'il y a dessous,
   ce qu'il y a autour. Écris-le dans "observed".
2. Repère le bord HAUT du papier, puis le bord BAS, puis le GAUCHE, puis le
   DROIT. Chacun est une transition entre le papier et autre chose.
3. Le rectangle est celui qui contient ces quatre bords.

COORDONNÉES :
  • le HAUT de l'image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • la boîte s'écrit [y_min, x_min, y_max, x_max] — la VERTICALE D'ABORD.

Des entiers de 0 à 1000. Ni pixels, ni pourcentages, ni valeurs entre 0 et 1.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier.
{"observed":"double page d'un magazine de cuisine posée sur un torchon blanc, le tout sur un canapé gris","box":[110,180,880,760],"kind":"double_page","confidence":0.9}

Si aucune page n'est visible :
{"observed":"…","box":null,"kind":"autre","confidence":0}
`;

const CORNERS_PROMPT = String.raw`
TÂCHE : donner les quatre coins du papier dans ce gros plan.

CE QUE TU REGARDES est un recadrage serré autour d'une page déjà repérée. La
page occupe l'essentiel du cadre ; il reste une petite marge de décor tout
autour — le support sur lequel elle est posée, et ce qu'il y a plus loin.

Ton travail n'est plus de trouver la page : elle est là, devant toi. Il est de
placer ses QUATRE SOMMETS, au pixel près.

La page est photographiée de biais : c'est un QUADRILATÈRE, pas un rectangle.
Ses côtés opposés n'ont ni la même longueur ni la même inclinaison. Ne rends
JAMAIS un rectangle droit — s'il l'était, tes quatre coins auraient deux à deux
la même verticale et la même horizontale, et ce n'est presque jamais le cas.

Suis le bord du papier, coin par coin :
- coin haut-gauche : là où le bord haut rencontre le bord gauche ;
- coin haut-droit, puis bas-droit, puis bas-gauche.

Le coin est sur le PAPIER, pas dans la marge de décor autour. S'il y a une
ombre portée le long d'un bord, le coin est du côté du papier, pas de l'ombre.

COORDONNÉES, dans le repère de CE gros plan :
  • le HAUT de cette image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • chaque coin s'écrit [y, x] — la VERTICALE D'ABORD.

Ordre : haut-gauche, haut-droit, bas-droit, bas-gauche — le sens des aiguilles
d'une montre en partant du coin supérieur gauche DU PAPIER, et non de l'image.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier.
{"observed":"la page penche vers la droite, son coin bas-gauche est le plus bas","quad":[[40,60],[55,930],[960,910],[945,35]],"confidence":0.9}
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

function parseBox(raw: unknown): Box | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const values = raw.map(clamp1000);
  if (values.some((v) => v === null)) return null;
  const [yMin, xMin, yMax, xMax] = values as number[];
  if (yMax - yMin < 40 || xMax - xMin < 40) return null;
  return [yMin, xMin, yMax, xMax];
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

async function askJson(args: {
  bytes: Buffer;
  mimeType: string;
  prompt: string;
  header: string;
  stage: string;
  ctx: ModelCallContext;
  choice: SandboxModelChoice | null;
  /** Rempli avec le moteur qui a RÉELLEMENT répondu, pour l'écran. */
  engines: SandboxEngine[];
}): Promise<Record<string, unknown> | null> {
  const { bytes, mimeType, prompt, header, stage, ctx, choice, engines } = args;

  const { result, requested } = await askModel({
    parts: [filePart(mimeType, bytes), textPart(header + prompt)],
    ctx: { ...ctx, timeoutMs: 60_000, effort: "high" },
    choice,
  });

  // Le moteur est relevé sur la RÉPONSE, pas sur la demande. Un repli
  // automatique change de fournisseur en cours de route : la configuration
  // dirait alors une chose, et l'appel en aurait fait une autre.
  engines.push({
    stage,
    provider: result.provider,
    model: result.model,
    ...(requested ? { requested } : {}),
  });

  const text = result.text.trim();

  await logAiText({
    stage,
    text,
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: ctx.feature,
    provider: result.provider,
    model: result.model,
    moduleType: "DESIGN",
  });

  try {
    return JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
  } catch (err) {
    await logError({
      message: `Bac à sable : réponse illisible à l'étape « ${stage} »`,
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
    });
    return null;
  }
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
  /** Le modèle imposé par l'expérience, `null` pour suivre la politique. */
  choice: SandboxModelChoice | null;
}): Promise<DetectedPage | null> {
  const { bytes, mimeType, widthPx, heightPx, ctx, choice } = args;

  const engines: SandboxEngine[] = [];

  const header =
    widthPx && heightPx
      ? `L'image mesure ${widthPx} pixels de large et ${heightPx} de haut.\n\n`
      : "";

  // ── Passe 1 : la boîte ────────────────────────────────────────────────────
  const first = await askJson({
    bytes,
    mimeType,
    prompt: BOX_PROMPT,
    header,
    stage: "sandbox_detect_page_box",
    choice,
    engines,
    ctx,
  });
  if (!first) return null;

  const box = parseBox(first.box);
  if (!box) return null;

  const kindValue = String(first.kind ?? "").toLowerCase();
  const kind: PageKind = (KINDS as readonly string[]).includes(kindValue)
    ? (kindValue as PageKind)
    : "autre";
  const boxConfidence = Number(first.confidence);
  const note = String(first.observed ?? "").slice(0, 240);

  // ── Le gros plan ──────────────────────────────────────────────────────────
  const [yMin, xMin, yMax, xMax] = box;
  const marginY = (yMax - yMin) * CROP_MARGIN;
  const marginX = (xMax - xMin) * CROP_MARGIN;
  const cropTop = Math.max(0, yMin - marginY);
  const cropLeft = Math.max(0, xMin - marginX);
  const cropBottom = Math.min(1000, yMax + marginY);
  const cropRight = Math.min(1000, xMax + marginX);

  const boxQuad: Quad = [
    [yMin, xMin],
    [yMin, xMax],
    [yMax, xMax],
    [yMax, xMin],
  ];

  const fallback = (): DetectedPage => ({
    quad: boxQuad,
    kind,
    confidence: Number.isFinite(boxConfidence) ? Math.min(1, Math.max(0, boxConfidence)) : 0,
    note,
    fromBoxOnly: true,
    engines,
  });

  let cropBuffer: Buffer;
  let cropWidth = 0;
  let cropHeight = 0;
  try {
    // Import dynamique : le SDK est lourd, et ce module est chargé au
    // démarrage de toutes les fonctions du paquet.
    const { default: sharp } = await import("sharp");
    const image = sharp(bytes);
    const meta = await image.metadata();
    const fullWidth = meta.width ?? 0;
    const fullHeight = meta.height ?? 0;
    if (fullWidth === 0 || fullHeight === 0) return fallback();

    const left = Math.round((cropLeft / 1000) * fullWidth);
    const top = Math.round((cropTop / 1000) * fullHeight);
    const width = Math.max(16, Math.round(((cropRight - cropLeft) / 1000) * fullWidth));
    const height = Math.max(16, Math.round(((cropBottom - cropTop) / 1000) * fullHeight));

    cropBuffer = await image
      .extract({
        left: Math.min(left, fullWidth - 16),
        top: Math.min(top, fullHeight - 16),
        width: Math.min(width, fullWidth - left),
        height: Math.min(height, fullHeight - top),
      })
      .jpeg({ quality: 92 })
      .toBuffer();
    const cropMeta = await sharp(cropBuffer).metadata();
    cropWidth = cropMeta.width ?? 0;
    cropHeight = cropMeta.height ?? 0;
  } catch (err) {
    await logError({
      message: "Bac à sable : recadrage impossible avant la passe des coins",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
    });
    return fallback();
  }

  // ── Passe 2 : les coins ───────────────────────────────────────────────────
  const second = await askJson({
    bytes: cropBuffer,
    mimeType: "image/jpeg",
    prompt: CORNERS_PROMPT,
    header:
      cropWidth && cropHeight
        ? `Ce gros plan mesure ${cropWidth} pixels de large et ${cropHeight} de haut.\n\n`
        : "",
    stage: "sandbox_detect_page_corners",
    choice,
    engines,
    ctx,
  });
  if (!second) return fallback();

  const cropQuad = parseQuad(second.quad);
  if (!cropQuad) return fallback();

  // Retour dans le repère de l'image entière.
  const spanY = cropBottom - cropTop;
  const spanX = cropRight - cropLeft;
  const quad = cropQuad.map(([y, x]) => [
    Math.round(cropTop + (y / 1000) * spanY),
    Math.round(cropLeft + (x / 1000) * spanX),
  ]) as Quad;

  // Un quadrilatère qui couvre 2 % de l'image, ou 99,5 %, n'est pas une page :
  // c'est un détail attrapé au passage, ou le cadre entier rendu par défaut.
  const area = quadArea(quad);
  if (area < 20_000 || area > 995_000) return fallback();

  const cornersConfidence = Number(second.confidence);
  const secondNote = String(second.observed ?? "").slice(0, 160);

  return {
    quad,
    kind,
    confidence: Number.isFinite(cornersConfidence)
      ? Math.min(1, Math.max(0, cornersConfidence))
      : 0,
    note: secondNote ? `${note} — ${secondNote}` : note,
    fromBoxOnly: false,
    engines,
  };
}
