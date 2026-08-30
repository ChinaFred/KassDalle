/**
 * Extraire les illustrations d'une page importée.
 *
 * Portage en production de l'expérience `image_import` du bac à sable, dont la
 * chaîne a été mise au point pas à pas. Rien n'y est repris « par symétrie » :
 * chaque étape est là parce que la retirer casse un cas réel.
 *
 * ## La chaîne
 *
 * 1. **Y a-t-il quelque chose à extraire ?** Un appel sur la photo brute. Non →
 *    on s'arrête là, et les quatre appels suivants n'ont pas lieu. Le cas est
 *    fréquent : une page de recette sur deux ne porte aucune image.
 * 2. **Où est la page ?** Une boîte droite, puis les quatre coins sur un gros
 *    plan de cette boîte. Deux questions, parce qu'un modèle encadre bien et
 *    place mal des sommets libres.
 * 3. **À plat.** Homographie, calculée par le programme. Aucun modèle n'a son
 *    mot à dire ici.
 * 4. **À l'endroit.** Une planche des quatre orientations, et le modèle dit
 *    dans laquelle il sait lire. Le programme applique le quart de tour.
 * 5. **Les zones.** Des rectangles droits — la page est à plat, une photo
 *    imprimée dessus est alignée sur ses bords.
 * 6. **La découpe.** Un simple recadrage sur la page pleine résolution : rien
 *    n'est ré-échantillonné, chaque pixel gardé est celui d'origine.
 *
 * La règle qui traverse tout : **au modèle le sens, au programme la géométrie**.
 * Chaque échec de la mise au point venait d'une question géométrique posée au
 * modèle — des degrés à calculer, des sommets à placer. Chaque correction a
 * consisté à la reformuler en reconnaissance.
 *
 * ## Ce qui se passe quand ça rate
 *
 * Rien de visible. L'extraction est un bonus attaché à un import de recette qui,
 * lui, doit aboutir. Une panne ici journalise et rend une liste vide ; elle ne
 * fait jamais échouer le job. C'est le seul endroit du projet où un `catch` se
 * termine par un résultat dégradé — et il journalise avant, comme la règle
 * l'exige.
 *
 * ## Le bac à sable est resté en place
 *
 * `functions/src/sandbox/` porte toujours sa version, et les deux vont diverger :
 * l'une continuera d'essayer, l'autre est figée sur ce qui marche. Les prompts
 * ont donc été **copiés** dans `prompts.ts`, pas partagés.
 */

import { callModel } from "../ai/router";
import { filePart, textPart, type ModelCallContext, type ModelCallResult } from "../ai/types";
import { logAiText, logError } from "../logging";
import { IllustrationLedger } from "./ledger";
import {
  BOX_PROMPT,
  CORNERS_PROMPT,
  ORIENTATION_PROMPT,
  PRECHECK_PROMPT,
  REGIONS_PROMPT,
} from "./prompts";
import { buildOrientationSheet, SHEET_LABELS, SHEET_ROTATIONS } from "./sheet";
import { warpQuadrilateral, type Quad as PixelQuad } from "../gemini/perspective";

// ── Postes de coût ───────────────────────────────────────────────────────────
//
// Quatre postes distincts et non un seul : c'est le seul moyen de répondre à
// « le pré-contrôle rapporte-t-il plus qu'il ne coûte ». Un poste unique dirait
// ce que l'extraction coûte, jamais où part l'argent.
//
// Ils vivent aussi dans `ROUTABLE_FEATURES` (`callable/aiRoutingCallable.ts`) et
// dans `feature_catalog.dart` — voir « Un poste d'IA vit à trois endroits ».

export const FEATURE_PRECHECK = "page_illustrations_precheck";
export const FEATURE_FRAME = "page_illustrations_frame";
export const FEATURE_ORIENTATION = "page_illustrations_orientation";
export const FEATURE_REGIONS = "page_illustrations_regions";

// ── Réglages, copiés du bac à sable ──────────────────────────────────────────

/**
 * Côté long de l'image envoyée au modèle.
 *
 * Les coordonnées reviennent en repère normalisé 0-1000 : réduire ne coûte
 * aucune précision, et une photo de téléphone dépasse sinon les limites d'un
 * appel multimodal.
 *
 * 2048 et non 1600 : c'est la valeur avec laquelle toute la chaîne a été mise
 * au point dans le bac à sable. L'écart change peu de chose — les fournisseurs
 * redimensionnent eux-mêmes au-delà d'un certain côté — mais un portage n'a
 * aucune raison de changer un réglage validé.
 */
