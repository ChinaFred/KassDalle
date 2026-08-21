/**
 * Redressement d'un quadrilatère : la correction de perspective, côté serveur.
 *
 * Une page de livre photographiée à main levée n'est pas un rectangle, c'est un
 * TRAPÈZE. Un cadre rectangulaire, aussi serré soit-il, garde forcément deux
 * coins de papier et de table — c'est une limite de la forme, pas du cadrage,
 * et aucun prompt ne la lèvera.
 *
 * On demande donc au modèle les QUATRE COINS de la photographie imprimée, et on
 * applique la transformation qui les ramène sur un rectangle. C'est ce que fait
 * déjà l'atelier de retouche côté client (`image_enhancer_processing.dart`,
 * `warpIsolate`) : le même algorithme, porté ici pour que la chaîne automatique
 * rende ce que l'outil manuel rendait.
 *
 * Pourquoi une homographie et pas une rotation : une rotation redresse
 * l'inclinaison mais laisse la déformation en trapèze, celle qui vient de
 * photographier une page depuis un angle. Les deux bords opposés n'ont alors
 * pas la même longueur, et seule une projection les égalise.
 *
 * Le calcul est fait en clair sur des pixels bruts. Sharp ne sait pas
 * transformer une perspective — il redimensionne, tourne, découpe, mais ne
 * projette pas.
 */

import sharp from "sharp";

/** Un point de l'image, en pixels. */
export interface Point {
  x: number;
  y: number;
}

/**
 * Un quadrilatère, dans l'ordre : haut-gauche, haut-droit, bas-droit, bas-gauche.
 *
 * L'ordre n'est pas une convention arbitraire : c'est lui qui dit quel côté du
 * résultat sera le haut. Deux coins intervertis donnent une image miroir ou
 * retournée, parfaitement nette et parfaitement fausse.
 */
export type Quad = [Point, Point, Point, Point];

/** Au-delà, on travaille sur une version réduite : la boucle est en clair. */
const MAX_WORK_DIMENSION = 2400;

function distance(a: Point, b: Point): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

/**
 * Matrice de normalisation de Hartley (3×3, ligne par ligne).
 *
 * Centre les points et les met à l'échelle pour que leur distance moyenne au
 * centre vaille √2. Sans cette étape, le système linéaire mêle des coordonnées
 * de l'ordre du millier à des produits de l'ordre du million, et la résolution
 * perd ses décimales là où elles comptent.
 */
