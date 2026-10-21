/**
 * Unités standard du référentiel `nutrition_units`, et ce que le semis écrit
 * sur chacune.
 *
 * Cette liste vivait côté client (`NutritionUnitsRepository.seedDefaultUnits`,
 * icône « Initialiser les unités par défaut » de l'écran Unités de mesure).
 * Elle est recopiée ici à l'identique en v0.24.40 et n'existe plus que côté
 * serveur : le semis passe par Admin › Backfills (`backfillDefaultUnitsFn`).
 *
 * La table de repli de `quantityConversion.ts` (`WEIGHT_UNIT_TO_GRAMS`,
 * `VOLUME_UNIT_TO_ML`) porte les mêmes grammages et volumes, mais ni libellé ni
 * alias, et des clés de plus (`gram`, `litres`…) : elle ne peut pas servir de
 * liste à semer. `defaultUnits.test.ts` vérifie que chaque unité ci-dessous a
 * le même facteur que cette table.
 *
 * Règle de modèle : une unité de VOLUME ne porte QUE son volume. Les grammes
 * dépendent de la densité de l'ingrédient et sont calculés à l'usage. Une
 * unité de COMPTAGE ne porte ni l'un ni l'autre.
 */

export type DefaultUnitType = "weight" | "volume" | "count";

export interface DefaultUnit {
  normalizedUnit: string;
  displayLabel: string;
  aliases: readonly string[];
  measurementType: DefaultUnitType;
  gramsPerUnit: number | null;
  volumeMlPerUnit: number | null;
}

function weight(id: string, label: string, aliases: string[], grams: number): DefaultUnit {
  return {
    normalizedUnit: id,
    displayLabel: label,
    aliases,
    measurementType: "weight",
    gramsPerUnit: grams,
    volumeMlPerUnit: null,
  };
}

function volume(id: string, label: string, aliases: string[], ml: number): DefaultUnit {
  return {
    normalizedUnit: id,
    displayLabel: label,
    aliases,
    measurementType: "volume",
    gramsPerUnit: null,
    volumeMlPerUnit: ml,
  };
}

export const DEFAULT_NUTRITION_UNITS: readonly DefaultUnit[] = [
  // ── Poids ──────────────────────────────────────────────────────────────────
  weight("g", "Gramme", ["gramme", "grammes", "gr"], 1),
  weight("kg", "Kilogramme", ["kilogramme", "kilogrammes"], 1000),
  weight("mg", "Milligramme", ["milligramme", "milligrammes"], 0.001),
  // ── Petites mesures à poids fixe ───────────────────────────────────────────
  weight("pincee", "Pincée", ["pincee", "pincees", "pinch"], 0.5),
  weight("pointe_de_couteau", "Pointe de couteau", ["pointe", "pointe de couteau"], 1),
  // ── Unités botaniques ──────────────────────────────────────────────────────
  weight("brin", "Brin", ["brins", "sprig"], 2),
  weight("filet", "Filet", ["filets", "drizzle"], 5),
  weight("bouquet", "Bouquet", ["bouquets", "bunch"], 30),
  weight("feuille", "Feuille", ["feuilles", "leaf"], 1),
  weight("branche", "Branche", ["branches"], 15),
  weight("tige", "Tige", ["tiges", "stem"], 3),
  weight("noisette", "Noisette", ["noisettes", "knob"], 5),
  weight("zeste", "Zeste", ["zestes"], 3),
  // ── Volumes de base ────────────────────────────────────────────────────────
  volume("ml", "Millilitre", ["millilitre", "millilitres"], 1),
  volume("cl", "Centilitre", ["centilitre", "centilitres"], 10),
  volume("dl", "Décilitre", ["decilitre", "decilitres"], 100),
  volume("l", "Litre", ["litre", "litres", "liter"], 1000),
  // ── Cuillères ──────────────────────────────────────────────────────────────
  volume("c_a_c", "Cuillère à café", ["cc", "cac", "tsp", "c.a.c", "c. à c."], 5),
  volume("c_a_the", "Cuillère à thé", ["cuillere a the", "c. à t."], 5),
  volume("c_a_d", "Cuillère à dessert", ["cad", "c.a.d", "c. à d."], 10),
  volume("c_a_s", "Cuillère à soupe", ["cs", "cas", "tbsp", "c.a.s", "c. à s."], 15),
  // ── Verres / tasses / contenants ───────────────────────────────────────────
  volume("verre", "Verre moyen", ["verres", "verre_standard"], 200),
  volume("grand_verre", "Grand verre à moutarde", ["grand_verre", "verre_200"], 200),
  volume("verre_vin", "Verre à vin", ["verre_a_vin", "verre vin"], 120),
  volume("tasse", "Tasse", ["tasses", "cup", "cups"], 240),
  volume("tasse_a_cafe", "Tasse à café", ["tasses_a_cafe"], 70),
  volume("tasse_metrique", "Tasse métrique", ["tasses_metriques"], 250),
  volume("bol", "Bol de cuisine", ["bols"], 350),
  volume("quart_de_litre", "Quart de litre", ["1/4 l", "quart_l", "25cl"], 250),
  volume("demi_litre", "Demi-litre", ["1/2 l", "demi_l", "50cl"], 500),
  // ── Mesures anglo-saxonnes ─────────────────────────────────────────────────
  volume("fl_oz", "Once liquide américaine", ["fl oz", "fl. oz."], 29.5),
  volume("uk_fl_oz", "Once liquide impériale", ["uk fl oz"], 28.4),
  volume("pinte_americaine", "Pinte américaine", ["pt us", "pt (US)"], 473),
  volume("pinte_imperiale", "Pinte impériale", ["pt uk", "pt (UK)"], 568),
  volume("quart_americain", "Quart américain", ["qt us", "qt (US)"], 946),
  volume("gallon_americain", "Gallon américain", ["gal us", "gal (US)"], 3785),
  volume("chopine", "Chopine", ["choppe"], 480),
  // ── Très petits volumes ────────────────────────────────────────────────────
  volume("larme", "Larme", ["larmes"], 0.05),
  volume("goutte", "Goutte", ["gouttes", "drop"], 0.05),
  // ── Comptage ───────────────────────────────────────────────────────────────
  {
    normalizedUnit: "piece",
    displayLabel: "Pièce / Unité",
    aliases: ["unité", "unite", "pcs", "pce", "un"],
    measurementType: "count",
    gramsPerUnit: null,
    volumeMlPerUnit: null,
  },
];