const MODEL_MAX_DIMENSION = 2048;

/**
 * Côté long de la page redressée.
 *
 * Le bac à sable a mesuré ce chiffre. À 2048 px — le plafond de l'atelier de
 * retouche — une double page extraite sort autour de 650 px de large et son
 * corps de texte mesure cinq pixels de haut : illisible pour un modèle comme
 * pour un humain. À 4000, la même page sort autour de 1300 px, et les découpes
 * sont publiables.
 */
const PAGE_MAX_DIMENSION = 4000;

/**
 * Homothétie de sécurité appliquée aux coins avant le redressement, en part.
 *
 * Deux pour cent vers l'extérieur. Les deux erreurs ne se valent pas : un
 * liseré de décor autour de la page ne gêne pas la détection des zones, tandis
 * qu'un bord de photo rogné est perdu.
 */
const SAFETY_MARGIN = 0.02;

/** Marge autour de la boîte avant le gros plan des coins. */
const CROP_MARGIN = 0.25;

/** En dessous de cette confiance, la passe des coins est rejouée une fois. */
const RETRY_BELOW_CONFIDENCE = 0.6;

/** Sous cette taille, une découpe n'est pas une illustration mais un accident. */
const MIN_CROP_PX = 16;

/**
 * Tolérance sur « le cadre couvre déjà toute l'image », en millièmes.
 *
 * Copiée du bac à sable (`detected_page.dart`, 0,015 en fraction).
 */
const FULL_FRAME_TOLERANCE = 15;

/** Une image prête à partir au modèle, avec les dimensions qu'elle a vraiment. */
interface PreparedImage {
  bytes: Buffer;
  width: number;
  height: number;
}

/**
 * La ligne qui annonce au modèle la taille de ce qu'il regarde.
 *
 * Elle manquait au portage, et c'est un oubli qui compte. Les prompts de
 * cadrage et de zones ont été mis au point AVEC elle : celui des coins demande
 * encore de placer les sommets « au pixel près », ce qui n'a pas de sens pour
 * un modèle à qui personne n'a dit combien il y a de pixels.
 *
 * Le prompt d'orientation n'en a jamais eu, des deux côtés : on y demande de
 * reconnaître une vignette, pas de mesurer.
 */
export function sizeHeader(image: PreparedImage, sujet = "L'image"): string {
  return `${sujet} mesure ${image.width} pixels de large et ${image.height} de haut.\n\n`;
}

/**
 * Les quatre coins sont-ils ceux de l'image ?
 *
 * Sur un scan à plat, le modèle rend le cadre entier. Le redresser reviendrait
 * à ré-échantillonner chaque pixel pour rien, et un ré-échantillonnage coûte de
 * la netteté. Le bac à sable saute l'étape dans ce cas ; le portage l'avait
 * perdue.
 *
 * L'ordre attendu est haut-gauche, haut-droit, bas-droit, bas-gauche, en
 * `[y, x]` sur mille.
 */
export function isFullFrame(quad: Quad1000): boolean {
  const expected: Quad1000 = [
    [0, 0],
    [0, 1000],
    [1000, 1000],
    [1000, 0],
  ];
  return quad.every(
    ([y, x], i) =>
      Math.abs(y - expected[i][0]) <= FULL_FRAME_TOLERANCE &&
      Math.abs(x - expected[i][1]) <= FULL_FRAME_TOLERANCE,
  );
}

// ── Résultat ─────────────────────────────────────────────────────────────────

export type RegionKind = "photo" | "dessin" | "schema" | "texte_manuscrit" | "autre";

export interface ExtractedIllustration {
  bytes: Buffer;
  width: number;
  height: number;
  kind: RegionKind;
  /** Ce que la zone montre, en trois ou quatre mots, tel que le modèle l'a dit. */
  label: string;
  confidence: number;
}

export interface IllustrationExtraction {
  illustrations: ExtractedIllustration[];
  /** Ce qui s'est passé, en une phrase — repris tel quel dans le journal. */
  outcome: string;
  /** La chaîne s'est arrêtée au pré-contrôle : la page ne porte aucune image. */
  skipped: boolean;
  /**
   * Combien d'images la page porte, au mieux de ce qu'on sait.
   *
   * Les zones repérées à l'étape 5 quand la chaîne est allée jusque-là, sinon
   * le compte annoncé par le pré-contrôle. C'est ce chiffre qui nourrit le
   * bandeau de relecture, et il doit rester vrai même — surtout — quand
   * l'extraction n'a rien rendu : « il y avait trois photos à prendre » est
   * exactement ce qu'il faut dire à ce moment-là.
   */
  onPage: number;
}

