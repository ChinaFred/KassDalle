/**
 * Conservation et réchauffage d'un plat préparé à l'avance.
 *
 * Le poste ne produit pas un cours d'hygiène alimentaire — le refroidissement
 * en deux heures, les trois jours au réfrigérateur, le réchauffage à cœur sont
 * des règles générales, qui se calculent et ne se demandent pas à un modèle.
 * Elles vivent dans `STORAGE_RULES` ci-dessous et dans le module Dart jumeau.
 *
 * Ce qui est demandé au modèle, c'est ce qui est propre à CE plat : dans quel
 * contenant il tient, ce qui se dégrade en premier, comment le réchauffer sans
 * le ruiner, ce qui doit être ajouté au dernier moment plutôt que conservé, et
 * à quoi on voit qu'il n'est plus bon.
 *
 * Le garde-fou `looksGeneric` refuse une réponse qui ne nomme aucun ingrédient
 * de la recette : « laissez refroidir puis couvrez » s'affiche parfaitement et
 * ne vaut rien. C'est le genre d'échec qu'il faut attraper à la production.
 */

import { extractJsonObject } from "./client";
import { extractIngredientNames, extractTitle } from "../cooklang/parser";
import { callModel } from "../ai/router";
import { logInfo } from "../logging";
import { textPart, type AiProvider, type ModelCallContext } from "../ai/types";

export const STORAGE_PROMPT_VERSION = 1;

/** Mode de conservation entre la préparation et le repas. */
export type MealStorageMode = "sameDay" | "fridge" | "freezer";

/**
 * Règles générales, tenues hors du modèle.
 *
 * Dupliquées dans `lib/features/planning/domain/meal_storage_rules.dart`, sous
 * fixture partagée `test-fixtures/meal_storage_rules.json`. Un écart ici ne
 * casse rien et ne se voit pas : il fait seulement dire à un écran qu'un plat
 * tient au réfrigérateur quand l'autre le fait congeler.
 */
export const MAX_FRIDGE_DAYS = 3;
export const MAX_COOLING_HOURS = 2;

/** Mode de conservation pour un plat préparé `daysAhead` jours à l'avance. */
export function mealStorageMode(daysAhead: number): MealStorageMode {
  if (daysAhead <= 0) return "sameDay";
  if (daysAhead <= MAX_FRIDGE_DAYS) return "fridge";
  return "freezer";
}

export interface StorageWindow {
  /** Durée maximale conseillée pour ce plat, dans l'unité du mode. */
  duree: string;
  /** Contenant et conditionnement conseillés pour ce plat. */
  contenant: string;
  /** Ce qui se dégrade en premier, et comment le limiter. */
  conseil: string;
}

export interface ReheatAdvice {
  /** Casserole, four, vapeur, poêle… pour ce plat précis. */
  methode: string;
  /** Température ou puissance, en clair. */
  temperature: string;
  /** Durée indicative. */
  duree: string;
  /** Le geste qui évite de ruiner le plat au réchauffage. */
  conseil: string;
}

export interface StorageAdvice {
  /** Une phrase : ce plat supporte-t-il d'attendre, et à quelles conditions. */
  resume: string;
  /** Refroidissement propre à ce plat avant la mise au froid. */
  refroidissement: string;
  refrigerateur: StorageWindow;
  /** Null si le plat ne se congèle pas sans se dégrader. */
  congelateur: StorageWindow | null;
  /** Pourquoi ce plat ne se congèle pas, quand `congelateur` est null. */
  congelationDeconseillee: string | null;
  rechauffage: ReheatAdvice;
  /** Éléments à préparer ou ajouter au dernier moment plutôt qu'à conserver. */
  aAjouterAuDernierMoment: string[];
  /** Signes qu'il ne faut plus le manger. */
  signesDAlerte: string[];
}

export interface StorageAdviceInput {
  titre: string;
  cooklang: string;
  dishTypes: string[];
  portions: number | null;
}

