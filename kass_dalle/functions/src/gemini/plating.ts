/**
 * Conseil de dressage sur mesure pour une recette donnée.
 *
 * Le poste ne produit pas des règles de dressage — il en existe des livres
 * entiers, et l'utilisateur n'a pas besoin d'un site de plus pour lui dire
 * d'essuyer le bord de l'assiette. Il produit la gestuelle d'envoi de CE plat :
 * quel élément se pose en premier, où, dans quel contenant, et ce qui va rater
 * si l'ordre change.
 *
 * D'où le garde-fou `looksGeneric` : une réponse dont les gestes ne nomment
 * aucun élément de la recette est refusée et redemandée une fois. Un conseil
 * générique ne lève aucune erreur et s'affiche parfaitement — c'est exactement
 * pour cela qu'il faut le détecter ici, et pas à la lecture.
 */

import { extractJsonObject } from "./client";
import { extractIngredientNames, extractTitle } from "../cooklang/parser";
import { callModel } from "../ai/router";
import { logInfo } from "../logging";
import { textPart, type AiProvider, type ModelCallContext } from "../ai/types";

export type PlatingComplexity = "simple" | "intermediaire" | "complexe";

export interface PlatingStep {
  /** Titre court du geste, ex. « Le lit de poireaux fondus ». */
  titre: string;
  /** Le geste lui-même, nommant les éléments réels de la recette. */
  geste: string;
  /** Éléments de la recette manipulés à cette étape. */
  elements: string[];
  /**
   * Description du visuel à générer pour cette étape, ou null.
   * Non nul uniquement quand le placement est difficile à décrire en mots.
   */
  imagePrompt: string | null;
}

export interface PlatingAdvice {
  complexite: PlatingComplexity;
  /** Une phrase : l'intention visuelle du plat. */
  resume: string;
  /** Contenant conseillé et pourquoi, pour ce plat précis. */
  contenant: string;
  etapes: PlatingStep[];
  /** Pièges propres à ce plat (humidité, température, texture). */
  pieges: string[];
  /** Ce qui se pose au dernier moment, juste avant l'envoi. */
  derniereMinute: string[];
}

export interface PlatingInput {
  titre: string;
  cooklang: string;
  /** Tags de la recette (cuisine, type de plat) — contexte de style. */
  cuisines?: string[];
  dishTypes?: string[];
  portions?: number | null;
  /** Contrainte de service saisie par l'utilisateur (« buffet froid », « à emporter »). */
  userInstruction?: string | null;
}

const MAX_COOKLANG_CHARS = 6000;
const MAX_IMAGE_PROMPTS = 3;

/**
 * Version du prompt, stockée avec le conseil.
 *
 * Sans elle, impossible de savoir si un conseil affiché vient de la consigne
 * actuelle ou d'une version qu'on a depuis corrigée — et donc impossible de
 * décider ce qui mérite d'être régénéré.
 */
export const PLATING_PROMPT_VERSION = 1;

