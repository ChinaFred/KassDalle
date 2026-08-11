/**
 * Présentation et normalisation légère des quantités et unités.
 *
 * Fonctions PURES, sans accès Firestore ni Gemini : formatage d'une quantité,
 * libellé lisible d'une unité, inférence d'une unité depuis le nom d'un
 * ingrédient (« 2 gousses d'ail »), nettoyage des quantités non exploitables.
 *
 * Extrait de callable/nutritionCallable.ts, qui n'a plus à héberger que ses
 * points d'entrée HTTPS.
 */

import { parseQuantityToNumber } from "./quantityConversion";
import { normalizeIngredientCanonicalId } from "./ingredientName";

export function asPositiveNumber(value: unknown): number | null {
  return parseQuantityToNumber(value);
}

export function roundValue(value: number, digits = 2): number {
  const factor = Math.pow(10, digits);
  return Math.round(value * factor) / factor;
}

export const UNIT_LABEL_BY_CANONICAL: Record<string, string> = {
  c_a_c: "c.à.c.",
  c_a_s: "c.à.s.",
  c_a_d: "c.à.d.",
  piece: "pièce",
  pincee: "pincée",
  l: "L",
};

export function fallbackUnitLabel(normalizedUnit: string): string {
  if (!normalizedUnit) return "";
  return UNIT_LABEL_BY_CANONICAL[normalizedUnit] ?? normalizedUnit.replace(/_/g, " ");
}

export function parseQtyAndUnit(raw: string): { qty: string; unit: string } {
  const parts = raw.split("%");
  const qty = parts.length > 0 ? parts[0].trim() : "";
  const unit = parts.length > 1 ? parts.slice(1).join("%").trim() : "";
  return { qty, unit };
}

export function formatQtyAndUnit(qty: string, unit: string): string {
  if (!qty && !unit) return "";
  if (!unit) return qty;
  return `${qty}%${unit}`;
}

export function inferUnitFromIngredientName(args: {
  rawName: string;
  rawUnit: string;
}): { ingredientName: string; unit: string } {
  const initialName = args.rawName.trim();
  const initialUnit = args.rawUnit.trim();
  if (initialName.length == 0 || initialUnit.length > 0) {
    return { ingredientName: initialName, unit: initialUnit };
  }

  // Cas fréquent OCR/IA : l'unité est incluse dans le nom
  // ex: "brin de cerfeuil frais", "gousse d'ail".
  const match = initialName.match(
    /^(brin|brins|gousse|gousses|pinc[ée]e|pinc[ée]es|pi[èe]ce|pi[èe]ces|tranche|tranches|feuille|feuilles|bouquet|bouquets|branche|branches|filet|filets|tige|tiges|noisette|noisettes|zeste|zestes)\s+(?:de|d')\s+(.+)$/i,
  );
  if (!match) {
    return { ingredientName: initialName, unit: "" };
  }

  const unit = match[1].trim().toLowerCase();
  const ingredientName = match[2].trim(); // Conserve les qualificatifs ("frais", "séché"…) — identitaires pour la nutrition
  if (ingredientName.length == 0) {
    return { ingredientName: initialName, unit: "" };
  }
  return { ingredientName, unit };
}

/**
 * Singularisation algorithmique de repli : retire le « s » final (valable pour
 * la quasi-totalité des unités culinaires françaises).
 *
 * Utilisée quand Gemini, à qui la singularisation est normalement déléguée par
 * un appel batch, est indisponible.
 */
export function fallbackSingularize(unit: string): string {
  const t = unit.trim().toLowerCase();
  if (t.length > 2 && t.endsWith("s")) return t.slice(0, -1);
  return t;
}

// Ingrédients comptés à la pièce qui doivent recevoir « pièce » comme unité
// quand aucune unité n'est fournie (ni dans le champ unit, ni inférable du nom).
export const PIECE_INGREDIENT_IDS = [
  // Protéines portionnées
  "blanc_de_poulet",
  "filet_de_poulet",
  "haut_de_cuisse_de_poulet",
  "haut_de_cuisse",
  "cuisse_de_poulet",
  "escalope",
  "steak",
  "steack",
  "cote_de_veau",
  "cote_de_porc",
  "cote_d_agneau",
  "entrecote",
  "filet_mignon",
  "magret_de_canard",
  "magret",
  // Légumes/aromates typiquement comptés à la pièce
  "echalote",
  "oignon",
  "aubergine",
  "courgette",
  "poivron",
  "concombre",
  "navet",
  "poireau",
  "citron",
  "orange",
];

export function inferPieceUnitIfEmpty(ingredientName: string): string {
  const normalizedId = normalizeIngredientCanonicalId(ingredientName);
  if (!normalizedId) return "";
  return PIECE_INGREDIENT_IDS.some((pid) => normalizedId.includes(pid)) ? "pièce" : "";
}

// Quantités non numériques issues de l'extraction Gemini ("pour la cuisson",
// "à volonté", etc.) à traiter comme vides lors de la normalisation.
export const INVALID_QTY_PATTERNS: RegExp[] = [
  /^pour\s/i,
  /^à\s+volon/i,
  /^au\s+go[uû]t/i,
  /^qsp$/i,
  /^qs$/i,
  /^selon\s/i,
  /^un\s+peu/i,
  /^quelques$/i,
  /^suffisamment/i,
];

export function cleanQtyValue(qty: string): string {
  if (!qty) return "";
  return INVALID_QTY_PATTERNS.some((p) => p.test(qty.trim())) ? "" : qty;
}

