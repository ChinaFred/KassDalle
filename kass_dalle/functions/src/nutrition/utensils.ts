/**
 * Ustensiles et consommables de cuisine : une liste fermée.
 *
 * Le balisage écrivait parfois « @papier sulfurisé{} » au lieu de
 * « #papier sulfurisé{} ». Le nom entrait alors dans la liste d'ingrédients,
 * puis dans le référentiel : une fiche `nutrition_ingredients/papier_sulfurise`
 * naissait, avec une demande de valeurs nutritionnelles au modèle. La règle du
 * prompt qui l'interdisait a disparu le 20 août 2026 (v0.21.31), et rien,
 * après le modèle, ne vérifiait ce point.
 *
 * Cette liste est ce contrôle. Un nom reconnu :
 * - n'entre pas dans la liste d'ingrédients que le parseur CookLang dérive ;
 * - est retiré de la liste rendue par le balisage, et son `@nom{…}` devient
 *   `#nom{…}` dans le texte (`retagUtensils`, serveur seul) ;
 * - ne crée ni ne met à jour aucune fiche du référentiel.
 *
 * Fermée, et sans aliment : « moule » seul est le mollusque, « ficelle » seule
 * le pain, « brochette » seule le plat. Un nom absent de la liste reste un
 * ingrédient ; l'ajouter se fait ici ET dans `lib/core/utils/utensils.dart`,
 * avec son cas dans `test-fixtures/utensils.json`.
 */

import { depluralizeToken, normalizeIngredientStrictId } from "./ingredientName";

/** La liste, dans l'ordre de la fixture partagée. */
export const UTENSIL_NAMES: readonly string[] = [
  "papier sulfurisé",
  "papier cuisson",
  "papier de cuisson",
  "papier aluminium",
  "papier d'aluminium",
  "papier alu",
  "aluminium",
  "film alimentaire",
  "film étirable",
  "papier film",
  "papier absorbant",
  "essuie-tout",
  "tapis de cuisson",
  "tapis en silicone",
  "cure-dent",
  "pique à brochette",
  "pic à brochette",
  "pique en bois",
  "brochette en bois",
  "ficelle de cuisine",
  "ficelle alimentaire",
  "fil de cuisine",
  "poche à douille",
  "douille",
  "caissette",
  "cercle à pâtisserie",
  "cercle à tarte",
  "cercle à entremets",
  "emporte-pièce",
  "étamine",
  "ramequin",
  "sac de congélation",
  "sachet de congélation",
  "moule à tarte",
  "moule à tartelette",
  "moule à manqué",
  "moule à cake",
  "moule à gâteau",
  "moule à charnière",
  "moule à savarin",
  "moule à kouglof",
  "moule à muffin",
  "moule à madeleine",
  "moule à cannelé",
  "moule à soufflé",
  "moule à brioche",
  "moule à financier",
  "moule à quiche",
  "moule à gratin",
  "moule à pain",
  "moule en silicone",
];

/** Mots de tête sans contenu : articles et tailles (« 1 grande feuille de… »). */
const LEADING_NOISE = new Set<string>([
  "un",
  "une",
  "des",
  "du",
  "de",
  "d",
  "l",
  "le",
  "la",
  "les",
  "grand",
  "grande",
  "petit",
  "petite",
]);

/** Unités de dimension retirées partout (« cercle de 20 cm »). */
const DIMENSION_UNITS = new Set<string>(["cm", "mm"]);

/** Contenants de tête : « feuille de papier sulfurisé », « rouleau de film ». */
const CONTAINERS = new Set<string>([
  "feuille",
  "morceau",
  "bande",
  "rouleau",
  "carre",
  "rectangle",
]);

/** Qualificatifs de fin d'un seul mot. */
const TRAILING_WORDS = new Set<string>([
  "de",
  "d",
  "environ",
  "inox",
  "jetable",
  "individuel",
  "individuelle",
]);

/**
 * Matières introduites par « en » en fin de nom : « piques en bois ».
 *
 * Comparées après dépluralisation, comme les mots du texte : « bois » y
 * devient « boi ».
 */
const TRAILING_MATERIALS = new Set<string>(
  ["bois", "papier", "silicone", "metal", "inox", "alu"].map(depluralizeToken),
);

/** Mots normalisés d'un texte : identité stricte, pluriel régulier retiré mot par mot. */
function utensilTokens(text: string): string[] {
  const withoutParentheses = text.replace(/\([^)]*\)/g, " ");
  return normalizeIngredientStrictId(withoutParentheses)
    .split("_")
    .filter((t) => t.length > 0)
    .map(depluralizeToken);
}

function stripTrailingQualifiers(tokens: string[]): string[] {
  const out = [...tokens];
  for (;;) {
    const last = out[out.length - 1];
    if (out.length > 1 && TRAILING_WORDS.has(last)) {
      out.pop();
      continue;
    }
    if (out.length > 2 && out[out.length - 2] === "en" && TRAILING_MATERIALS.has(last)) {
      out.splice(out.length - 2, 2);
      continue;
    }
    return out;
  }
}

const UTENSIL_KEYS = new Set<string>(UTENSIL_NAMES.map((n) => utensilTokens(n).join("_")));

/**
 * Vrai quand le texte — un nom d'ingrédient ou une ligne du livre — désigne un
 * ustensile de la liste fermée.
 *
 * Ce qui est ignoré avant la comparaison : parenthèses, nombres, cm et mm,
 * articles et « grand / petit » de tête. Puis on essaie le nom tel quel, sans
 * contenant de tête (« feuille de »), et sans qualificatif de fin
 * (« en bois », « inox », « de » resté d'une dimension retirée). La comparaison
 * reste une ÉGALITÉ avec un nom de la liste : « feuille de brick » donne
 * « brick », qui n'y est pas.
 */
export function isUtensil(text: string): boolean {
  let tokens = utensilTokens(text).filter((t) => !/^\d+$/.test(t) && !DIMENSION_UNITS.has(t));
  while (tokens.length > 0 && LEADING_NOISE.has(tokens[0])) tokens = tokens.slice(1);
  if (tokens.length === 0) return false;

  const candidates: string[][] = [tokens];
  if (tokens.length > 2 && CONTAINERS.has(tokens[0]) && (tokens[1] === "de" || tokens[1] === "d")) {
    candidates.push(tokens.slice(2));
  }
  for (const candidate of [...candidates]) candidates.push(stripTrailingQualifiers(candidate));
  return candidates.some((c) => c.length > 0 && UTENSIL_KEYS.has(c.join("_")));
}

/**
 * Réécrit en `#nom{…}` chaque `@nom{…}` qui désigne un ustensile — serveur seul.
 *
 * Les accolades sont conservées telles quelles : `#papier sulfurisé{1%feuille}`
 * reste une écriture CookLang valide pour un ustensile. Le reste du texte n'est
 * pas touché.
 */
export function retagUtensils(cooklang: string): string {
  return cooklang.replace(/@([^{@#~\n]+)\{([^}]*)\}/g, (match, name: string, inner: string) =>
    isUtensil(name.trim()) ? `#${name}{${inner}}` : match,
  );
}
