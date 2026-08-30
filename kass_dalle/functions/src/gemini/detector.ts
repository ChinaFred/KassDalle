/**
 * Détection de zones photographiques dans une image de recette.
 *
 * Sert l'atelier manuel — le bouton « Extraire les illustrations » de la
 * relecture de brouillon et de l'édition. L'import de pages, lui, a sa propre
 * chaîne dans `illustrations/extract.ts`.
 */

import sharp from "sharp";
import { extractJsonArray } from "./client";
import { callModel } from "../ai/router";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { logAiText, logError } from "../logging";
import { assessCrop, type CropRejection } from "./illustrationQuality";
import { isNearlyRectangular, warpQuadrilateral, type Quad } from "./perspective";

/**
 * Zone détectée : quatre coins dans le repère 0-1000, [y, x] chacun.
 *
 * Dans l'ordre haut-gauche, haut-droit, bas-droit, bas-gauche — l'ordre du sens
 * des aiguilles d'une montre en partant du coin supérieur gauche DE LA PHOTO,
 * pas de l'image. C'est lui qui décide quel côté du résultat sera le haut ;
 * deux coins intervertis donnent une image parfaitement nette et retournée.
 *
 * Un rectangle est un quadrilatère comme un autre : une boîte reçue du modèle
 * devient ses quatre coins, et tout le reste de la chaîne n'a qu'une forme à
 * connaître.
 */
export type DetectedQuad = [[number, number], [number, number], [number, number], [number, number]];

/** Bounding box [yMin, xMin, yMax, xMax] en coordonnées 0-1000. */
export type BBox = [number, number, number, number];

const DETECT_PROMPT = String.raw`
TÂCHE : trouver TOUTES les photographies culinaires dans cette image de livre.

LES TROIS CAS, ET LE PREMIER EST LE PLUS FRÉQUENT :
- UNE SEULE grande photo, occupant une demi-page ou une pleine page — le plat fini.
  Elle compte pour UNE boîte. Ne la découpe pas.
- UNE photo en bandeau, en haut ou en pied de page, plus large que haute.
  Elle compte pour UNE boîte, même si elle traverse toute la largeur.
- UNE GRILLE de vignettes d'étapes. Là, et là seulement, une boîte par case.

MÉTHODE EN 3 ÉTAPES (suis-les rigoureusement) :
1. Balaye l'image et COMPTE le nombre exact de vignettes photographiques distinctes.
   Une grille de 8 vignettes = 8 photos. Une grille 3×3 = 9. Une grille 2×3 = 6.
   Une photo pleine page = 1. Ne cherche pas une grille là où il n'y en a pas.
2. Pour chaque vignette individuelle, repère ses 4 coins.
3. Liste UNE boîte par vignette, dans l'ordre de lecture (gauche→droite, haut→bas).

CE QUE TU REGARDES N'EST PAS UNE PAGE, C'EST UNE PHOTO DE PAGE.

Le livre a été posé sur un bureau et photographié. Autour de la page, il y a
donc du décor qui n'appartient pas au livre : le plateau de la table, un
clavier, une souris, un bord d'écran, une main, l'ombre du photographe, et
souvent la page d'en face. Le livre lui-même est probablement de travers, et
ses bords ne sont pas parallèles à ceux de l'image.

Ta boîte doit contenir la PHOTOGRAPHIE IMPRIMÉE, et rien d'autre :
- pas un centimètre de bureau, de clavier ou de nappe ;
- pas la marge blanche du papier autour de la photo ;
- pas la page voisine, même si elle porte aussi une image ;
- pas la tranche ni la reliure du livre.

Serre le cadre AU BORD de la photographie imprimée. Une boîte trop large est
inutilisable : elle sera publiée telle quelle, décor compris. Si le livre est
de travers, prends la boîte qui contient tout juste la photo inclinée — mieux
vaut deux coins de papier qu'un morceau de table.

RÈGLES ABSOLUES :
- Chaque vignette de la grille = 1 boîte distincte. NE JAMAIS fusionner.
- Une grille NxM contient toujours N×M boîtes (sauf si certaines cellules sont vides).
- Les boîtes ne doivent PAS se chevaucher significativement.
- NE PAS inclure : texte, ingrédients listés, fond blanc, bordures, schémas, icônes.
- Une boîte qui couvre presque toute l'image est presque toujours FAUSSE : sur
  une photo de page prise à main levée, la photographie imprimée occupe rarement
  plus des deux tiers du cadre.

TYPES de photos à détecter :
- Photos d'étapes de préparation (souvent en grille régulière)
- Photo finale du plat
- Photos d'ingrédients mis en scène

COORDONNÉES — lis ceci en entier, c'est la partie qu'on rate.

Repère NORMALISÉ, indépendant de la taille réelle de l'image :
  • le HAUT de l'image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • une boîte s'écrit [y_min, x_min, y_max, x_max], dans CET ordre —
    la verticale D'ABORD.

Exemple : une photo qui occupe la moitié droite de la page, du haut au bas,
s'écrit [0, 500, 1000, 1000]. Une photo pleine page s'écrit [0, 0, 1000, 1000].

Ne réponds ni en pixels, ni en pourcentages, ni entre 0 et 1 : des entiers
entre 0 et 1000.

LES QUATRE COINS, PAS UN RECTANGLE

Le livre est de travers : la photographie imprimée est un QUADRILATÈRE, pas un
rectangle. Donne ses quatre coins réels, dans cet ordre :
  haut-gauche, haut-droit, bas-droit, bas-gauche
— l'ordre du sens des aiguilles d'une montre en partant du coin supérieur
gauche DE LA PHOTO, et non de l'image.

Chaque coin s'écrit [y, x] dans le repère décrit ci-dessus.

Ne redresse rien toi-même, ne devine pas un rectangle : donne les coins tels
que tu les VOIS, de travers s'ils le sont. C'est le programme qui redressera,
et il le fera d'autant mieux que tes coins collent au papier.

RÉPONSE : UNIQUEMENT le tableau JSON, sans markdown ni explication.
Une photo = un groupe de quatre coins :
[[[y,x],[y,x],[y,x],[y,x]], ...] ou [] si aucune photo.
`;

