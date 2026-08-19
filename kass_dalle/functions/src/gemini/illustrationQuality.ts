/**
 * Ce qu'on garde d'une découpe, et ce qu'on jette.
 *
 * Les boîtes viennent d'un modèle, pas d'un détecteur géométrique : rien ne
 * garantit qu'elles encadrent une photographie. Jusqu'ici, une boîte fantaisiste
 * produisait une bande de texte téléversée comme illustration, conservée pour
 * toujours et présentée à la famille comme une photo du plat.
 *
 * Trois filtres, **locaux et gratuits** : ils lisent la découpe, ils
 * n'interrogent aucun modèle. Ils sont volontairement conservateurs — jeter une
 * vraie photo est une perte irrattrapable, garder une découpe douteuse ne coûte
 * qu'un rejet de plus dans la revue de modération.
 *
 * À ne pas confondre avec `utils/imageQuality.ts`, qui mesure tout autre chose :
 * là, une photo est acquise et l'on juge si elle est floue ou mal exposée ; ici,
 * on juge si c'est une photo.
 */

/** Mesures d'une découpe, telles que Sharp les rend. */
export interface CropMeasures {
  widthPx: number;
  heightPx: number;
  pageWidthPx: number;
  pageHeightPx: number;
  /** Luminance moyenne, 0 (noir) à 255 (blanc). */
  meanLuminance: number;
  /**
   * Écart maximal entre les moyennes des trois canaux, 0 à 255.
   *
   * Une zone de texte sur papier est neutre — ses trois canaux se valent. Une
   * photographie de nourriture ne l'est jamais.
   */
  chroma: number;
}

export type CropRejection = "too_small" | "extreme_aspect" | "blank_or_text";

export interface CropVerdict {
  keep: boolean;
  reason: CropRejection | null;
}

/** Sous ce seuil, la découpe est une icône ou un fragment de bordure. */
export const MIN_CROP_SIDE_PX = 120;

/** Et elle doit peser au moins ce ratio de la page. */
export const MIN_CROP_AREA_RATIO = 0.015;

/** Au-delà, ce n'est plus une photo, c'est une bande. */
export const MAX_ASPECT_RATIO = 4;

/**
 * Presque blanche **et** sans couleur : du papier, ou du texte sur du papier.
 *
 * Les deux conditions sont exigées ensemble, et volontairement extrêmes. Une
 * photographie en noir et blanc a bien une chroma nulle, mais jamais une
 * luminance moyenne de 225 — le seuil ne l'atteint pas.
 */
export const BLANK_LUMINANCE = 225;
export const BLANK_CHROMA = 12;

/**
 * Décide du sort d'une découpe. Fonction **pure** : elle ne lit ni fichier, ni
 * réseau, et c'est ce qui la rend vérifiable seule.
 */
export function assessCrop(m: CropMeasures): CropVerdict {
  if (m.widthPx < MIN_CROP_SIDE_PX || m.heightPx < MIN_CROP_SIDE_PX) {
    return { keep: false, reason: "too_small" };
  }

  const pageArea = m.pageWidthPx * m.pageHeightPx;
  if (pageArea > 0 && (m.widthPx * m.heightPx) / pageArea < MIN_CROP_AREA_RATIO) {
    return { keep: false, reason: "too_small" };
  }

  const aspect = m.widthPx / m.heightPx;
  if (aspect > MAX_ASPECT_RATIO || aspect < 1 / MAX_ASPECT_RATIO) {
    return { keep: false, reason: "extreme_aspect" };
  }

  if (m.meanLuminance >= BLANK_LUMINANCE && m.chroma <= BLANK_CHROMA) {
    return { keep: false, reason: "blank_or_text" };
  }

  return { keep: true, reason: null };
}

/** Libellé français d'un rejet, pour le journal. */
export function rejectionLabel(reason: CropRejection): string {
  switch (reason) {
    case "too_small":
      return "trop petite pour être une photographie";
    case "extreme_aspect":
      return "bande plutôt que photographie";
    case "blank_or_text":
      return "presque blanche et sans couleur — papier ou texte";
  }
}