function buildPrompt(input: PlatingInput, retryReason?: string): string {
  const cooklang =
    input.cooklang.length > MAX_COOKLANG_CHARS
      ? input.cooklang.slice(0, MAX_COOKLANG_CHARS) + "\n...(tronqué)"
      : input.cooklang;

  const contexte = [
    input.cuisines?.length ? `Cuisine: ${input.cuisines.join(", ")}` : "",
    input.dishTypes?.length ? `Type de plat: ${input.dishTypes.join(", ")}` : "",
    input.portions ? `Portions: ${input.portions}` : "",
    input.userInstruction?.trim()
      ? `Contrainte de service imposée par l'utilisateur: ${input.userInstruction.trim()}`
      : "",
  ]
    .filter(Boolean)
    .join("\n");

  return [
    "Tu es chef de partie et tu envoies CE plat, ce service, maintenant.",
    "On ne te demande pas la recette : elle est déjà cuisinée. On te demande",
    "comment poser les éléments dans le contenant, dans quel ordre, et ce qui",
    "rate si l'ordre change.",
    "",
    `TITRE: ${input.titre}`,
    contexte,
    "",
    "RECETTE (format CookLang — @ingrédient{quantité%unité}, #ustensile, ~{temps}) :",
    cooklang,
    "",
    "RÈGLES ABSOLUES :",
    "1. Chaque geste doit nommer des éléments RÉELS de cette recette. Interdit :",
    "   « l'élément principal », « la protéine », « la garniture », « les accompagnements ».",
    "   On dit « le dos de cabillaud », « le confit d'oignon », « la tuile de parmesan ».",
    "2. Une phrase qui resterait vraie pour un autre plat est une phrase à supprimer.",
    "   Pas de « laisser respirer l'assiette », pas de « essuyer les bords »,",
    "   pas de « jouer sur les contrastes de couleurs ».",
    "3. Les pièges sont physiques et propres à ce plat : ce qui détrempe, ce qui fige,",
    "   ce qui rend de l'eau, ce qui ternit, ce qui refroidit en premier.",
    "4. Si la recette n'a rien à dresser (soupe servie au bol, gâteau démoulé, boisson,",
    '   page technique), dis-le : complexite = "simple", 2 étapes maximum, et ne',
    "   fabrique pas de complexité qui n'existe pas.",
    "5. Écris en français, à l'infinitif ou à l'impératif, sans emphase publicitaire.",
    "",
    "COMPLEXITÉ :",
    '- "simple" : un ou deux éléments, le contenant fait le travail.',
    '- "intermediaire" : plusieurs éléments à positionner, mais sans montage en hauteur.',
    '- "complexe" : montage en plusieurs couches, éléments fragiles, ordre critique.',
    "",
    "IMAGES :",
    "Pour les étapes dont le placement est difficile à décrire en mots, et pour elles seules,",
    `renseigne "imagePrompt" (${MAX_IMAGE_PROMPTS} au maximum sur toute la recette, 0 si le`,
    "dressage est simple). C'est la description d'un visuel montrant l'assiette",
    "À CE STADE du montage — pas le plat fini, pas une photo de magazine :",
    "position et orientation des éléments déjà posés, vue de dessus ou trois quarts.",
    'Les autres étapes ont "imagePrompt": null.',
    "",
    "Retourne UNIQUEMENT ce JSON, sans balise markdown, sans commentaire :",
    "{",
    '  "complexite": "simple|intermediaire|complexe",',
    '  "resume": "une phrase sur l\'intention visuelle de ce plat",',
    '  "contenant": "quel contenant et pourquoi pour ce plat",',
    '  "etapes": [',
    '    {"titre": "…", "geste": "…", "elements": ["…"], "imagePrompt": null}',
    "  ],",
    '  "pieges": ["…"],',
    '  "derniere_minute": ["…"]',
    "}",
    "",
    "3 à 6 étapes, 1 à 4 pièges, 0 à 3 gestes de dernière minute.",
    retryReason
      ? `\nTA RÉPONSE PRÉCÉDENTE A ÉTÉ REFUSÉE : ${retryReason}\nRecommence en nommant explicitement les éléments de cette recette.`
      : "",
  ]
    .filter(Boolean)
    .join("\n");
}

function stripAccents(value: string): string {
  return value.normalize("NFD").replace(/[̀-ͯ]/g, "");
}

/** Tokens significatifs d'un texte — sert à vérifier qu'un geste parle du plat. */
function significantTokens(value: string): string[] {
  return stripAccents(value.toLowerCase())
    .split(/[^a-z0-9]+/)
    .filter((token) => token.length >= 4);
}

/**
 * Vrai si les gestes ne parlent pas de cette recette en particulier.
 *
 * Le seuil est volontairement bas : il suffit qu'une minorité d'étapes cite un
 * élément réel pour qu'on accepte. On cherche la réponse entièrement passe-
 * partout, pas la formulation imparfaite.
 */
