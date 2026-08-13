/**
 * imageQuality.ts — Score de qualité d'image basé sur Sharp.
 *
 * Calcule trois métriques sans appel Gemini :
 *   - blur_score : variance du Laplacien (élevé = net, faible = flou)
 *   - exposure_ok : luminosité et contraste dans des plages acceptables
 *   - has_tilt    : orientation EXIF différente de 1 (image pivotée)
 *
 * Utilisé comme gate avant d'appeler Gemini Enhancement : si la photo est déjà
 * correcte, un pipeline Sharp seul suffit (0 token Gemini consommé).
 */

import sharp from "sharp";

export interface ImageQualityResult {
  /** True si l'image nécessite l'enhancement Gemini complet. */
  needsGemini: boolean;
  /** Raisons détectées : "blur", "exposure", "tilt". */
  reasons: string[];
  /** Variance du Laplacien (>200 = net, 50-200 = acceptable, <50 = flou). */
  blurScore: number;
  /** True si la luminosité et le contraste sont dans des plages correctes. */
  exposureOk: boolean;
  /** True si l'EXIF indique une rotation (orientation ≠ 1). */
  hasTilt: boolean;
}

/**
 * Analyse une image et retourne un score de qualité.
 * Décision finale : needsGemini = true si au moins deux facteurs sont problématiques,
 * ou si le flou est sévère (score < 30), ou si l'exposition est très mauvaise.
 */
export async function scoreImageQuality(bytes: Buffer): Promise<ImageQualityResult> {
  // ── Métrique 1 : flou (variance du Laplacien) ────────────────────────────
  const { data: grayData, info } = await sharp(bytes)
    .resize(512, 512, { fit: "inside", withoutEnlargement: true })
    .grayscale()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const blurScore = _laplacianVariance(grayData, info.width, info.height);

  // ── Métrique 2 : exposition (stats canaux RGB) ───────────────────────────
  const stats = await sharp(bytes).stats();
  // Moyenne et écart-type normalisés sur [0, 1]
  const mean = stats.channels.slice(0, 3).reduce((s, c) => s + c.mean, 0) / (3 * 255);
  const stdDev = stats.channels.slice(0, 3).reduce((s, c) => s + c.stdev, 0) / (3 * 255);
  // Bonne exposition : luminosité entre 20% et 80%, contraste ≥ 10%
  const exposureOk = mean >= 0.2 && mean <= 0.8 && stdDev >= 0.1;

  // ── Métrique 3 : rotation EXIF ───────────────────────────────────────────
  const meta = await sharp(bytes).metadata();
  const hasTilt =
    meta.orientation !== undefined && meta.orientation !== null && meta.orientation !== 1;

  // ── Décision ─────────────────────────────────────────────────────────────
  const reasons: string[] = [];
  if (blurScore < 50) reasons.push("blur");
  if (!exposureOk) reasons.push("exposure");
  if (hasTilt) reasons.push("tilt");

  // Gemini si : flou sévère, ou exposition très mauvaise, ou ≥ 2 problèmes
  const needsGemini =
    blurScore < 30 ||
    (!exposureOk && (mean < 0.1 || mean > 0.9 || stdDev < 0.05)) ||
    reasons.length >= 2;

  return { needsGemini, reasons, blurScore, exposureOk, hasTilt };
}

/**
 * Calcule la variance du Laplacien sur une image en niveaux de gris (raw pixels).
 * Noyau Laplacien : [0, 1, 0, 1, -4, 1, 0, 1, 0]
 * Une variance élevée indique une image nette (beaucoup de transitions franches).
 */
function _laplacianVariance(data: Buffer, W: number, H: number): number {
  let sum = 0;
  let sumSq = 0;
  let count = 0;

  for (let y = 1; y < H - 1; y++) {
    for (let x = 1; x < W - 1; x++) {
      const v =
        data[(y - 1) * W + x] +
        data[(y + 1) * W + x] +
        data[y * W + x - 1] +
        data[y * W + x + 1] -
        4 * data[y * W + x];
      sum += v;
      sumSq += v * v;
      count++;
    }
  }

  if (count === 0) return 0;
  const mean = sum / count;
  return sumSq / count - mean * mean;
}
