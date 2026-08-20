/**
 * Contrôle de fidélité entre la transcription et le balisage.
 *
 * Cent cinquante lignes de prompt demandaient de ne pas réécrire la recette.
 * Aucune ligne de code ne le constatait. Une consigne que rien ne vérifie est
 * un vœu : quand le modèle raccourcissait une étape ou fusionnait deux
 * ingrédients, la recette partait en base sans que personne le sache, et l'on
 * ne s'en apercevait qu'en rouvrant le livre.
 *
 * Ces vérifications ne coûtent aucun appel. Elles comparent ce que la passe 2 a
 * rendu à ce que la passe 1 lui avait donné — deux textes que nous possédons.
 *
 * Ce qu'elles NE font pas : juger la qualité du balisage. Un ingrédient mal
 * catégorisé passe. Ce qu'elles attrapent, c'est la DISPARITION et la FUSION,
 * les deux défauts qui rendent une recette fausse sans qu'elle en ait l'air.
 */

import type { TranscribedRecipe } from "./transcription";
import type { TaggedRecipe } from "./tagging";
import { ingredientLinesOf, stepCountOf } from "./tagging";

export type FidelityLevel = "ok" | "avertissement" | "rupture";

export interface FidelityFinding {
  /** Identifiant court, pour compter les occurrences dans les journaux. */
  code: string;
  /** Ce qui ne va pas, en français, sans jargon. */
  message: string;
  level: FidelityLevel;
}

export interface FidelityReport {
  level: FidelityLevel;
  findings: FidelityFinding[];
  /** Vrai quand le texte balisé ne peut pas être retenu tel quel. */
  rejette: boolean;
}

/**
 * Lignes d'étapes d'un texte CookLang : ni métadonnées, ni sections, ni notes,
 * ni lignes vides. Une continuation (« + ») appartient à l'étape précédente et
 * ne compte donc pas pour une étape de plus.
 */
export function cooklangStepLines(cooklang: string): string[] {
  return cooklang
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(
      (l) =>
        l.length > 0 &&
        !l.startsWith(">>") &&
        !l.startsWith(">") &&
        !l.startsWith("==") &&
        !l.startsWith("+"),
    );
}

/** Titres de section d'un texte CookLang, dans l'ordre. */
export function cooklangSectionTitles(cooklang: string): string[] {
  const out: string[] = [];
  for (const raw of cooklang.split(/\r?\n/)) {
    const line = raw.trim();
    const match = /^==\s*(.+?)\s*==$/.exec(line);
    if (match) out.push(match[1].trim());
  }
  return out;
}

/**
 * Forme comparable d'un titre : casse, accents et ponctuation de bord ignorés.
 *
 * Le prompt demande le titre « caractère pour caractère », mais exiger l'égalité
 * stricte ferait échouer sur « POUR LA SAUCE » rendu « Pour la sauce » — une
 * normalisation de casse explicitement autorisée. Ce qu'on traque est la perte
 * de MOTS : « Pour la sauce à l'aneth et à la moutarde » devenu « Pour la
 * sauce ».
 */