export interface StorageAdviceResult {
  advice: StorageAdvice;
  provider: AiProvider;
  model: string;
}

/**
 * Vrai si le conseil ne nomme aucun ingrédient de la recette.
 *
 * Un conseil de conservation générique est le mode d'échec le plus probable et
 * le moins visible : il est juste, il est inutile, et rien ne le signale.
 */
function looksGeneric(advice: StorageAdvice, ingredientNames: string[]): boolean {
  if (ingredientNames.length === 0) return false;
  const bag = [
    advice.resume,
    advice.refroidissement,
    advice.refrigerateur.contenant,
    advice.refrigerateur.conseil,
    advice.congelateur?.conseil ?? "",
    advice.rechauffage.methode,
    advice.rechauffage.conseil,
    ...advice.aAjouterAuDernierMoment,
    ...advice.signesDAlerte,
  ]
    .join(" ")
    .toLowerCase();
  return !ingredientNames.some((name) => name.length > 3 && bag.includes(name.toLowerCase()));
}

function buildPrompt(input: StorageAdviceInput, retry: boolean): string {
  const lines: string[] = [];
  lines.push(
    "Tu es un chef habitué au batch cooking et à la sécurité alimentaire domestique.",
    "On te donne une recette. Dis comment conserver ce plat préparé à l'avance, et comment le réchauffer sans le gâcher.",
    "",
    "=== RÈGLES GÉNÉRALES, DÉJÀ CONNUES ===",
    `Ne les répète pas, elles sont affichées séparément : mise au froid dans les ${MAX_COOLING_HOURS} h, réfrigérateur à 4 °C, ${MAX_FRIDGE_DAYS} jours maximum pour un plat cuisiné, réchauffage à cœur, on ne recongèle jamais un plat décongelé.`,
    "Ton rôle est de dire ce qui est propre à CE plat, et de corriger la règle générale quand ce plat exige plus court.",
    "",
    "=== RECETTE ===",
    `Titre : ${input.titre}`,
  );
  if (input.dishTypes.length > 0) lines.push(`Type : ${input.dishTypes.join(", ")}`);
  if (input.portions) lines.push(`Portions : ${input.portions}`);
  lines.push("", input.cooklang.trim(), "");

  if (retry) {
    lines.push(
      "ATTENTION : ta réponse précédente était générique et ne nommait aucun ingrédient de cette recette. Recommence en désignant les éléments réels du plat.",
      "",
    );
  }

  lines.push(
    "=== CE QUE TU DOIS DIRE ===",
    "- ce qui se dégrade en premier dans CE plat (texture qui rend l'eau, croûte qui ramollit, herbe qui noircit)",
    "- le contenant et le conditionnement adaptés à ce plat",
    "- si le plat se congèle : combien de temps, comment le portionner, comment le décongeler ; s'il ne se congèle pas, dis-le et explique pourquoi",
    "- si ce plat tient MOINS que la règle générale, donne la durée courte et dis pourquoi (poisson, riz cuit, viande hachée, crème, œuf peu cuit…)",
    "- le réchauffage : méthode, température, durée, et le geste qui évite de le ruiner",
    "- ce qu'il vaut mieux préparer au dernier moment que conserver (garniture croquante, herbe fraîche, sauce à monter)",
    "- les signes visibles ou olfactifs qu'il ne faut plus le manger",
    "",
    "=== FORMAT ===",
    "Réponds UNIQUEMENT avec un objet JSON valide, sans balises markdown :",
    JSON.stringify(
      {
        resume: "Une phrase : ce plat supporte-t-il d'attendre, à quelles conditions.",
        refroidissement: "Comment refroidir ce plat précis avant de le ranger.",
        refrigerateur: {
          duree: "3 jours",
          contenant: "Contenant et conditionnement conseillés.",
          conseil: "Ce qui se dégrade en premier et comment le limiter.",
        },
        congelateur: {
          duree: "2 mois",
          contenant: "Portionnage et conditionnement pour la congélation.",
          conseil: "Décongélation et précautions.",
        },
        congelation_deconseillee: null,
        rechauffage: {
          methode: "Casserole à feu doux",
          temperature: "feu doux, à couvert",
          duree: "10 à 12 minutes",
          conseil: "Le geste qui évite de ruiner le plat.",
        },
        a_ajouter_au_dernier_moment: ["Élément à ne pas conserver avec le reste."],
        signes_d_alerte: ["Ce qui indique qu'il ne faut plus le manger."],
      },
      null,
      0,
    ),
    "",
    "Si le plat ne se congèle pas, mets `congelateur` à null et renseigne `congelation_deconseillee` avec la raison.",
    "Écris en français, à la deuxième personne, sans emphase ni superlatif.",
  );
  return lines.join("\n");
}