/** Ce que le pré-contrôle a répondu, seul. */
export interface PagePrecheck {
  hasImages: boolean;
  /** Le nombre d'images distinctes annoncé par le modèle. */
  count: number;
  /** Le pré-contrôle lui-même a échoué : on ne sait rien, et on le dit. */
  failed: boolean;
}

const KINDS: readonly RegionKind[] = ["photo", "dessin", "schema", "texte_manuscrit", "autre"];

// ── Entrée ───────────────────────────────────────────────────────────────────

/**
 * Rend les illustrations d'une page, ou une liste vide.
 *
 * Ne lève jamais : tout échec est journalisé et rendu sous forme de liste vide.
 * L'appelant est un import de recette, et une page sans illustration extraite
 * reste une recette parfaitement importée.
 */
export async function extractPageIllustrations(args: {
  bytes: Buffer;
  mimeType: string;
  correlationId: string;
  /** Scan de l'utilisateur d'où vient la page, quand il en vient un. */
  scanId?: string;
  userId?: string;
  jobId?: string;
  fileName?: string;
}): Promise<IllustrationExtraction> {
  const ledger = new IllustrationLedger({
    correlationId: args.correlationId,
    scanId: args.scanId,
    userId: args.userId,
    jobId: args.jobId,
    fileName: args.fileName,
  });

  const base = {
    correlationId: args.correlationId,
    scanId: args.scanId,
    userId: args.userId,
    jobId: args.jobId,
    moduleType: "DESIGN" as const,
  };

  try {
    const result = await runChain({ ...args, ledger, base });
    await ledger.close({
      outcome: result.outcome,
      illustrations: result.illustrations.length,
    });
    return result;
  } catch (err) {
    await logError({
      message: "Illustrations : extraction interrompue, la recette est importée sans images",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: args.correlationId,
      scanId: args.scanId,
      userId: args.userId,
      jobId: args.jobId,
      feature: "page_illustrations",
    });
    await ledger.close({ outcome: "interrompue", illustrations: 0 });
    return { illustrations: [], outcome: "interrompue", skipped: false, onPage: 0 };
  }
}

// ── La chaîne ────────────────────────────────────────────────────────────────