function hartleyNormMatrix(pts: Quad): number[] {
  const cx = (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4;
  const cy = (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4;
  let sum = 0;
  for (const p of pts) sum += Math.hypot(p.x - cx, p.y - cy);
  const mean = sum / 4;
  const s = mean > 1e-8 ? Math.SQRT2 / mean : 1;
  return [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1];
}

function applyNormMatrix(t: number[], pts: Quad): Quad {
  return pts.map((p) => ({ x: t[0] * p.x + t[2], y: t[4] * p.y + t[5] })) as Quad;
}

function mulMat3(a: number[], b: number[]): number[] {
  const c = new Array<number>(9).fill(0);
  for (let r = 0; r < 3; r++) {
    for (let col = 0; col < 3; col++) {
      for (let k = 0; k < 3; k++) c[r * 3 + col] += a[r * 3 + k] * b[k * 3 + col];
    }
  }
  return c;
}

export function invertMatrix3(m: number[]): number[] {
  const [a, b, c, d, e, f, g, h, k] = m;
  const det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
  if (Math.abs(det) < 1e-10) return new Array<number>(9).fill(0);
  const inv = 1 / det;
  return [
    (e * k - f * h) * inv,
    (c * h - b * k) * inv,
    (b * f - c * e) * inv,
    (f * g - d * k) * inv,
    (a * k - c * g) * inv,
    (c * d - a * f) * inv,
    (d * h - e * g) * inv,
    (b * g - a * h) * inv,
    (a * e - b * d) * inv,
  ];
}

/** Résolution d'un système 8×8 par élimination de Gauss avec pivot partiel. */
function gaussianElim(a: number[][], b: number[]): number[] {
  const n = 8;
  const m = a.map((row, i) => [...row, b[i]]);
  for (let col = 0; col < n; col++) {
    let maxRow = col;
    for (let row = col + 1; row < n; row++) {
      if (Math.abs(m[row][col]) > Math.abs(m[maxRow][col])) maxRow = row;
    }
    [m[col], m[maxRow]] = [m[maxRow], m[col]];
    if (Math.abs(m[col][col]) < 1e-12) continue;
    for (let row = col + 1; row < n; row++) {
      const factor = m[row][col] / m[col][col];
      for (let k = col; k <= n; k++) m[row][k] -= factor * m[col][k];
    }
  }
  const x = new Array<number>(n).fill(0);
  for (let i = n - 1; i >= 0; i--) {
    x[i] = m[i][n];
    for (let j = i + 1; j < n; j++) x[i] -= m[i][j] * x[j];
    if (Math.abs(m[i][i]) > 1e-12) x[i] /= m[i][i];
  }
  return x;
}

/** Homographie qui envoie `src` sur `dst`, en 3×3 ligne par ligne. */
export function computeHomography(src: Quad, dst: Quad): number[] {
  const tSrc = hartleyNormMatrix(src);
  const tDst = hartleyNormMatrix(dst);
  const srcN = applyNormMatrix(tSrc, src);
  const dstN = applyNormMatrix(tDst, dst);

  const a: number[][] = [];
  const b: number[] = [];
  for (let i = 0; i < 4; i++) {
    const { x: xi, y: yi } = srcN[i];
    const { x: xp, y: yp } = dstN[i];
    a.push([xi, yi, 1, 0, 0, 0, -xp * xi, -xp * yi]);
    b.push(xp);
    a.push([0, 0, 0, xi, yi, 1, -yp * xi, -yp * yi]);
    b.push(yp);
  }
  const hNorm = [...gaussianElim(a, b), 1];

  // H = T_dst⁻¹ · H_norm · T_src
  return mulMat3(mulMat3(invertMatrix3(tDst), hNorm), tSrc);
}

/**
 * Dimensions du rectangle de sortie, déduites du quadrilatère.
 *
 * Moyenne GÉOMÉTRIQUE des deux bords opposés, et non le plus grand des deux :
 * en perspective, le bord proche est plus long que le bord lointain, et retenir
 * le maximum étire l'image dans un sens. La moyenne géométrique estime la vraie
 * dimension du document.
 */
export function outputSize(quad: Quad): { width: number; height: number } {
  const top = distance(quad[0], quad[1]);
  const bottom = distance(quad[3], quad[2]);
  const left = distance(quad[0], quad[3]);
  const right = distance(quad[1], quad[2]);
  return {
    width: Math.round(Math.sqrt(top * bottom)),
    height: Math.round(Math.sqrt(left * right)),
  };
}

/**
 * Le quadrilatère est-il assez proche d'un rectangle pour qu'un simple découpage
 * suffise ?
 *
 * Redresser coûte une boucle sur chaque pixel de sortie. Quand la page est déjà
 * droite — un scan à plat, une capture d'écran — la transformation ne change
 * rien de visible et le découpage rectangulaire, lui, préserve la netteté
 * d'origine sans ré-échantillonner.
 */
export function isNearlyRectangular(quad: Quad, tolerance = 0.02): boolean {
  const width = Math.max(distance(quad[0], quad[1]), distance(quad[3], quad[2]));
  const height = Math.max(distance(quad[0], quad[3]), distance(quad[1], quad[2]));
  if (width < 1 || height < 1) return true;

  const ecartHorizontal = Math.abs(quad[0].y - quad[1].y) + Math.abs(quad[3].y - quad[2].y);
  const ecartVertical = Math.abs(quad[0].x - quad[3].x) + Math.abs(quad[1].x - quad[2].x);
  return ecartHorizontal / height < tolerance && ecartVertical / width < tolerance;
}

/**
 * Redresse la zone délimitée par `quad` et rend un JPEG rectangulaire.
 *
 * Interpolation bilinéaire : sans elle, une image redressée porte des escaliers
 * sur chaque diagonale, et c'est précisément ce qu'on cherchait à corriger.
 */
export async function warpQuadrilateral(bytes: Buffer, quad: Quad): Promise<Buffer> {
  // Redressée d'abord : le modèle a vu l'image debout, ses coins sont dans ce
  // repère-là. Et réduite si elle est immense — la boucle est en clair, et une
  // photo de vingt mégapixels y passerait plusieurs secondes pour un résultat
  // qu'aucun écran ne distingue.
  const upright = sharp(bytes).rotate();
  const meta = await upright.metadata();
  const srcW = meta.width ?? 0;
  const srcH = meta.height ?? 0;
  if (srcW === 0 || srcH === 0) throw new Error("Image illisible : dimensions inconnues.");

  const facteur = Math.min(1, MAX_WORK_DIMENSION / Math.max(srcW, srcH));
  const workW = Math.round(srcW * facteur);
  const workH = Math.round(srcH * facteur);

  const { data, info } = await upright
    .resize(workW, workH)
    .raw()
    .toBuffer({ resolveWithObject: true });

  const channels = info.channels;
  const source: Quad = quad.map((p) => ({ x: p.x * facteur, y: p.y * facteur })) as Quad;
  const { width: outW, height: outH } = outputSize(source);
  if (outW < 8 || outH < 8) throw new Error("Zone à redresser trop petite.");

  const destination: Quad = [
    { x: 0, y: 0 },
    { x: outW, y: 0 },
    { x: outW, y: outH },
    { x: 0, y: outH },
  ];
  const inverse = invertMatrix3(computeHomography(source, destination));

  const out = Buffer.alloc(outW * outH * channels);
  for (let y = 0; y < outH; y++) {
    for (let x = 0; x < outW; x++) {
      const denom = inverse[6] * x + inverse[7] * y + inverse[8];
      const sx = (inverse[0] * x + inverse[1] * y + inverse[2]) / denom;
      const sy = (inverse[3] * x + inverse[4] * y + inverse[5]) / denom;
      sampleBilinear(
        out,
        (y * outW + x) * channels,
        data,
        info.width,
        info.height,
        channels,
        sx,
        sy,
      );
    }
  }

  return sharp(out, { raw: { width: outW, height: outH, channels } })
    .jpeg({ quality: 90 })
    .toBuffer();
}

/** Écrit dans `out` le pixel de `src` aux coordonnées fractionnaires (sx, sy). */
function sampleBilinear(
  out: Buffer,
  outOffset: number,
  src: Buffer,
  srcW: number,
  srcH: number,
  channels: number,
  sx: number,
  sy: number,
): void {
  // Hors cadre : noir plutôt qu'une couleur de bord répétée. Une bande noire se
  // voit et se recadre ; un bord étiré passe pour de l'image.
  if (sx < 0 || sy < 0 || sx > srcW - 1 || sy > srcH - 1) {
    for (let c = 0; c < channels; c++) out[outOffset + c] = 0;
    return;
  }

  const x0 = Math.floor(sx);
  const y0 = Math.floor(sy);
  const x1 = Math.min(x0 + 1, srcW - 1);
  const y1 = Math.min(y0 + 1, srcH - 1);
  const fx = sx - x0;
  const fy = sy - y0;

  const i00 = (y0 * srcW + x0) * channels;
  const i10 = (y0 * srcW + x1) * channels;
  const i01 = (y1 * srcW + x0) * channels;
  const i11 = (y1 * srcW + x1) * channels;

  for (let c = 0; c < channels; c++) {
    const haut = src[i00 + c] * (1 - fx) + src[i10 + c] * fx;
    const bas = src[i01 + c] * (1 - fx) + src[i11 + c] * fx;
    out[outOffset + c] = Math.round(haut * (1 - fy) + bas * fy);
  }
}