function comparableTitle(title: string): string {
  return title
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Tolérance sur le nombre d'étapes, en proportion de l'original. */
const TOLERANCE_ETAPES = 0.2;

/**
 * Confronte le balisage à la transcription.
 *
 * Deux niveaux, et la distinction compte : un « avertissement » se journalise
 * et laisse passer, une « rupture » fait retomber la recette sur le texte
 * verbatim de la transcription. On ne jette une sortie que lorsqu'elle est
 * démontrablement amputée — refuser sur un doute reviendrait à priver
 * l'utilisateur d'un balisage correct pour une virgule.
 */
export function checkFidelity(
  transcribed: TranscribedRecipe,
  tagged: TaggedRecipe,
): FidelityReport {
  const findings: FidelityFinding[] = [];

  // ── Les ingrédients : une ligne du livre, une entrée ─────────────────────
  const lignes = ingredientLinesOf(transcribed);
  const rendus = tagged.ingredients.length;
  if (lignes.length > 0 && rendus !== lignes.length) {
    findings.push({
      code: "ingredients_compte",
      message: `${rendus} ingrédient(s) normalisé(s) pour ${lignes.length} ligne(s) dans le livre.`,
      // Moins d'entrées que de lignes : des ingrédients ont été fusionnés ou
      // perdus, et ils manqueront aux courses comme à la nutrition. Plus
      // d'entrées : le modèle en a inventé.
      level: rendus < lignes.length ? "rupture" : "avertissement",
    });
  }

  // ── Les étapes : autant en sortie qu'en entrée ───────────────────────────
  const etapesAttendues = stepCountOf(transcribed);
  const etapesRendues = cooklangStepLines(tagged.cooklang).length;
  if (etapesAttendues > 0) {
    const ecart = Math.abs(etapesRendues - etapesAttendues) / etapesAttendues;
    if (ecart > TOLERANCE_ETAPES) {
      findings.push({
        code: "etapes_compte",
        message: `${etapesRendues} étape(s) balisée(s) pour ${etapesAttendues} transcrite(s).`,
        // Un résumé enlève des étapes ; c'est le défaut grave. En ajouter est
        // le plus souvent un découpage de phrase, gênant mais pas faux.
        level: etapesRendues < etapesAttendues ? "rupture" : "avertissement",
      });
    }
  }

  // ── Les titres de section : aucun mot perdu ──────────────────────────────
  const titresAttendus = [
    ...new Set(
      [...transcribed.sectionsIngredients, ...transcribed.sectionsEtapes]
        .map((s) => s.titre)
        .filter((t) => t.length > 0)
        .map(comparableTitle),
    ),
  ];
  const titresRendus = cooklangSectionTitles(tagged.cooklang).map(comparableTitle);
  const manquants = titresAttendus.filter((t) => !titresRendus.includes(t));
  if (manquants.length > 0) {
    findings.push({
      code: "sections_titres",
      message: `Titre(s) de section absent(s) ou raccourci(s) : ${manquants.join(" / ")}.`,
      // Raccourcir « Pour la sauce à l'aneth et à la moutarde » en « Pour la
      // sauce » ne casse aucun écran — mais deux sauces d'une même recette
      // deviennent indiscernables, et leurs ingrédients se confondent.
      level: "avertissement",
    });
  }

  // ── Un texte balisé vide n'est pas un texte ──────────────────────────────
  if (tagged.cooklang.trim().length === 0) {
    findings.push({
      code: "cooklang_vide",
      message: "Le balisage n'a rendu aucun texte.",
      level: "rupture",
    });
  }

  const level: FidelityLevel = findings.some((f) => f.level === "rupture")
    ? "rupture"
    : findings.some((f) => f.level === "avertissement")
      ? "avertissement"
      : "ok";

  return { level, findings, rejette: level === "rupture" };
}

/**
 * Texte CookLang de repli, bâti depuis la seule transcription.
 *
 * Sans balise : mieux vaut une recette exacte et non balisée qu'une recette
 * balisée et fausse. Les ingrédients restent exploitables — ils viennent de la
 * transcription, pas du balisage rejeté — et l'utilisateur peut relancer un
 * raffinage depuis l'éditeur.
 */
export function verbatimCooklang(recipe: TranscribedRecipe): string {
  const out: string[] = [];
  out.push(`>> titre: ${recipe.titre}`);
  if (recipe.page != null) out.push(`>> page: ${recipe.page}`);
  if (recipe.portions != null) out.push(`>> portions: ${recipe.portions}`);
  if (recipe.difficulte) out.push(`>> difficulté: ${recipe.difficulte}`);
  if (recipe.tempsPreparation) out.push(`>> temps_préparation: ${recipe.tempsPreparation}`);
  if (recipe.tempsCuisson) out.push(`>> temps_cuisson: ${recipe.tempsCuisson}`);
  out.push("");

  for (const section of recipe.sectionsEtapes) {
    if (section.titre) out.push(`== ${section.titre} ==`);
    for (const etape of section.etapes) out.push(etape);
    out.push("");
  }

  for (const note of recipe.notes) {
    out.push(`> ${note.genre ? `${note.genre} : ` : ""}${note.texte}`);
  }

  return out.join("\n").trim();
}