/** Ce que le semis fait d'une unité : la créer, la compléter, ou rien. */
export type DefaultUnitPlan =
  | { action: "create"; fields: Record<string, unknown> }
  | { action: "patch"; fields: Record<string, unknown> }
  | { action: "unchanged" };

/**
 * Décision du semis pour une unité standard, sans horodatage : l'appelant
 * ajoute `created_at`, `updated_at`… Même règle que l'ancien semis du client :
 *
 *  - document absent : création complète, statut `known`, source `builtin` ;
 *  - document présent : seuls les champs manquants sont complétés —
 *    `grams_per_unit` et `volume_ml_per_unit` absents ou nuls,
 *    `display_label` absent ou vide, `measurement_type` égal à `unknown`.
 *    Le statut passe alors à `known`, et une source `fallback_auto` devient
 *    `builtin`. Une valeur présente n'est jamais écrasée ;
 *  - rien de manquant : aucune écriture, même si le statut n'est pas `known`.
 *
 * Un champ mal formé (libellé ou type qui n'est pas une chaîne) compte comme
 * une valeur présente : il n'est pas réécrit. L'ancien semis du client
 * s'arrêtait sur une exception de conversion à cet endroit.
 */
export function defaultUnitPlan(
  existing: Record<string, unknown> | null,
  unit: DefaultUnit,
): DefaultUnitPlan {
  if (existing == null) {
    return {
      action: "create",
      fields: {
        normalized_unit: unit.normalizedUnit,
        display_label: unit.displayLabel,
        aliases: [...unit.aliases],
        measurement_type: unit.measurementType,
        grams_per_unit: unit.gramsPerUnit,
        volume_ml_per_unit: unit.volumeMlPerUnit,
        status: "known",
        source: "builtin",
        seen_count: 0,
      },
    };
  }

  const missingGrams = existing.grams_per_unit == null && unit.gramsPerUnit != null;
  const missingVolume = existing.volume_ml_per_unit == null && unit.volumeMlPerUnit != null;
  const label = existing.display_label;
  const missingLabel =
    (label == null || (typeof label === "string" && label.length === 0)) &&
    unit.displayLabel.length > 0;
  const missingType = existing.measurement_type === "unknown";

  if (!missingGrams && !missingVolume && !missingLabel && !missingType) {
    return { action: "unchanged" };
  }

  const fields: Record<string, unknown> = {};
  if (missingGrams) fields.grams_per_unit = unit.gramsPerUnit;
  if (missingVolume) fields.volume_ml_per_unit = unit.volumeMlPerUnit;
  if (missingLabel) fields.display_label = unit.displayLabel;
  if (missingType) fields.measurement_type = unit.measurementType;
  if (existing.status !== "known") fields.status = "known";
  if (existing.source === "fallback_auto") fields.source = "builtin";
  return { action: "patch", fields };
}
