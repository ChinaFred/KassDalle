/**
 * La planche des quatre orientations : le programme fait tourner, le modèle lit.
 *
 * Porté de `sandbox_image_ops.dart` (`sandboxOrientationSheetIsolate`), même
 * géométrie : quatre cases de 900 px en 2×2, un bandeau blanc de 72 px au-dessus
 * de chacune, la lettre dedans, et la vignette centrée sans déformation.
 *
 * Deux détails valent la peine d'être répétés ici, parce qu'ils viennent tous
 * deux d'un essai raté :
 *
 * - **la lettre n'est jamais écrite sur la page**, mais dans un bandeau
 *   au-dessus. Écrite par-dessus, elle se confond avec le texte imprimé et le
 *   modèle la lit comme une partie de la page.
 * - **la vignette garde ses proportions.** L'étirer pour remplir la case
 *   donnerait au modèle un indice qui n'existe pas : les quatre cases auraient
 *   alors la même forme, et une page couchée cesserait d'avoir l'air couchée.
 *
 * ## Les lettres sont dessinées, pas écrites
 *
 * Le Dart écrivait la lettre avec une police embarquée dans le paquet `image`.
 * Rien de tel ici : le conteneur des Cloud Functions n'a aucune police
 * installée, et un rendu de texte qui suppose une police disponible marche sur
 * la machine du développeur puis rend un carré vide en production.
 *
 * Les quatre glyphes sont donc des matrices de 5 × 7 points, agrandies. C'est
 * laid de près, parfaitement lisible à 900 px, et ça ne dépend de rien.
 */

import type sharpType from "sharp";

/** L'ordre des cases. La case A porte la page telle quelle. */
export const SHEET_ROTATIONS: readonly number[] = [0, 90, 180, 270];

/** Les lettres, dans le même ordre. */
export const SHEET_LABELS: readonly string[] = ["A", "B", "C", "D"];

/** Côté d'une case, en pixels. */
const CELL = 900;

/** Hauteur du bandeau qui porte la lettre. */
const BAND = 72;

/** Agrandissement d'un point de glyphe, en pixels. */
const GLYPH_SCALE = 8;

/**
 * Les quatre glyphes, un point par caractère.
 *
 * Seulement quatre : c'est tout ce dont la planche a besoin, et une police
 * complète serait quatre-vingts lignes pour rien.
 */
const GLYPHS: Record<string, string[]> = {
  A: ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  B: ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
  C: ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
  D: ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
};

/** Une lettre, en pixels RGBA : noir opaque sur transparent. */
function glyphBuffer(letter: string): {
  data: Buffer;
  width: number;
  height: number;
} {
  const rows = GLYPHS[letter];
  if (!rows) throw new Error(`Glyphe inconnu : ${letter}`);
  const width = rows[0].length * GLYPH_SCALE;
  const height = rows.length * GLYPH_SCALE;
  const data = Buffer.alloc(width * height * 4, 0);

  for (let row = 0; row < rows.length; row++) {
    for (let col = 0; col < rows[row].length; col++) {
      if (rows[row][col] !== "1") continue;
      for (let dy = 0; dy < GLYPH_SCALE; dy++) {
        for (let dx = 0; dx < GLYPH_SCALE; dx++) {
          const offset = ((row * GLYPH_SCALE + dy) * width + col * GLYPH_SCALE + dx) * 4;
          data[offset] = 0;
          data[offset + 1] = 0;
          data[offset + 2] = 0;
          data[offset + 3] = 255;
        }
      }
    }
  }
  return { data, width, height };
}

export interface OrientationSheet {
  bytes: Buffer;
  width: number;
  height: number;
}

/**
 * Compose les quatre orientations de la page en une seule planche 2×2.
 *
 * « De combien de degrés faut-il tourner cette page » est une question de
 * raisonnement spatial, et un modèle y répond mal — il a affirmé à 98 % qu'une
 * page couchée était droite. « Laquelle de ces quatre pages se lit » est de la
 * reconnaissance, et il y répond bien.
 *
 * Les quatre rotations coûtent quatre permutations de pixels, et l'appel au
 * modèle reste unique.
 */
export async function buildOrientationSheet(bytes: Buffer): Promise<OrientationSheet> {
  const { default: sharp } = await import("sharp");

  const sheetWidth = CELL * 2;
  const sheetHeight = (CELL + BAND) * 2;

  const layers: sharpType.OverlayOptions[] = [];

  for (let index = 0; index < SHEET_ROTATIONS.length; index++) {
    const rotation = SHEET_ROTATIONS[index];
    const column = index % 2;
    const row = Math.floor(index / 2);
    const cellX = column * CELL;
    const cellY = row * (CELL + BAND);

    // `fit: "inside"` conserve les proportions et ne remplit pas la case : une
    // page couchée reste couchée, ce qui est justement l'indice recherché.
    const thumb = await sharp(bytes)
      .rotate(rotation)
      .resize(CELL, CELL, { fit: "inside", withoutEnlargement: false })
      .toBuffer({ resolveWithObject: true });

    const bandeau = await sharp({
      create: {
        width: CELL,
        height: BAND,
        channels: 3,
        background: { r: 255, g: 255, b: 255 },
      },
    })
      .png()
      .toBuffer();

    const glyph = glyphBuffer(SHEET_LABELS[index]);

    layers.push(
      { input: bandeau, left: cellX, top: cellY },
      {
        input: glyph.data,
        raw: { width: glyph.width, height: glyph.height, channels: 4 },
        left: cellX + 16,
        top: cellY + Math.round((BAND - glyph.height) / 2),
      },
      {
        input: thumb.data,
        left: cellX + Math.round((CELL - thumb.info.width) / 2),
        top: cellY + BAND + Math.round((CELL - thumb.info.height) / 2),
      },
    );
  }

  const composed = await sharp({
    create: {
      width: sheetWidth,
      height: sheetHeight,
      channels: 3,
      background: { r: 240, g: 240, b: 240 },
    },
  })
    .composite(layers)
    .jpeg({ quality: 88 })
    .toBuffer();

  return { bytes: composed, width: sheetWidth, height: sheetHeight };
}