/**
 * Détecte les zones de photos culinaires dans une image de recette.
 *
 * Un appel, un seul. Il y en avait quatre : quand le modèle rendait deux à
 * quatre zones dont une dépassait le quart de la page, une cascade de trois
 * appels supplémentaires cherchait une grille de vignettes qu'il aurait
 * fusionnée — dimensions de la grille, puis seconde passe sur le recadrage,
 * puis relance sur l'image entière.
 *
 * Les compteurs de `ai_usage_monthly` ont tranché : sur quatre mois, la
 * cascade est partie 109 fois, sa première approche a abouti 3 fois et la
 * deuxième 13 fois. Le reste allait jusqu'au dernier repli, dont le résultat
 * était jeté s'il ne rendait pas plus d'une zone. Trois appels sur quatre ne
 * changeaient rien.
 *
 * Le prompt de détection demande déjà une boîte par vignette, et le compte des
 * cases fait partie de ce qu'il énumère. Lui redemander trois fois ne le lui
 * apprend pas.
 */
export async function detectIllustrationRegions(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: ModelCallContext,
): Promise<DetectedQuad[]> {
  return callDetectAndParse(apiKey, bytes, mimeType, DETECT_PROMPT, "detect_illustrations", ctx);
}

async function callDetectAndParse(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  prompt: string,
  feature: string,
  ctx: ModelCallContext,
): Promise<DetectedQuad[]> {
  // Les dimensions servent deux fois : dans le prompt, pour que le modèle sache
  // ce qu'il regarde, et à la lecture, pour convertir une réponse en pixels.
  const meta = await sharp(bytes).metadata();
  const pageWidth = meta.width ?? 0;
  const pageHeight = meta.height ?? 0;
  const entete =
    pageWidth > 0 && pageHeight > 0
      ? `L'image mesure ${pageWidth} pixels de large et ${pageHeight} de haut.

`
      : "";

  let result: Awaited<ReturnType<typeof callModel>>;
  try {
    result = await callModel({
      parts: [filePart(mimeType, bytes), textPart(entete + prompt)],
      // Situer des rectangles dans une image demande du soin, pas de la
      // vitesse. Le réglage par défaut vient de la chaîne nutrition, où deviner
      // des calories ne réclame aucun raisonnement.
      ctx: { ...ctx, feature, timeoutMs: 90_000, effort: "high" },
    });
  } catch (err) {
    // Le `catch` était VIDE, et rendait un tableau de boîtes.
    //
    // Un refus du modèle, un plafond de dépense atteint, un délai dépassé, une
    // réponse illisible : tout se présentait à l'identique sous la forme
    // « aucune photographie détectée ». Impossible de dire si la page n'en
    // portait pas ou si l'appel avait échoué — deux situations qui demandent
    // deux réactions opposées, et la seule règle vraiment stricte de ce projet
    // interdit précisément de les confondre.
    await logError({
      message: "Détection d'illustrations : l'appel au modèle a échoué",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      feature,
    });
    throw err;
  }

  const text = result.text.trim();

  // La réponse brute, toujours. Elle tient en une ligne et tranche la question
  // que rien ne permettait de trancher : le modèle a-t-il regardé et rien vu,
  // ou a-t-il répondu autre chose que ce qu'on attendait ?
  await logAiText({
    stage: "detection.illustrations",
    text,
    message: "Réponse brute du détecteur d'illustrations",
    feature,
    provider: result.provider,
    model: result.model,
    moduleType: "DESIGN",
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
    jobId: ctx.jobId,
    userId: ctx.userId,
  });

  if (!text || text === "[]") return [];

  try {
    const parsed = JSON.parse(extractJsonArray(text));
    if (!Array.isArray(parsed)) throw new Error("La réponse n'est pas un tableau.");

    const boxes: DetectedQuad[] = [];
    for (const entry of parsed) {
      const quad = readQuad(entry, pageWidth, pageHeight);
      if (quad) boxes.push(quad);
    }

    // Une réponse non vide qui ne donne aucune boîte exploitable n'est pas un
    // « aucune photo » : c'est un désaccord de format. Le repère
    // `[y_min, x_min, y_max, x_max]` sur mille est une convention GOOGLE ; un
    // autre moteur ne la connaît pas et répond à côté, sans erreur.
    if (boxes.length === 0) {
      await logError({
        message: "Détection d'illustrations : réponse non vide, aucune boîte exploitable",
        errorDescription: `Moteur ${result.provider} (${result.model}) — format inattendu`,
        moduleType: "DESIGN",
        correlationId: ctx.correlationId,
        jobId: ctx.jobId,
        userId: ctx.userId,
        feature,
        extra: { reponse: text.slice(0, 500) },
      });
    }
    return boxes;
  } catch (err) {
    await logError({
      message: "Détection d'illustrations : réponse illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      feature,
      extra: { provider: result.provider, model: result.model, reponse: text.slice(0, 500) },
    });
    return [];
  }
}

