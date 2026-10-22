/**
 * Polish CookLang, refine recipe, generate recipe.
 * Porté depuis GeminiService.polishCooklang() / refineRecipe() / generateRecipe().
 */

import { extractJsonObject } from "./client";
import { callModel } from "../ai/router";
import { textPart, type ModelCallContext } from "../ai/types";
import { GEMINI_POLISH_PROMPT, COOKLANG_RULES } from "./prompts";
import { isUtensil, retagUtensils } from "../nutrition/utensils";

/** Plafond de sortie : une recette complète en CookLang tient largement dedans. */
const RECIPE_MAX_TOKENS = 16_000;

/**
 * Mise en forme et correction orthographique d'un document Markdown non-recette.
 * Ne modifie PAS le contenu/sens — uniquement la mise en forme et l'orthographe.
 */
export async function polishMarkdown(
  apiKey: string,
  markdown: string,
  instruction: string | null,
  ctx: ModelCallContext,
): Promise<string | null> {
  const customPart = instruction
    ? `\nConsigne supplémentaire de l'utilisateur : "${instruction}"\n`
    : "";

  const prompt = `Tu es un correcteur/rédacteur expert francophone. Voici un document au format Markdown :

---
${markdown}
---
${customPart}
Ta mission :
1. Corriger l'orthographe, la grammaire et la ponctuation.
2. Améliorer la mise en forme Markdown (titres, listes, emphases) pour plus de lisibilité.
3. NE PAS modifier le sens, les informations ou le contenu du texte.
4. NE PAS ajouter ni supprimer d'informations.
5. Conserver toutes les images Markdown (![...](...)). 

Retourne UNIQUEMENT le document Markdown corrigé, sans commentaire ni explication.`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, feature: "polish_markdown", timeoutMs: 2 * 60 * 1000 },
    maxTokens: RECIPE_MAX_TOKENS,
  });
  const out = result.text.trim();
  // Enlever les éventuels délimiteurs de bloc markdown que Gemini pourrait ajouter
  return (
    out
      .replace(/^```(?:markdown)?\n?/i, "")
      .replace(/\n?```$/i, "")
      .trim() || null
  );
}

/** Correction orthographique/sémantique d'un CookLang existant. */
export async function polishCooklang(
  apiKey: string,
  cooklang: string,
  ctx: ModelCallContext,
): Promise<string | null> {
  const result = await callModel({
    parts: [textPart(`${GEMINI_POLISH_PROMPT}\n\n---\n${cooklang}`)],
    ctx: { ...ctx, feature: "polish_cooklang", timeoutMs: 2 * 60 * 1000 },
    maxTokens: RECIPE_MAX_TOKENS,
  });
  const out = result.text.trim();
  return out || null;
}

export interface RefineInput {
  currentTitre: string;
  currentCooklang: string;
  currentIngredients: Array<{ name?: string; qty?: string; unit?: string }>;
  currentTags: Record<string, unknown>;
  currentPortions: number | null;
  instruction: string;
}