export function looksGeneric(advice: PlatingAdvice, input: PlatingInput): boolean {
  if (advice.etapes.length === 0) return true;

  const names = extractIngredientNames(input.cooklang);
  // Une page sans ingrédients balisés (note, technique, texte libre) ne fournit
  // pas de quoi juger : refuser y serait un faux positif systématique, et le
  // second appel coûterait autant que le premier pour le même résultat.
  if (names.length < 2) return false;

  const vocabulary = new Set<string>();
  for (const name of names) {
    for (const token of significantTokens(name)) vocabulary.add(token);
  }
  for (const token of significantTokens(input.titre)) vocabulary.add(token);
  if (vocabulary.size === 0) return false;

  const grounded = advice.etapes.filter((step) => {
    const haystack = significantTokens(`${step.titre} ${step.geste} ${step.elements.join(" ")}`);
    return haystack.some((token) => vocabulary.has(token));
  }).length;

  return grounded * 2 < advice.etapes.length;
}

function asStringList(value: unknown, max: number): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .slice(0, max);
}

function parseComplexity(value: unknown): PlatingComplexity {
  return value === "complexe" || value === "intermediaire" || value === "simple"
    ? value
    : "intermediaire";
}

function parseAdvice(raw: string): PlatingAdvice {
  const json = JSON.parse(extractJsonObject(raw)) as Record<string, unknown>;

  const etapesRaw = Array.isArray(json.etapes) ? json.etapes : [];
  let remainingImages = MAX_IMAGE_PROMPTS;

  const etapes: PlatingStep[] = etapesRaw
    .filter(
      (entry): entry is Record<string, unknown> => typeof entry === "object" && entry !== null,
    )
    .slice(0, 8)
    .map((entry) => {
      const rawPrompt = typeof entry.imagePrompt === "string" ? entry.imagePrompt.trim() : "";
      // Le quota d'images est appliqué ici plutôt que laissé au modèle : c'est
      // 0,04 $ par image, et la consigne du prompt n'est pas un contrat.
      const keepPrompt = rawPrompt.length > 0 && remainingImages > 0;
      if (keepPrompt) remainingImages -= 1;
      return {
        titre: typeof entry.titre === "string" ? entry.titre.trim() : "",
        geste: typeof entry.geste === "string" ? entry.geste.trim() : "",
        elements: asStringList(entry.elements, 6),
        imagePrompt: keepPrompt ? rawPrompt : null,
      };
    })
    .filter((step) => step.geste.length > 0);

  return {
    complexite: parseComplexity(json.complexite),
    resume: typeof json.resume === "string" ? json.resume.trim() : "",
    contenant: typeof json.contenant === "string" ? json.contenant.trim() : "",
    etapes,
    pieges: asStringList(json.pieges, 4),
    derniereMinute: asStringList(json.derniere_minute, 3),
  };
}

export interface PlatingAdviceResult {
  advice: PlatingAdvice;
  /** Moteur qui a réellement répondu — affiché en label dans l'onglet. */
  provider: AiProvider;
  model: string;
}

/** Demande au moteur un dressage propre à cette recette. */
export async function suggestPlating(
  input: PlatingInput,
  ctx: ModelCallContext,
): Promise<PlatingAdviceResult> {
  const titre = input.titre.trim() || extractTitle(input.cooklang);
  const normalized: PlatingInput = { ...input, titre };

  const call = async (retryReason?: string): Promise<PlatingAdviceResult> => {
    const result = await callModel({
      parts: [textPart(buildPrompt(normalized, retryReason))],
      ctx: { ...ctx, feature: "plating_coach", timeoutMs: 60_000 },
      maxTokens: 2000,
    });
    return {
      advice: parseAdvice(result.text || "{}"),
      provider: result.provider,
      model: result.model,
    };
  };

  const first = await call();
  if (!looksGeneric(first.advice, normalized)) return first;

  await logInfo({
    message: "suggestPlating: réponse sans ancrage dans la recette, seconde passe",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    feature: "plating_coach",
    extra: { titre, steps: first.advice.etapes.length },
  });

  const second = await call("aucun geste ne citait un ingrédient ou un élément réel de la recette");
  // La seconde passe est servie même si elle échoue au même test : deux appels
  // suffisent, et un conseil imparfait vaut mieux qu'un écran vide.
  return second.advice.etapes.length > 0 ? second : first;
}
