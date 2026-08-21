/**
 * Détection de zones photographiques dans une image de recette.
 *
 * Porté depuis GeminiService.detectIllustrationRegions() et
 * detectMainCulinaryPhoto(), avec subdivision intelligente via Sharp.
 */

import sharp from "sharp";
import { extractJsonArray } from "./client";
import { callModel } from "../ai/router";
import { filePart, textPart, type ModelCallContext } from "../ai/types";
import { assessCrop, type CropRejection } from "./illustrationQuality";

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

RÈGLES ABSOLUES :
- Chaque vignette de la grille = 1 boîte distincte. NE JAMAIS fusionner.
- Une grille NxM contient toujours N×M boîtes (sauf si certaines cellules sont vides).
- Les boîtes ne doivent PAS se chevaucher significativement.
- NE PAS inclure : texte, ingrédients listés, fond blanc, bordures, schémas, icônes.

TYPES de photos à détecter :
- Photos d'étapes de préparation (souvent en grille régulière)
- Photo finale du plat
- Photos d'ingrédients mis en scène

COORDONNÉES : [y_min, x_min, y_max, x_max] entiers 0-1000

RÉPONSE : UNIQUEMENT le tableau JSON, sans markdown ni explication :
[[y1,x1,y2,x2], ...] ou [] si aucune photo.
`;

const MAIN_PHOTO_PROMPT = String.raw`
Regarde cette image. Y a-t-il une photographie d'un plat cuisiné, d'un repas ou d'une nourriture préparée ?

Si OUI : donne les coordonnées de la zone photo [y_min, x_min, y_max, x_max] en entiers 0-1000.
Si NON : réponds [].