/** Modifie une recette existante d'après l'instruction utilisateur. */
export async function refineRecipe(
  apiKey: string,
  input: RefineInput,
  ctx: ModelCallContext,
): Promise<Record<string, unknown>> {
  const ingredientsList = input.currentIngredients
    .map((i) => {
      const parts = [i.qty, i.unit, i.name].filter((s) => s && String(s).length > 0);
      return `- ${parts.join(" ").trim()}`;
    })
    .join("\n");

  const portions = input.currentPortions != null ? `\nPortions : ${input.currentPortions}` : "";

  const prompt = `Tu es un chef cuisinier expert francophone. Voici une recette existante :

TITRE: ${input.currentTitre}${portions}
INGRÉDIENTS:
${ingredientsList}

RECETTE AU FORMAT COOKLANG:
${input.currentCooklang}

L'utilisateur souhaite modifier cette recette avec la consigne suivante :
"${input.instruction}"

Applique EXACTEMENT cette consigne en modifiant la recette. Conserve tout ce qui n'est pas concerné par la consigne.

RÈGLE ABSOLUE SUR LES TEMPS :
- "prep_time" = temps de MAIN À LA PÂTE avant cuisson (épluchage, découpe, montage), en minutes.
  Le temps où rien ne se fait — marinade, réfrigération, levée, repos de pâte — n'y entre PAS :
  il a son propre champ, "rest_time". Les compter deux fois donnerait une recette qui a l'air
  impraticable, sans qu'aucune erreur ne le dise.
- "rest_time" = temps de repos en minutes, ou null. La plus longue attente, jamais leur somme.
- "cook_time" = somme EXACTE de TOUS les timers ~{...} de cuisson présents dans le CookLang, en minutes.
- Ces deux valeurs DOIVENT être cohérentes avec les timers ~{} réels de la recette CookLang générée.
- Si tu modifies des étapes, recalcule prep_time et cook_time en conséquence.
- N'invente JAMAIS un cook_time différent de la somme des timers ~{} de cuisson.

Retourne la recette MODIFIÉE en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "justification": "1 a 2 phrases expliquant ce que tu as changé et pourquoi ces changements améliorent la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [{"name": "ingredient", "qty": "200", "unit": "g"}],
  "tags": {"themes": [], "cuisines": [], "occasions": [], "dish_types": [], "difficulty": "facile", "prep_time": 20, "cook_time": 40, "rest_time": null},
  "portions": 4
}
===COOKLANG===
Contenu CookLang modifié
===END===

${COOKLANG_RULES}`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, feature: "refine", timeoutMs: 2 * 60 * 1000 },
    maxTokens: RECIPE_MAX_TOKENS,
  });

  return parseMetadataCooklang(result.text);
}

export interface GenerateRecipeInput {
  query: string;
  preferenceInsight: string | null;
  libraryContext?: Array<Record<string, string>>;
  variantLabel?: string | null;
  variantInstruction?: string | null;
  siblingVariantLabels?: string[];
  avoidTitles?: string[];
}

/** Génère une nouvelle recette originale à partir d'une requête utilisateur. */
export async function generateRecipe(
  apiKey: string,
  input: GenerateRecipeInput,
  ctx: ModelCallContext,
): Promise<Record<string, unknown>> {
  const prefSection = input.preferenceInsight
    ? `\nTiens compte des préférences connues de l'utilisateur : ${input.preferenceInsight}\n`
    : "";
  const libraryContext = input.libraryContext ?? [];
  const librarySection =
    libraryContext.length === 0
      ? ""
      : `\nBibliothèque actuellement sélectionnée par l'utilisateur (source d'inspiration, sans copier mot pour mot) :\n${JSON.stringify(libraryContext)}\n`;
  const variantLabel = input.variantLabel?.trim() ?? "Alternative";
  const variantInstruction =
    input.variantInstruction?.trim() ?? "Propose une variation nette et utile.";
  const siblingLabels = (input.siblingVariantLabels ?? []).filter(Boolean);
  const siblingSection =
    siblingLabels.length === 0
      ? ""
      : `\nTu fais partie d'un lot de variantes parallèles. Les angles du lot sont : ${siblingLabels.join(", ")}.\nTa proposition actuelle doit incarner prioritairement l'angle « ${variantLabel} » et rester clairement distincte des autres angles.\n`;
  const avoidTitles = (input.avoidTitles ?? []).filter(Boolean);
  const avoidSection =
    avoidTitles.length === 0
      ? ""
      : `\nN'utilise pas un titre ou un concept trop proche des propositions déjà retenues : ${avoidTitles.join(", ")}.\nSi besoin, change franchement la technique, le profil aromatique, l'accompagnement ou le format du plat pour éviter les doublons.\n`;

  const prompt = `Tu es un chef cuisinier expert francophone. L'utilisateur cherche une recette : "${input.query}"${prefSection}${librarySection}${siblingSection}
Angle attendu pour CETTE proposition : ${variantLabel}
Consigne de différenciation : ${variantInstruction}${avoidSection}

Génère une recette originale complète qui répond exactement à cette demande.
La proposition doit être crédible, exploitable et clairement différenciée des autres variantes possibles.

RÈGLE ABSOLUE SUR LES TEMPS :
- "prep_time" = temps de MAIN À LA PÂTE avant cuisson (épluchage, découpe, montage), en minutes.
  Le temps où rien ne se fait — marinade, réfrigération, levée, repos de pâte — n'y entre PAS :
  il a son propre champ, "rest_time". Les compter deux fois donnerait une recette qui a l'air
  impraticable, sans qu'aucune erreur ne le dise.
- "rest_time" = temps de repos en minutes, ou null. La plus longue attente, jamais leur somme.
- "cook_time" = somme EXACTE de TOUS les timers ~{...} de cuisson présents dans le CookLang, en minutes.
- Ces deux valeurs DOIVENT être cohérentes avec les timers ~{} réels de la recette CookLang générée.
- N'invente JAMAIS un cook_time différent de la somme des timers ~{} de cuisson.

Retourne la réponse en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [{"name": "ingredient", "qty": "200", "unit": "g"}],
  "justification": "2 phrases max expliquant pourquoi cette variante est pertinente et en quoi elle se distingue",
  "variant_label": "${variantLabel}",
  "tags": {"themes": [], "cuisines": [], "occasions": [], "dish_types": [], "difficulty": "facile", "prep_time": 20, "cook_time": 40, "rest_time": null},
  "portions": 4
}
===COOKLANG===
Contenu CookLang complet
===END===

${COOKLANG_RULES}`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, feature: "generate", timeoutMs: 2 * 60 * 1000 },
    maxTokens: RECIPE_MAX_TOKENS,
  });

  return parseMetadataCooklang(result.text);
}

