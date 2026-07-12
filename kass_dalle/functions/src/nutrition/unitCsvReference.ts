/**
 * Référentiel des unités de mesure culinaires, issu du fichier "units ref.csv".
 * Source : Libellé, Abréviation, Équivalence en Volume, Poids Moyen constaté.
 *
 * Ce fichier est la source de vérité statique pour initialiser la collection
 * Firestore `nutrition_units` via le backfill `initNutritionUnitsFromCsvFn`.
 */

export interface CsvUnitEntry {
  /** Libellé humain complet (ex: "Cuillère à soupe"). */
  label: string;
  /** Abréviation usuelle (ex: "c. à s."). */
  abbreviation: string;
  /** ID document Firestore normalisé (ex: "c_a_s"). */
  normalizedUnit: string;
  /** Tous les alias à indexer (libellé + abréviation + variantes). */
  aliases: string[];
  /** Type de mesure. */
  measurementType: "weight" | "volume";
  /** Volume en millilitres (undefined pour les unités poids-only). */
  volumeMl?: number;
  /** Poids moyen constaté en grammes (eau / ingrédient typique). */
  gramsPerUnit: number;
}

/**
 * Données du CSV "units ref.csv" converties en tableau TypeScript.
 * Ordre identique au fichier source.
 */
export const CSV_UNIT_REFERENCE: CsvUnitEntry[] = [
  {
    label: "Larme",
    abbreviation: "larme",
    normalizedUnit: "larme",
    aliases: ["larme", "larmes"],
    measurementType: "volume",
    volumeMl: 0.05,
    gramsPerUnit: 0.05,
  },
  {
    label: "Goutte",
    abbreviation: "goutte",
    normalizedUnit: "goutte",
    aliases: ["goutte", "gouttes", "drop"],
    measurementType: "volume",
    volumeMl: 0.05,
    gramsPerUnit: 0.05,
  },
  {
    label: "Pincée",
    abbreviation: "pin",
    normalizedUnit: "pincee",
    aliases: ["pincée", "pincee", "pincées", "pincees", "pin", "pinch", "pinchs"],
    measurementType: "weight",
    gramsPerUnit: 0.5,
  },
  {
    label: "Pointe de couteau",
    abbreviation: "poi",
    normalizedUnit: "pointe_de_couteau",
    aliases: ["pointe de couteau", "pointe_de_couteau", "poi", "pointe"],
    measurementType: "weight",
    gramsPerUnit: 1,
  },
  {
    label: "Cuillère à café",
    abbreviation: "c. à c.",
    normalizedUnit: "c_a_c",
    aliases: ["c. à c.", "c. à café", "c_a_c", "cac", "cc", "c_c", "tsp", "teaspoon", "teaspoons", "cuillère à café", "cuillere_a_cafe"],
    measurementType: "volume",
    volumeMl: 5,
    gramsPerUnit: 5,
  },
  {
    label: "Cuillère à dessert",
    abbreviation: "c. à d.",
    normalizedUnit: "c_a_d",
    aliases: ["c. à d.", "c_a_d", "cad", "cuillère à dessert", "cuillere_a_dessert", "cuilleres_a_dessert"],
    measurementType: "volume",
    volumeMl: 10,
    gramsPerUnit: 10,
  },
  {
    label: "Cuillère à soupe",
    abbreviation: "c. à s.",
    normalizedUnit: "c_a_s",
    aliases: ["c. à s.", "c. à soupe", "c_a_s", "cas", "cs", "c_s", "tbsp", "tablespoon", "tablespoons", "cuillère à soupe", "cuillere_a_soupe"],
    measurementType: "volume",
    volumeMl: 15,
    gramsPerUnit: 15,
  },
  {
    label: "Once liquide américaine",
    abbreviation: "fl. oz.",
    normalizedUnit: "fl_oz",
    aliases: ["fl. oz.", "fl_oz", "fl oz", "once liquide américaine", "once_liquide_americaine"],
    measurementType: "volume",
    volumeMl: 29.5,
    gramsPerUnit: 30,
  },
  {
    label: "Once liquide impériale",
    abbreviation: "uk fl. oz.",
    normalizedUnit: "uk_fl_oz",
    aliases: ["uk fl. oz.", "uk_fl_oz", "uk fl oz", "once liquide impériale", "once_liquide_imperiale"],
    measurementType: "volume",
    volumeMl: 28.4,
    gramsPerUnit: 28,
  },
  {
    label: "Tasse à café",
    abbreviation: "tas",
    normalizedUnit: "tasse_a_cafe",
    aliases: ["tasse à café", "tasse_a_cafe", "tas", "tasses à café", "tasses_a_cafe"],
    measurementType: "volume",
    volumeMl: 70,
    gramsPerUnit: 65,
  },
  {
    label: "Décilitre",
    abbreviation: "dl",
    normalizedUnit: "dl",
    aliases: ["dl", "décilitre", "decilitre", "décilitres", "decilitres"],
    measurementType: "volume",
    volumeMl: 100,
    gramsPerUnit: 90,
  },
  {
    label: "Verre à vin ordinaire",
    abbreviation: "verre vin",
    normalizedUnit: "verre_vin",
    aliases: ["verre à vin", "verre_vin", "verre vin", "verre_a_vin", "verres à vin"],
    measurementType: "volume",
    volumeMl: 120,
    gramsPerUnit: 130,
  },
  {
    label: "Tasse américaine",
    abbreviation: "cup",
    normalizedUnit: "tasse",
    aliases: ["cup", "cups", "tasse américaine", "tasse_americaine", "tasse", "tasses"],
    measurementType: "volume",
    volumeMl: 236,
    gramsPerUnit: 215,
  },
  {
    label: "Tasse métrique",
    abbreviation: "cup metric",
    normalizedUnit: "tasse_metrique",
    aliases: ["tasse métrique", "tasse_metrique", "cup métrique"],
    measurementType: "volume",
    volumeMl: 250,
    gramsPerUnit: 230,
  },
  {
    label: "Verre moyen",
    abbreviation: "verre",
    normalizedUnit: "verre",
    aliases: ["verre", "verres", "verre moyen", "verre_moyen"],
    measurementType: "volume",
    volumeMl: 200,
    gramsPerUnit: 200,
  },
  {
    label: "Grand verre à moutarde",
    abbreviation: "grd verre",
    normalizedUnit: "grand_verre",
    aliases: ["grand verre", "grand_verre", "grd verre", "grand verre à moutarde", "grand_verre_a_moutarde"],
    measurementType: "volume",
    volumeMl: 200,
    gramsPerUnit: 170,
  },
  {
    label: "Quart de litre",
    abbreviation: "1/4 l",
    normalizedUnit: "quart_de_litre",
    aliases: ["1/4 l", "1/4l", "quart de litre", "quart_de_litre", "quarter litre"],
    measurementType: "volume",
    volumeMl: 250,
    gramsPerUnit: 230,
  },
  {
    label: "Bol de cuisine",
    abbreviation: "bol",
    normalizedUnit: "bol",
    aliases: ["bol", "bols", "bol de cuisine"],
    measurementType: "volume",
    volumeMl: 350,
    gramsPerUnit: 350,
  },
  {
    label: "Chopine",
    abbreviation: "choppe",
    normalizedUnit: "chopine",
    aliases: ["chopine", "choppe", "chopines"],
    measurementType: "volume",
    volumeMl: 480,
    gramsPerUnit: 440,
  },
  {
    label: "Pinte américaine",
    abbreviation: "pt (US)",
    normalizedUnit: "pinte_americaine",
    aliases: ["pt (US)", "pt us", "pt_us", "pinte américaine", "pinte_americaine", "pint us"],
    measurementType: "volume",
    volumeMl: 473,
    gramsPerUnit: 430,
  },
  {
    label: "Pinte impériale",
    abbreviation: "pt (UK)",
    normalizedUnit: "pinte_imperiale",
    aliases: ["pt (UK)", "pt uk", "pt_uk", "pinte impériale", "pinte_imperiale", "pint uk"],
    measurementType: "volume",
    volumeMl: 568,
    gramsPerUnit: 520,
  },
  {
    label: "Demi-litre",
    abbreviation: "1/2 l",
    normalizedUnit: "demi_litre",
    aliases: ["1/2 l", "1/2l", "demi-litre", "demi_litre", "demi litre"],
    measurementType: "volume",
    volumeMl: 500,
    gramsPerUnit: 450,
  },
  {
    label: "Quart américain",
    abbreviation: "qt (US)",
    normalizedUnit: "quart_americain",
    aliases: ["qt (US)", "qt us", "qt_us", "quart américain", "quart_americain"],
    measurementType: "volume",
    volumeMl: 946,
    gramsPerUnit: 850,
  },
  {
    label: "Litre",
    abbreviation: "l",
    normalizedUnit: "litre",
    aliases: ["l", "litre", "litres", "liter", "liters"],
    measurementType: "volume",
    volumeMl: 1000,
    gramsPerUnit: 900,
  },
  {
    label: "Gallon américain",
    abbreviation: "gal (US)",
    normalizedUnit: "gallon_americain",
    aliases: ["gal (US)", "gal us", "gal_us", "gallon américain", "gallon_americain"],
    measurementType: "volume",
    volumeMl: 3785,
    gramsPerUnit: 3400,
  },
];