async function runChain(args: {
  bytes: Buffer;
  mimeType: string;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<IllustrationExtraction> {
  const { ledger, base } = args;
  const { default: sharp } = await import("sharp");

  // L'orientation EXIF est appliquée dans les pixels, une fois pour toutes.
  // Sans cette passe, le modèle voit l'image couchée, rend des coins justes
  // dans ce repère-là, et le redressement les applique à une image debout : le
  // résultat est un morceau de canapé, parfaitement net.
  const upright = await sharp(args.bytes).rotate().jpeg({ quality: 95 }).toBuffer();

  // ── 1. Y a-t-il quelque chose à extraire ? ─────────────────────────────────
  const small = await downscale(upright, MODEL_MAX_DIMENSION);
  const precheck = await runPrecheck({
    bytes: small.bytes,
    label: "pré-contrôle",
    ledger,
    base,
  });

  // Le compte du pré-contrôle est le filet de sécurité de tout ce qui suit :
  // si la chaîne s'arrête plus loin, c'est lui qui dira au lecteur combien de
  // photos il y avait à prendre. Une extraction ratée sans ce chiffre laisse
  // une recette sans image et sans explication.
  const onPage = precheck.count;

  if (!precheck.hasImages) {
    return {
      illustrations: [],
      outcome: precheck.failed ? "pré-contrôle illisible" : "aucune image sur la page",
      skipped: true,
      onPage,
    };
  }

  // ── 2. Où est la page ? ───────────────────────────────────────────────────
  const quad = await detectPageQuad({ full: upright, small, ledger, base });
  if (!quad) {
    return { illustrations: [], outcome: "page non cadrée", skipped: false, onPage };
  }

  // ── 3. À plat ─────────────────────────────────────────────────────────────
  const meta = await sharp(upright).metadata();
  const fullWidth = meta.width ?? 0;
  const fullHeight = meta.height ?? 0;
  if (fullWidth === 0 || fullHeight === 0) {
    return { illustrations: [], outcome: "image illisible", skipped: false, onPage };
  }

  // La page occupe déjà tout le cadre : un scan à plat, une capture d'écran.
  // La redresser ne changerait rien de visible et ré-échantillonnerait chaque
  // pixel, donc coûterait de la netteté sans rien rendre.
  let page = upright;
  if (!isFullFrame(quad)) {
    const pixelQuad = withSafetyMargin(quad).map(([y, x]) => ({
      x: (x / 1000) * fullWidth,
      y: (y / 1000) * fullHeight,
    })) as PixelQuad;

    page = await warpQuadrilateral(upright, pixelQuad, {
      maxWorkDimension: PAGE_MAX_DIMENSION,
      quality: 95,
    });
  }

  // ── 4. À l'endroit ────────────────────────────────────────────────────────
  const rotation = await detectRotation({ page, ledger, base });
  if (rotation !== 0) {
    page = await sharp(page).rotate(rotation).jpeg({ quality: 95 }).toBuffer();
  }

  // ── 5. Les zones ──────────────────────────────────────────────────────────
  const pageSmall = await downscale(page, MODEL_MAX_DIMENSION);
  const regions = await detectRegions({ prepared: pageSmall, ledger, base });
  if (regions.length === 0) {
    return { illustrations: [], outcome: "aucune zone détectée", skipped: false, onPage };
  }

  // ── 6. La découpe ─────────────────────────────────────────────────────────
  const illustrations = await cropRegions({ page, regions, base });

  return {
    illustrations,
    outcome: `${illustrations.length} illustration(s) extraite(s) sur ${regions.length} zone(s)`,
    skipped: false,
    // Les zones vues sur la page à plat priment sur le compte du pré-contrôle :
    // elles ont été repérées sur une image redressée, à l'endroit, et cadrées
    // une par une. C'est le meilleur chiffre dont on dispose.
    onPage: regions.length,
  };
}

/**
 * Le pré-contrôle seul : cette page porte-t-elle des images, et combien ?
 *
 * Exporté parce qu'il sert **aussi** quand l'extraction n'est pas demandée.
 * C'est la seule chose que l'import ait besoin de savoir dans ce cas : combien
 * de photos la page porte, pour que la relecture puisse le dire.
 *
 * Il a remplacé `detectIllustrationRegions` sur ce chemin. Les deux répondaient
 * à la même question, mais l'autre le faisait avec le prompt complet de
 * détection — un repère de coordonnées, des règles de cadrage, un format de
 * boîte — dont l'appelant ne gardait qu'un entier. `detectIllustrationRegions`
 * garde son vrai rôle : rendre des boîtes à découper, pour l'atelier manuel.
 *
 * Ne lève jamais : un pré-contrôle en panne rend `failed`, ce que l'appelant
 * doit pouvoir distinguer de « aucune image ». Les deux appellent des réactions
 * opposées — réessayer, ou ne rien faire.
 */
export async function precheckPageImages(args: {
  bytes: Buffer;
  mimeType: string;
  correlationId: string;
  /** Scan de l'utilisateur d'où vient la page, quand il en vient un. */
  scanId?: string;
  userId?: string;
  jobId?: string;
  fileName?: string;
}): Promise<PagePrecheck> {
  const ledger = new IllustrationLedger({
    correlationId: args.correlationId,
    scanId: args.scanId,
    userId: args.userId,
    jobId: args.jobId,
    fileName: args.fileName,
  });
  const base = {
    correlationId: args.correlationId,
    scanId: args.scanId,
    userId: args.userId,
    jobId: args.jobId,
    moduleType: "DESIGN" as const,
  };

  try {
    const { default: sharp } = await import("sharp");
    const upright = await sharp(args.bytes).rotate().jpeg({ quality: 95 }).toBuffer();
    const small = await downscale(upright, MODEL_MAX_DIMENSION);
    const precheck = await runPrecheck({ bytes: small.bytes, label: "comptage", ledger, base });
    await ledger.close({
      outcome: precheck.failed ? "pré-contrôle illisible" : `${precheck.count} image(s)`,
      illustrations: 0,
    });
    return precheck;
  } catch (err) {
    await logError({
      message: "Illustrations : comptage impossible, la recette est importée sans ce chiffre",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: args.correlationId,
      scanId: args.scanId,
      userId: args.userId,
      jobId: args.jobId,
      feature: FEATURE_PRECHECK,
    });
    await ledger.close({ outcome: "comptage interrompu", illustrations: 0 });
    return { hasImages: false, count: 0, failed: true };
  }
}

/** L'appel de pré-contrôle et la lecture de sa réponse. */
async function runPrecheck(args: {
  bytes: Buffer;
  label: string;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<PagePrecheck> {
  const answer = await askJson({
    bytes: args.bytes,
    mimeType: "image/jpeg",
    prompt: PRECHECK_PROMPT,
    label: args.label,
    feature: FEATURE_PRECHECK,
    ledger: args.ledger,
    base: args.base,
  });
  if (!answer) return { hasImages: false, count: 0, failed: true };

  const hasImages = answer.json?.has_images === true;
  const raw = Number(answer.json?.count);
  // Un compte absent ou aberrant sur une page qui porte des images vaut 1 :
  // « il y en a » est l'information, le nombre exact ne l'est pas. Zéro serait
  // pire — il ferait dire au bandeau qu'il n'y a rien à prendre.
  const count = hasImages
    ? Number.isFinite(raw) && raw > 0
      ? Math.min(50, Math.round(raw))
      : 1
    : 0;
  return { hasImages, count, failed: false };
}

// ── Étape 2 : le cadrage, en deux passes ─────────────────────────────────────

type Corner = [number, number];
export type Quad1000 = [Corner, Corner, Corner, Corner];

async function detectPageQuad(args: {
  full: Buffer;
  small: PreparedImage;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<Quad1000 | null> {
  const { full, small, ledger, base } = args;
  const { default: sharp } = await import("sharp");

  const first = await askJson({
    bytes: small.bytes,
    mimeType: "image/jpeg",
    prompt: BOX_PROMPT,
    header: sizeHeader(small),
    label: "cadrage (boîte)",
    feature: FEATURE_FRAME,
    ledger,
    base,
  });
  const box = parseBox(first?.json?.box);
  if (!box) return null;

  const [yMin, xMin, yMax, xMax] = box;
  const boxQuad: Quad1000 = [
    [yMin, xMin],
    [yMin, xMax],
    [yMax, xMax],
    [yMax, xMin],
  ];

  // Le gros plan, marge comprise. Un quart de boîte : quand la première passe
  // est courte d'un cinquième, la page tient quand même entière dedans, et la
  // seconde passe ne cadre pas une page amputée.
  const marginY = (yMax - yMin) * CROP_MARGIN;
  const marginX = (xMax - xMin) * CROP_MARGIN;
  const cropTop = Math.max(0, yMin - marginY);
  const cropLeft = Math.max(0, xMin - marginX);
  const cropBottom = Math.min(1000, yMax + marginY);
  const cropRight = Math.min(1000, xMax + marginX);

  let crop: PreparedImage;
  try {
    const meta = await sharp(full).metadata();
    const width = meta.width ?? 0;
    const height = meta.height ?? 0;
    if (width === 0 || height === 0) return boxQuad;

    const left = Math.round((cropLeft / 1000) * width);
    const top = Math.round((cropTop / 1000) * height);
    const extracted = await sharp(full)
      .extract({
        left: Math.min(left, width - MIN_CROP_PX),
        top: Math.min(top, height - MIN_CROP_PX),
        width: Math.min(
          Math.max(MIN_CROP_PX, Math.round(((cropRight - cropLeft) / 1000) * width)),
          width - left,
        ),
        height: Math.min(
          Math.max(MIN_CROP_PX, Math.round(((cropBottom - cropTop) / 1000) * height)),
          height - top,
        ),
      })
      .jpeg({ quality: 92 })
      .toBuffer();
    crop = await downscale(extracted, MODEL_MAX_DIMENSION);
  } catch (err) {
    await logError({
      message: "Illustrations : gros plan impossible, le cadrage reste la boîte",
      errorDescription: err instanceof Error ? err.message : String(err),
      ...base,
      feature: FEATURE_FRAME,
    });
    return boxQuad;
  }

  let second = await askJson({
    bytes: crop.bytes,
    mimeType: "image/jpeg",
    prompt: CORNERS_PROMPT,
    header: sizeHeader(crop, "Ce gros plan"),
    label: "cadrage (coins)",
    feature: FEATURE_FRAME,
    ledger,
    base,
  });

  // Second essai quand le modèle doute lui-même. La confiance sépare
  // nettement : plus de 80 % sur les cadrages justes, 42 % sur celui qui ne
  // l'était pas. Une page facile ne repasse donc jamais par ici, et un cadrage
  // déjà bon ne peut pas être abîmé.
  const firstConfidence = Number(second?.json?.confidence);
  if (Number.isFinite(firstConfidence) && firstConfidence < RETRY_BELOW_CONFIDENCE) {
    const retry = await askJson({
      bytes: crop.bytes,
      mimeType: "image/jpeg",
      prompt: CORNERS_PROMPT,
      header: sizeHeader(crop, "Ce gros plan"),
      label: "cadrage (coins, 2e essai)",
      feature: FEATURE_FRAME,
      ledger,
      base,
    });
    const retryConfidence = Number(retry?.json?.confidence);
    if (Number.isFinite(retryConfidence) && retryConfidence > firstConfidence) {
      second = retry;
    }
  }

  if (!second) return boxQuad;

  // La page déborde du gros plan : les coins que le modèle rendrait seraient
  // ceux du morceau visible. La boîte, elle, couvre la page en entier.
  if (second.json?.cut === true) return boxQuad;

  const cropQuad = parseQuad(second.json?.quad);
  if (!cropQuad) return boxQuad;

  // Même garde, mesurée : un coin collé au bord trahit une page qui continue
  // au-delà, que le modèle l'ait avoué ou non.
  if (cropQuad.some(([y, x]) => y <= 8 || y >= 992 || x <= 8 || x >= 992)) return boxQuad;

  const spanY = cropBottom - cropTop;
  const spanX = cropRight - cropLeft;
  const quad = cropQuad.map(([y, x]) => [
    Math.round(cropTop + (y / 1000) * spanY),
    Math.round(cropLeft + (x / 1000) * spanX),
  ]) as Quad1000;

  // Un quadrilatère qui couvre 2 % de l'image, ou 99,5 %, n'est pas une page :
  // c'est un détail attrapé au passage, ou le cadre entier rendu par défaut.
  const area = quadArea(quad);
  if (area < 20_000 || area > 995_000) return boxQuad;

  return quad;
}

// ── Étape 4 : le sens de lecture ─────────────────────────────────────────────

/**
 * Le quart de tour à appliquer, en degrés dans le sens des aiguilles.
 *
 * Zéro quand rien ne tranche : la case A est la page telle qu'elle est arrivée,
 * et ne rien changer est moins gênant que de la retourner pour rien.
 */
async function detectRotation(args: {
  page: Buffer;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<number> {
  const { page, ledger, base } = args;

  let sheet: Buffer;
  try {
    sheet = (await buildOrientationSheet(page)).bytes;
  } catch (err) {
    await logError({
      message: "Illustrations : planche d'orientation impossible, la page reste telle quelle",
      errorDescription: err instanceof Error ? err.message : String(err),
      ...base,
      feature: FEATURE_ORIENTATION,
    });
    return 0;
  }

  const answer = await askJson({
    bytes: sheet,
    mimeType: "image/jpeg",
    prompt: ORIENTATION_PROMPT,
    label: "orientation",
    feature: FEATURE_ORIENTATION,
    ledger,
    base,
  });

  const picked = String(answer?.json?.choice ?? "")
    .trim()
    .toUpperCase();
  const index = SHEET_LABELS.indexOf(picked);
  if (index < 0) return 0;
  return SHEET_ROTATIONS[index];
}

// ── Étape 5 : les zones ──────────────────────────────────────────────────────

interface Region {
  yMin: number;
  xMin: number;
  yMax: number;
  xMax: number;
  kind: RegionKind;
  label: string;
  confidence: number;
}

async function detectRegions(args: {
  prepared: PreparedImage;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<Region[]> {
  const { prepared, ledger, base } = args;

  const answer = await askJson({
    bytes: prepared.bytes,
    mimeType: "image/jpeg",
    prompt: REGIONS_PROMPT,
    header: sizeHeader(prepared),
    label: "zones",
    feature: FEATURE_REGIONS,
    ledger,
    base,
    array: true,
  });
  if (!answer || !Array.isArray(answer.array)) return [];

  const regions: Region[] = [];
  for (const entry of answer.array) {
    const source = entry as Record<string, unknown>;
    const box = parseBox(source?.box);
    if (!box) continue;
    const [yMin, xMin, yMax, xMax] = box;

    // Une zone qui couvre plus des neuf dixièmes de la page est la page
    // elle-même. Le modèle la rend quand il ne trouve rien d'autre.
    if ((yMax - yMin) * (xMax - xMin) > 900_000) continue;

    const kindValue = String(source?.kind ?? "").toLowerCase();
    const confidence = Number(source?.confidence);
    regions.push({
      yMin,
      xMin,
      yMax,
      xMax,
      kind: (KINDS as readonly string[]).includes(kindValue) ? (kindValue as RegionKind) : "autre",
      label: String(source?.label ?? "").slice(0, 120),
      confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    });
  }
  return regions;
}

// ── Étape 6 : la découpe ─────────────────────────────────────────────────────

/**
 * Découpe chaque zone sur la page pleine résolution.
 *
 * Un simple recadrage, et c'est voulu : la page est à plat et à l'endroit, les
 * zones y sont des rectangles alignés sur ses bords. Il n'y a plus de
 * perspective à corriger, donc rien à ré-échantillonner.
 */
async function cropRegions(args: {
  page: Buffer;
  regions: Region[];
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
}): Promise<ExtractedIllustration[]> {
  const { page, regions, base } = args;
  const { default: sharp } = await import("sharp");

  const meta = await sharp(page).metadata();
  const pageWidth = meta.width ?? 0;
  const pageHeight = meta.height ?? 0;
  if (pageWidth === 0 || pageHeight === 0) return [];

  const out: ExtractedIllustration[] = [];
  for (const region of regions) {
    const left = clampInt((region.xMin / 1000) * pageWidth, 0, pageWidth - 1);
    const top = clampInt((region.yMin / 1000) * pageHeight, 0, pageHeight - 1);
    const width = clampInt(((region.xMax - region.xMin) / 1000) * pageWidth, 1, pageWidth - left);
    const height = clampInt(((region.yMax - region.yMin) / 1000) * pageHeight, 1, pageHeight - top);

    // Une découpe de moins de seize pixels de côté vient d'une zone mal rendue :
    // l'encoder n'ajouterait qu'une vignette illisible à la galerie.
    if (width < MIN_CROP_PX || height < MIN_CROP_PX) continue;

    try {
      const bytes = await sharp(page)
        .extract({ left, top, width, height })
        .jpeg({ quality: 92 })
        .toBuffer();
      out.push({
        bytes,
        width,
        height,
        kind: region.kind,
        label: region.label,
        confidence: region.confidence,
      });
    } catch (err) {
      // Une zone perdue n'emporte pas les autres : elles n'ont rien à voir
      // avec elle. L'échec part quand même dans les journaux.
      await logError({
        message: `Illustrations : découpe impossible pour la zone « ${region.label} »`,
        errorDescription: err instanceof Error ? err.message : String(err),
        ...base,
        feature: FEATURE_REGIONS,
      });
    }
  }
  return out;
}

// ── Appel de modèle, journalisé et chiffré ───────────────────────────────────

interface JsonAnswer {
  json: Record<string, unknown> | null;
  array: unknown[] | null;
  result: ModelCallResult;
}

/**
 * Un appel, sa lecture JSON, sa ligne de journal et son montant.
 *
 * `null` quand la réponse est illisible. L'appel a bien été facturé, et il est
 * compté : une réponse inexploitable coûte exactement le même prix qu'une bonne.
 */
async function askJson(args: {
  bytes: Buffer;
  mimeType: string;
  prompt: string;
  /** Préfixe du prompt : la taille de l'image, quand l'étape la connaît. */
  header?: string;
  label: string;
  feature: string;
  ledger: IllustrationLedger;
  base: {
    correlationId: string;
    scanId?: string;
    userId?: string;
    jobId?: string;
    moduleType: "DESIGN";
  };
  array?: boolean;
}): Promise<JsonAnswer | null> {
  const { bytes, mimeType, prompt, header, label, feature, ledger, base, array } = args;

  const ctx: ModelCallContext = {
    correlationId: base.correlationId,
    userId: base.userId,
    jobId: base.jobId,
    feature,
    moduleType: "DESIGN",
    timeoutMs: 60_000,
    effort: "high",
  };

  const startedAt = Date.now();
  const result = await callModel({
    parts: [filePart(mimeType, bytes), textPart((header ?? "") + prompt)],
    ctx,
  });
  const elapsedMs = Date.now() - startedAt;
  const text = result.text.trim();

  // Le texte rendu par le modèle part dans les journaux comme celui des autres
  // postes : sans lui, un cadrage faux ne s'explique pas après coup.
  await logAiText({
    stage: feature,
    text,
    correlationId: base.correlationId,
    scanId: base.scanId,
    callId: result.callId,
    userId: base.userId,
    feature,
    provider: result.provider,
    model: result.model,
    moduleType: "DESIGN",
  });

  let parsed: unknown = null;
  let readable = true;
  try {
    parsed = JSON.parse(array ? extractJsonArray(text) : extractJsonObject(text));
  } catch (err) {
    readable = false;
    await logError({
      message: `Illustrations : réponse illisible à l'étape « ${label} »`,
      errorDescription: err instanceof Error ? err.message : String(err),
      ...base,
      feature,
      provider: result.provider,
      model: result.model,
    });
  }

  const observed = readable ? readObserved(parsed) : "réponse illisible";
  await ledger.record({ label, feature, result, elapsedMs, outcome: observed });

  if (!readable) return null;
  return {
    json: array ? null : ((parsed ?? null) as Record<string, unknown> | null),
    array: array ? (Array.isArray(parsed) ? parsed : null) : null,
    result,
  };
}

/**
 * Ce que le modèle dit avoir vu, pour la ligne de journal.
 *
 * Le champ `observed` est demandé dans chaque prompt, et il n'est pas décoratif :
 * c'est lui qui rend un cadrage douteux compréhensible six mois plus tard, sans
 * avoir à retrouver la photo d'origine.
 */
function readObserved(parsed: unknown): string {
  if (Array.isArray(parsed)) return `${parsed.length} entrée(s)`;
  const observed = (parsed as Record<string, unknown> | null)?.observed;
  return typeof observed === "string" && observed.trim() ? observed.slice(0, 200) : "sans détail";
}

// ── Géométrie et lecture ─────────────────────────────────────────────────────

/**
 * Écarte les quatre coins du centre de deux pour cent.
 *
 * Le cadrage du modèle est juste au bord près ; ce bord-là est parfois pris du
 * mauvais côté de l'ombre portée. Élargir un peu garde un liseré de décor,
 * qui ne gêne personne — la détection des zones qui suit ignore ce qui n'est
 * pas imprimé.
 */
function withSafetyMargin(quad: Quad1000): Quad1000 {
  const cy = quad.reduce((sum, [y]) => sum + y, 0) / 4;
  const cx = quad.reduce((sum, [, x]) => sum + x, 0) / 4;
  return quad.map(([y, x]) => [
    Math.min(1000, Math.max(0, cy + (y - cy) * (1 + SAFETY_MARGIN))),
    Math.min(1000, Math.max(0, cx + (x - cx) * (1 + SAFETY_MARGIN))),
  ]) as Quad1000;
}

/** Aire du quadrilatère, en millionièmes de page (repère 0-1000). */
function quadArea(quad: Quad1000): number {
  let sum = 0;
  for (let i = 0; i < 4; i++) {
    const [y1, x1] = quad[i];
    const [y2, x2] = quad[(i + 1) % 4];
    sum += x1 * y2 - x2 * y1;
  }
  return Math.abs(sum) / 2;
}

function clamp1000(value: unknown): number | null {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.min(1000, Math.max(0, Math.round(n)));
}

/**
 * Lit une boîte `[y_min, x_min, y_max, x_max]`.
 *
 * Les bornes sont remises en ordre plutôt que rejetées : un modèle qui inverse
 * `y_min` et `y_max` a quand même désigné la bonne zone.
 */
function parseBox(raw: unknown): [number, number, number, number] | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const values = raw.map(clamp1000);
  if (values.some((v) => v === null)) return null;
  const [a, b, c, d] = values as number[];
  const yMin = Math.min(a, c);
  const yMax = Math.max(a, c);
  const xMin = Math.min(b, d);
  const xMax = Math.max(b, d);
  if (yMax - yMin < 20 || xMax - xMin < 20) return null;
  return [yMin, xMin, yMax, xMax];
}

function parseQuad(raw: unknown): Quad1000 | null {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const corners: Corner[] = [];
  for (const corner of raw) {
    if (!Array.isArray(corner) || corner.length !== 2) return null;
    const y = clamp1000(corner[0]);
    const x = clamp1000(corner[1]);
    if (y === null || x === null) return null;
    corners.push([y, x]);
  }
  return corners as Quad1000;
}

function extractJsonObject(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  return match ? match[0] : cleaned;
}

function extractJsonArray(text: string): string {
  const cleaned = text.replace(/```json?|```/g, "").trim();
  const match = cleaned.match(/\[[\s\S]*\]/);
  return match ? match[0] : cleaned;
}

function clampInt(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(value)));
}

/** Réduit une image avant de l'envoyer au modèle, en JPEG. */
async function downscale(bytes: Buffer, maxDimension: number): Promise<PreparedImage> {
  const { default: sharp } = await import("sharp");
  const meta = await sharp(bytes).metadata();
  const longest = Math.max(meta.width ?? 0, meta.height ?? 0);
  if (longest === 0) throw new Error("Image illisible : dimensions inconnues.");

  if (longest <= maxDimension) {
    const out = await sharp(bytes).jpeg({ quality: 92 }).toBuffer({ resolveWithObject: true });
    return { bytes: out.data, width: out.info.width, height: out.info.height };
  }

  const out = await sharp(bytes)
    .resize({ width: maxDimension, height: maxDimension, fit: "inside" })
    .jpeg({ quality: 90 })
    .toBuffer({ resolveWithObject: true });
  return { bytes: out.data, width: out.info.width, height: out.info.height };
}