/**
 * Répare les erreurs JSON courantes générées par le moteur :
 * - Clé sans valeur : `"unit" }` ou `"unit" ,` → `"unit": "" }` / `"unit": "" ,`
 */
function repairJson(json: string): string {
  // Détecte les clés en position objet (après { ou ,) NON suivies de ':'
  return json.replace(/([{,]\s*"(?:[^"\\]|\\.)*")(?!\s*:)(\s*[,}])/g, '$1: ""$2');
}

/** Parse les sections ===METADATA=== / ===COOKLANG=== / ===END=== de la réponse. */
function parseMetadataCooklang(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Réponse vide du moteur d'IA");

  const metaMarker = "===METADATA===";
  const cooklangMarker = "===COOKLANG===";
  const endMarker = "===END===";

  const metaStart = trimmed.indexOf(metaMarker);
  const cooklangStart = trimmed.indexOf(cooklangMarker);
  if (metaStart === -1 || cooklangStart === -1) {
    throw new Error("Format de réponse invalide (marqueurs manquants)");
  }

  const metaJson = trimmed.substring(metaStart + metaMarker.length, cooklangStart).trim();
  const endIdx = trimmed.indexOf(endMarker);
  const cooklang = (
    endIdx === -1
      ? trimmed.substring(cooklangStart + cooklangMarker.length)
      : trimmed.substring(cooklangStart + cooklangMarker.length, endIdx)
  ).trim();

  const rawJson = extractJsonObject(metaJson);
  let data: Record<string, unknown>;
  try {
    data = JSON.parse(rawJson) as Record<string, unknown>;
  } catch (firstErr) {
    // Tentative de réparation du JSON malformé
    try {
      data = JSON.parse(repairJson(rawJson)) as Record<string, unknown>;
    } catch {
      throw firstErr;
    }
  }
  data.cooklang = cooklang;
  return withoutUtensilsInGenerated(data);
}

/**
 * Retire les ustensiles d'une recette retouchée ou imaginée par le modèle.
 *
 * Même règle qu'à l'import (`withoutUtensils`) : un `@papier sulfurisé{}`
 * devient `#papier sulfurisé{}` dans le texte, et le nom sort de
 * `ingredients` et de `ingredients_index`. Le client enregistre ensuite ces
 * champs tels quels ; sans ce retrait, l'ustensile entrait dans la recette et
 * le déclencheur nutrition lui cherchait une fiche.
 */
export function withoutUtensilsInGenerated(data: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...data };
  if (typeof out.cooklang === "string") out.cooklang = retagUtensils(out.cooklang);
  if (Array.isArray(out.ingredients)) {
    out.ingredients = out.ingredients.filter((item: unknown) => {
      const name =
        item && typeof item === "object" ? (item as Record<string, unknown>).name : undefined;
      return !(typeof name === "string" && isUtensil(name));
    });
  }
  if (Array.isArray(out.ingredients_index)) {
    out.ingredients_index = out.ingredients_index.filter(
      (name: unknown) => !(typeof name === "string" && isUtensil(name)),
    );
  }
  return out;
}