/**
 * Ramène une boîte au repère 0-1000, quelle que soit l'unité employée.
 *
 * Le repère « 0 à 1000 » est la convention native de Gemini, et le prompt la
 * décrivait en une ligne : « entiers 0-1000 ». Cela suffit à un modèle qui l'a
 * apprise, pas à un autre — Claude répond volontiers en pixels, et le résultat
 * ne ressemble à rien une fois interprété comme des millièmes.
 *
 * Le prompt décrit désormais le repère explicitement. Mais décrire ne suffit
 * pas : on accepte AUSSI ce que le modèle rend spontanément, en le convertissant.
 * Trois unités possibles, distinguées par leur ordre de grandeur :
 *
 *  - au-delà de 1000  → des pixels, ramenés avec les dimensions de l'image ;
 *  - au plus 1,5      → un repère 0-1, multiplié par mille ;
 *  - entre les deux   → déjà des millièmes.
 *
 * Sans les dimensions, une valeur en pixels ne se convertit pas : on la borne
 * plutôt que d'inventer un facteur, et le contrôle de qualité écartera une
 * découpe absurde.
 */
export function normalizeBox(vals: number[], pageWidth?: number, pageHeight?: number): BBox {
  const maxVal = Math.max(...vals);

  if (maxVal <= 1.5) {
    const scaled = vals.map((v) => Math.round(v * 1000));
    return [scaled[0], scaled[1], scaled[2], scaled[3]];
  }

  if (maxVal > 1000 && pageWidth && pageHeight) {
    // [y_min, x_min, y_max, x_max] : la verticale se rapporte à la hauteur.
    return [
      Math.round((vals[0] * 1000) / pageHeight),
      Math.round((vals[1] * 1000) / pageWidth),
      Math.round((vals[2] * 1000) / pageHeight),
      Math.round((vals[3] * 1000) / pageWidth),
    ];
  }

  const borne = (v: number) => Math.round(Math.min(Math.max(v, 0), 1000));
  return [borne(vals[0]), borne(vals[1]), borne(vals[2]), borne(vals[3])];
}

function clamp(v: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, v));
}