Réponds UNIQUEMENT avec le tableau JSON, rien d'autre.
Exemple pour une photo en bas de l'image : [480, 0, 1000, 1000]
`;

const GRID_PROMPT = String.raw`
Tu vois une zone d'une page de livre de cuisine contenant des photos arrangées en grille.
Compte le nombre de LIGNES et de COLONNES de photos distinctes.
Réponds UNIQUEMENT avec ce JSON (sans markdown, sans explication) :
{"rows": N, "cols": M}
Si c'est une seule grande photo (pas de grille), réponds : {"rows": 1, "cols": 1}
`;

const CROP_PROMPT = String.raw`
Compte et localise CHAQUE photographie culinaire individuelle dans cette image.
Chaque vignette = 1 boîte distincte. NE PAS fusionner.
Coordonnées [y_min, x_min, y_max, x_max] entiers 0-1000.
RÉPONSE : [[y1,x1,y2,x2], ...] ou [] si une seule photo.
`;

const FALLBACK_PROMPT = String.raw`
ATTENTION : une zone de cette image contient probablement PLUSIEURS petites
photographies (grille d'étapes culinaires) que tu as fusionnées par erreur.
Compte et liste CHAQUE vignette individuellement.
RÉPONSE : [[y1,x1,y2,x2], ...] ou [] si une seule photo.
`;

/**
 * Détecte les zones de photos culinaires dans une image de recette.
 * Avec subdivision automatique si Gemini sous-détecte une grille.
 */
export async function detectIllustrationRegions(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: ModelCallContext,
): Promise<BBox[]> {
  const regions = await callDetectAndParse(
    apiKey,
    bytes,
    mimeType,
    DETECT_PROMPT,
    "detect_illustrations",
    ctx,
  );

  // 2e passe : une boîte VRAIMENT grande est peut-être une grille fusionnée.
  //
  // Le seuil valait 80 000 sur un million — huit pour cent de la page. C'est la
  // taille d'une photographie ordinaire dans un livre de cuisine : presque
  // chaque photo réelle était donc soupçonnée d'être une grille, et découpée en
  // morceaux quand le modèle croyait y voir des cases. Une pleine page de
  // saumon ressortait en quatre tranches, ce qui explique le « très mal
  // recadré » constaté à l'usage.
  //
  // Un quart de page reste ambitieux pour une seule vignette, et c'est bien à
  // cette taille que les vraies grilles d'étapes se présentent.
  const shouldSubdivide =
    regions.length > 0 &&
    regions.length <= 4 &&
    regions.some((b) => (b[2] - b[0]) * (b[3] - b[1]) > 250_000);

  if (shouldSubdivide) {
    regions.sort((a, b) => (b[2] - b[0]) * (b[3] - b[1]) - (a[2] - a[0]) * (a[3] - a[1]));
    const [largest, ...others] = regions;
    const subdivided = await trySubdivideGrid(apiKey, bytes, largest, ctx);
    if (subdivided.length > 1) {
      return [...others, ...subdivided];
    }
  }

  return regions;
}

/**
 * Détection simple : 1 photo culinaire principale (utilisé en repli).
 */
export async function detectMainCulinaryPhoto(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: ModelCallContext,
): Promise<BBox | null> {
  try {
    const result = await callModel({
      parts: [filePart(mimeType, bytes), textPart(MAIN_PHOTO_PROMPT)],
      ctx: { ...ctx, feature: "detect_main_photo", timeoutMs: 45_000 },
    });

    const text = result.text.trim();
    if (!text || text === "[]") return null;

    const json = extractJsonArray(text);
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;

    const raw: number[] = Array.isArray(parsed[0]) ? (parsed[0] as number[]) : (parsed as number[]);
    if (raw.length !== 4) return null;
    return normalizeBox(raw);
  } catch {
    return null;
  }
}

async function callDetectAndParse(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  prompt: string,
  feature: string,
  ctx: ModelCallContext,
): Promise<BBox[]> {
  try {
    const result = await callModel({
      parts: [filePart(mimeType, bytes), textPart(prompt)],
      ctx: { ...ctx, feature, timeoutMs: 90_000 },
    });

    const text = result.text.trim();
    if (!text || text === "[]") return [];

    const json = extractJsonArray(text);
    const parsed = JSON.parse(json);
    if (!Array.isArray(parsed)) return [];

    const boxes: BBox[] = [];
    for (const entry of parsed) {
      if (!Array.isArray(entry) || entry.length !== 4) continue;
      const nums = entry.map((v) => Number(v));
      if (nums.some((n) => !Number.isFinite(n))) continue;
      boxes.push(normalizeBox(nums));
    }
    return boxes;
  } catch {
    return [];
  }
}

function normalizeBox(vals: number[]): BBox {
  const maxVal = Math.max(...vals);
  const scale = maxVal <= 1.5 ? 1000 : 1;
  const scaled = vals.map((v) => Math.round(v * scale));
  return [scaled[0], scaled[1], scaled[2], scaled[3]];
}

/**
 * Subdivise une grande zone détectée en cellules de grille.
 * Approche 1 : demande à Gemini les dimensions (rows × cols) puis division mathématique.
 * Approche 2 : crop + re-prompt coordonnées.
 * Approche 3 (repli) : re-prompt sur l'image entière.
 */
async function trySubdivideGrid(
  apiKey: string,
  bytes: Buffer,
  box: BBox,
  ctx: ModelCallContext,
): Promise<BBox[]> {
  try {
    const img = sharp(bytes);
    const meta = await img.metadata();
    const w = meta.width ?? 0;
    const h = meta.height ?? 0;
    if (w === 0 || h === 0) return [];

    const bx = clamp(Math.floor((box[1] * w) / 1000), 0, w - 1);
    const by = clamp(Math.floor((box[0] * h) / 1000), 0, h - 1);
    const bw = clamp(Math.floor(((box[3] - box[1]) * w) / 1000), 10, w - bx);
    const bh = clamp(Math.floor(((box[2] - box[0]) * h) / 1000), 10, h - by);

    if (bw <= 100 || bh <= 100) return [];

    const croppedBytes = await sharp(bytes)
      .extract({ left: bx, top: by, width: bw, height: bh })
      .jpeg({ quality: 90 })
      .toBuffer();

    // Approche 1 : grille mathématique
    try {
      const gridResult = await callModel({
        parts: [filePart("image/jpeg", croppedBytes), textPart(GRID_PROMPT)],
        ctx: { ...ctx, feature: "detect_grid_dims", timeoutMs: 60_000 },
      });

      const text = gridResult.text.replace(/```json?|```/g, "").trim();
      const match = text.match(/\{[^}]+\}/);
      if (match) {
        const dims = JSON.parse(match[0]) as { rows?: number; cols?: number };
        const rows = Math.floor(dims.rows ?? 1);
        const cols = Math.floor(dims.cols ?? 1);
        if (rows * cols > 1 && rows <= 6 && cols <= 6) {
          const boxH = box[2] - box[0];
          const boxW = box[3] - box[1];
          const cellH = Math.floor(boxH / rows);
          const cellW = Math.floor(boxW / cols);
          const out: BBox[] = [];
          for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
              out.push([
                box[0] + r * cellH,
                box[1] + c * cellW,
                box[0] + (r + 1) * cellH,
                box[1] + (c + 1) * cellW,
              ]);
            }
          }
          return out;
        }
      }
    } catch {
      // fall through
    }

    // Approche 2 : coordonnées directes sur le crop
    const subRegions = await callDetectAndParse(
      apiKey,
      croppedBytes,
      "image/jpeg",
      CROP_PROMPT,
      "detect_illustrations_crop",
      ctx,
    );
    if (subRegions.length > 1) {
      const boxH = box[2] - box[0];
      const boxW = box[3] - box[1];
      return subRegions.map<BBox>((r) => [
        box[0] + Math.floor((r[0] * boxH) / 1000),
        box[1] + Math.floor((r[1] * boxW) / 1000),
        box[0] + Math.floor((r[2] * boxH) / 1000),
        box[1] + Math.floor((r[3] * boxW) / 1000),
      ]);
    }
  } catch {
    // fall through
  }

  // Approche 3 : re-prompt sur l'image entière
  return callDetectAndParse(
    apiKey,
    bytes,
    "image/jpeg",
    FALLBACK_PROMPT,
    "detect_illustrations_grid",
    ctx,
  );
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
 * Découpe une image en sous-images d'après une liste de bounding boxes (0-1000).
 * Utilisé par le pipeline pour générer les illustrations à uploader dans Storage.
 *
 * L'image reçue doit DÉJÀ être redressée (`uprightImage`) : les coordonnées
 * viennent d'un modèle qui a vu l'image debout.
 */
export async function cropIllustrations(bytes: Buffer, boxes: BBox[]): Promise<Buffer[]> {
  if (boxes.length === 0) return [];
  const img = sharp(bytes);
  const meta = await img.metadata();
  const w = meta.width ?? 0;
  const h = meta.height ?? 0;
  if (w === 0 || h === 0) return [];

  const results: Buffer[] = [];
  for (const box of boxes) {
    const left = clamp(Math.floor((box[1] * w) / 1000), 0, w - 1);
    const top = clamp(Math.floor((box[0] * h) / 1000), 0, h - 1);
    const width = clamp(Math.floor(((box[3] - box[1]) * w) / 1000), 1, w - left);
    const height = clamp(Math.floor(((box[2] - box[0]) * h) / 1000), 1, h - top);

    const cropped = await sharp(bytes)
      .extract({ left, top, width, height })
      .jpeg({ quality: 88 })
      .toBuffer();
    results.push(cropped);
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
  boxes: BBox[],
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