function parseWindow(raw: unknown): StorageWindow | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const duree = typeof o.duree === "string" ? o.duree.trim() : "";
  if (!duree) return null;
  return {
    duree,
    contenant: typeof o.contenant === "string" ? o.contenant.trim() : "",
    conseil: typeof o.conseil === "string" ? o.conseil.trim() : "",
  };
}

function asStringList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((v): v is string => typeof v === "string")
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
}

function parseAdvice(text: string): StorageAdvice {
  const parsed = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
  const rechauffageRaw = (parsed.rechauffage ?? {}) as Record<string, unknown>;
  const str = (v: unknown): string => (typeof v === "string" ? v.trim() : "");

  return {
    resume: str(parsed.resume),
    refroidissement: str(parsed.refroidissement),
    refrigerateur: parseWindow(parsed.refrigerateur) ?? {
      duree: `${MAX_FRIDGE_DAYS} jours`,
      contenant: "",
      conseil: "",
    },
    congelateur: parseWindow(parsed.congelateur),
    congelationDeconseillee: str(parsed.congelation_deconseillee) || null,
    rechauffage: {
      methode: str(rechauffageRaw.methode),
      temperature: str(rechauffageRaw.temperature),
      duree: str(rechauffageRaw.duree),
      conseil: str(rechauffageRaw.conseil),
    },
    aAjouterAuDernierMoment: asStringList(parsed.a_ajouter_au_dernier_moment),
    signesDAlerte: asStringList(parsed.signes_d_alerte),
  };
}

/**
 * Produit le conseil de conservation et de réchauffage d'une recette.
 *
 * Le conseil vaut pour le plat, pas pour un repas : il décrit à la fois le
 * réfrigérateur et le congélateur. C'est le planning qui choisit ensuite la
 * moitié qui s'applique, selon le délai réel — sans quoi il faudrait repayer
 * un appel par créneau.
 */
export async function suggestStorageAdvice(
  input: StorageAdviceInput,
  ctx: ModelCallContext,
): Promise<StorageAdviceResult> {
  const titre = input.titre.trim() || extractTitle(input.cooklang) || "Recette";
  const ingredientNames = extractIngredientNames(input.cooklang);

  let last: StorageAdviceResult | null = null;
  for (const retry of [false, true]) {
    const result = await callModel({
      parts: [textPart(buildPrompt({ ...input, titre }, retry))],
      ctx: { ...ctx, feature: "storage_advice", timeoutMs: 90 * 1000 },
      maxTokens: 4_000,
    });

    const advice = parseAdvice(result.text);
    last = { advice, provider: result.provider, model: result.model };
    if (!looksGeneric(advice, ingredientNames)) return last;

    await logInfo("Conservation — conseil générique, nouvelle tentative", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: "storage_advice",
      extra: { titre, retry },
    });
  }
  // Deuxième réponse encore générique : elle est retournée telle quelle, le log
  // ci-dessus dit pourquoi. Un conseil faible vaut mieux que pas de conseil.
  return last as StorageAdviceResult;
}