/**
 * Redresse une image selon son EXIF, et efface l'étiquette d'orientation.
 *
 * C'est la correction du défaut le plus coûteux de cette chaîne : un modèle de
 * vision reçoit l'image telle qu'elle S'AFFICHE — le décodeur applique
 * l'orientation EXIF — et rend donc des coordonnées dans ce repère-là. Sharp,
 * lui, travaille sur la grille de pixels STOCKÉE. Pour une photo prise en
 * portrait avec un capteur paysage — le cas de tout téléphone — les deux
 * repères sont tournés de quatre-vingt-dix degrés l'un par rapport à l'autre.
 *
 * Le découpage tombait alors n'importe où : on demandait le plat et on
 * obtenait un bout de table. Rien ne le signalait, parce que la découpe était
 * techniquement valide — bonne taille, bon rapport de forme, ni blanche ni
 * uniforme. Elle passait les trois filtres et allait se faire refuser à la
 * modération, ou pire, se publiait.
 *
 * Une fois redressée, la même image sert à la détection ET au découpage : les
 * deux repères ne peuvent plus diverger.
 */
export async function uprightImage(bytes: Buffer): Promise<Buffer> {
  return sharp(bytes).rotate().toBuffer();
}

/**
 * Extrait chaque zone détectée, en REDRESSANT quand elle est de travers.
 *
 * Une page photographiée à main levée est un trapèze : le découpage
 * rectangulaire, aussi serré soit-il, garde forcément deux coins de papier et
 * de table. C'est une limite de la forme, qu'aucun cadrage ne lève.
 *
 * Quand la zone est déjà droite — un scan à plat, une capture d'écran — on
 * découpe sans redresser : la transformation ne changerait rien de visible, et
 * le découpage préserve la netteté d'origine sans ré-échantillonner.
 *
 * L'image reçue doit DÉJÀ être redressée en orientation EXIF
 * (`uprightImage`) : les coordonnées viennent d'un modèle qui a vu l'image
 * debout.
 */
export async function cropIllustrations(bytes: Buffer, regions: DetectedQuad[]): Promise<Buffer[]> {
  if (regions.length === 0) return [];
  const meta = await sharp(bytes).metadata();
  const w = meta.width ?? 0;
  const h = meta.height ?? 0;
  if (w === 0 || h === 0) return [];

  const results: Buffer[] = [];
  for (const region of regions) {
    // Du repère 0-1000 aux pixels de cette image-ci.
    const quad = region.map((pt) => ({
      x: clamp((pt[1] * w) / 1000, 0, w),
      y: clamp((pt[0] * h) / 1000, 0, h),
    })) as Quad;

    try {
      if (isNearlyRectangular(quad)) {
        const box = boundingBoxOf(region);
        const left = clamp(Math.floor((box[1] * w) / 1000), 0, w - 1);
        const top = clamp(Math.floor((box[0] * h) / 1000), 0, h - 1);
        const width = clamp(Math.floor(((box[3] - box[1]) * w) / 1000), 1, w - left);
        const height = clamp(Math.floor(((box[2] - box[0]) * h) / 1000), 1, h - top);
        results.push(
          await sharp(bytes).extract({ left, top, width, height }).jpeg({ quality: 88 }).toBuffer(),
        );
        continue;
      }
      results.push(await warpQuadrilateral(bytes, quad));
    } catch (err) {
      // Le redressement peut échouer sur une zone dégénérée — quatre coins
      // alignés, une aire nulle. On retombe sur le rectangle englobant plutôt
      // que de perdre la photo : moins bien cadrée vaut mieux qu'absente, et
      // les filtres de qualité l'écarteront si elle ne vaut rien.
      void logError({
        message: "Redressement d'une illustration impossible, découpe rectangulaire",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
      });
      const box = boundingBoxOf(region);
      const left = clamp(Math.floor((box[1] * w) / 1000), 0, w - 1);
      const top = clamp(Math.floor((box[0] * h) / 1000), 0, h - 1);
      const width = clamp(Math.floor(((box[3] - box[1]) * w) / 1000), 1, w - left);
      const height = clamp(Math.floor(((box[2] - box[0]) * h) / 1000), 1, h - top);
      results.push(
        await sharp(bytes).extract({ left, top, width, height }).jpeg({ quality: 88 }).toBuffer(),
      );
    }
  }
  return results;
}

/** Une découpe retenue, et ce qu'on sait d'elle. */
export interface KeptCrop {
  bytes: Buffer;
  widthPx: number;
  heightPx: number;
}

/** Une découpe écartée, et pourquoi. */
export interface DroppedCrop {
  reason: CropRejection;
  widthPx: number;
  heightPx: number;
}

export interface CropSelection {
  kept: KeptCrop[];
  dropped: DroppedCrop[];
}

/**
 * Découpe, puis écarte ce qui n'est manifestement pas une photographie.
 *
 * Les boîtes viennent d'un modèle : rien ne garantit qu'elles encadrent une
 * photo. Sans ce tri, une boîte fantaisiste produisait une bande de texte,
 * téléversée comme illustration et conservée pour toujours.
 *
 * Le tri est **local** — il ne coûte aucun appel de modèle — et conservateur :
 * il n'écarte que ce dont on est sûr.
 */
export async function cropAndSelectIllustrations(
  bytes: Buffer,
  boxes: DetectedQuad[],
): Promise<CropSelection> {
  const selection: CropSelection = { kept: [], dropped: [] };
  if (boxes.length === 0) return selection;

  const pageMeta = await sharp(bytes).metadata();
  const pageWidthPx = pageMeta.width ?? 0;
  const pageHeightPx = pageMeta.height ?? 0;

  const crops = await cropIllustrations(bytes, boxes);
  for (const crop of crops) {
    const image = sharp(crop);
    const [meta, stats] = await Promise.all([image.metadata(), image.stats()]);
    const widthPx = meta.width ?? 0;
    const heightPx = meta.height ?? 0;

    // Les trois premiers canaux sont R, G, B ; un quatrième, s'il existe, est
    // l'alpha et ne dit rien de la couleur.
    const channels = stats.channels.slice(0, 3);
    const means = channels.map((c) => c.mean);
    const meanLuminance = means.reduce((a, b) => a + b, 0) / (means.length || 1);
    const chroma = means.length < 3 ? 0 : Math.max(...means) - Math.min(...means);

    const verdict = assessCrop({
      widthPx,
      heightPx,
      pageWidthPx,
      pageHeightPx,
      meanLuminance,
      chroma,
    });

    if (verdict.keep) {
      selection.kept.push({ bytes: crop, widthPx, heightPx });
    } else {
      selection.dropped.push({ reason: verdict.reason!, widthPx, heightPx });
    }
  }

  return selection;
}

/**
 * Lit une zone, qu'elle vienne sous forme de boîte ou de quadrilatère.
 *
 * Les deux formes coexistent volontairement. Le prompt demande quatre coins —
 * une page photographiée de biais est un trapèze, et un rectangle y laisse
 * toujours deux coins de papier. Mais un modèle rend parfois la boîte
 * englobante, par habitude ou par prudence, et la refuser reviendrait à perdre
 * une photo correctement repérée pour une question de forme.
 *
 * Une boîte devient donc ses quatre coins, et le reste de la chaîne n'a qu'une
 * forme à connaître.
 */
export function readQuad(
  entry: unknown,
  pageWidth?: number,
  pageHeight?: number,
): DetectedQuad | null {
  if (!Array.isArray(entry) || entry.length !== 4) return null;

  // Quatre paires : les coins réels.
  if (entry.every((p) => Array.isArray(p) && p.length === 2)) {
    const points = (entry as unknown[][]).map((p) => [Number(p[0]), Number(p[1])]);
    if (points.some((p) => p.some((v) => !Number.isFinite(v)))) return null;
    // Les coins passent par la même mise à l'échelle que les boîtes : un modèle
    // qui répond en pixels le fait pour les deux formes.
    const plats = normalizeBox(
      [points[0][0], points[0][1], points[2][0], points[2][1]],
      pageWidth,
      pageHeight,
    );
    const echelle = (val: number, index: number) =>
      index === 0
        ? mapValue(val, points[0][0], points[2][0], plats[0], plats[2])
        : mapValue(val, points[0][1], points[2][1], plats[1], plats[3]);
    return points.map((pt) => [
      Math.round(echelle(pt[0], 0)),
      Math.round(echelle(pt[1], 1)),
    ]) as DetectedQuad;
  }

  // Quatre nombres : une boîte, convertie en son rectangle.
  const nums = entry.map((v) => Number(v));
  if (nums.some((n) => !Number.isFinite(n))) return null;
  const [yMin, xMin, yMax, xMax] = normalizeBox(nums, pageWidth, pageHeight);
  return [
    [yMin, xMin],
    [yMin, xMax],
    [yMax, xMax],
    [yMax, xMin],
  ];
}

/** Reporte une valeur d'un intervalle sur un autre, en évitant la division par zéro. */
function mapValue(v: number, from0: number, from1: number, to0: number, to1: number): number {
  const etendue = from1 - from0;
  if (Math.abs(etendue) < 1e-9) return to0;
  return to0 + ((v - from0) * (to1 - to0)) / etendue;
}

/** Rectangle englobant d'un quadrilatère, en 0-1000. */
export function boundingBoxOf(quad: DetectedQuad): BBox {
  const ys = quad.map((p) => p[0]);
  const xs = quad.map((p) => p[1]);
  return [Math.min(...ys), Math.min(...xs), Math.max(...ys), Math.max(...xs)];
}
