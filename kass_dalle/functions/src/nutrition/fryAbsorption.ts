/**
 * Huile absorbée à la friture.
 *
 * Un bain de friture ne finit pas dans l'assiette — `not_consumed` le sort du
 * calcul, et c'est juste : un litre d'huile pèse 8280 kcal. Mais l'aliment qui
 * y plonge, lui, en ressort plus gras qu'il n'y est entré. Un poulet pané au
 * panko absorbe environ un dixième de son poids en huile : sur 600 g, ce sont
 * 55 g de lipides et 500 kcal que la recette ne déclarait nulle part. La
 * couverture affichait « complet », le score était bon, et le plat mentait de
 * 40 % sur ses lipides.
 *
 * Le taux d'absorption n'appartient pas au bain : la quantité d'huile écrite
 * dans la recette est arbitraire — « 1 L pour la friture » n'a aucun rapport
 * avec ce qui est mangé. En garder un pourcentage ferait dépendre le résultat
 * de la façon dont l'auteur a rédigé sa ligne. Le taux appartient à l'aliment
 * frit, et le bain déclaré ne sert que de plafond : on n'absorbe pas plus
 * d'huile qu'il n'y en a.
 *
 * Reste à savoir *ce qui* est frit. Une liste d'ingrédients ne le dit pas —
 * dans un poulet pané, le poulet, la farine, l'œuf et la chapelure passent au
 * bain, la salade servie à côté non. Seul le texte de la recette le dit, d'où
 * une passe d'IA. Elle n'est demandée que si la recette sent la friture
 * (`looksFried`, déterministe et gratuit) et son verdict est conservé dans le
 * snapshot avec la signature qui l'a produit.
 */

import { logError, logInfo } from "../logging";
import { askJson } from "../ai/askJson";

/**
 * Profil de repli de l'huile absorbée, quand la recette ne déclare aucun corps
 * gras exploitable.
 *
 * Huile végétale courante (tournesol, arachide, colza). Approcher vaut mieux
 * que taire : sans ce repli, une recette frite dont le bain n'est pas listé
 * afficherait ses lipides d'avant cuisson comme s'ils étaient définitifs.
 */
export const DEFAULT_FRY_OIL_PER100G: Record<string, number> = {
  kcal: 900,
  fat_g: 100,
  saturated_fat_g: 13,
};

/** Nom affiché de la ligne dérivée, quand aucun corps gras n'est nommé. */
export const DEFAULT_FRY_OIL_NAME = "huile de friture";

/**
 * Plafond du taux d'absorption.
 *
 * Rien ne dépasse le tiers de son poids, même un beignet (≈ 20-25 %). Un
 * modèle qui répond « 60 % » s'est trompé d'unité ou de question : on le borne
 * plutôt que de doubler les lipides d'un plat.
 */
export const MAX_FRY_ABSORPTION_RATIO = 0.3;

/**
 * Signes de friture dans le texte d'une recette ou dans ses ingrédients.
 *
 * Recherche par mots entiers, jamais par sous-chaîne : « frit » en sous-chaîne
 * attrape « frittata », qui est une omelette et ne trempe dans rien.
 *
 * Une panure seule ne déclenche rien — un poulet pané peut finir au four.
 */
const FRYING_PATTERNS: RegExp[] = [
  /\bfrit(?:e|s|es)?\b/,
  /\bfrire\b/,
  /\bfriture[s]?\b/,
  /\bfriteuse[s]?\b/,
  /\bbain\s+(?:d['’]huile|de\s+friture|d['’]huile\s+chaude)\b/,
  /\btempura[s]?\b/,
  /\bbeignet[s]?\b/,
];

/** Minuscules sans accents : « frit » et « frît » désignent la même cuisson. */
const DIACRITICS = /[̀-ͯ]/g;

function foldForSearch(value: string): string {
  return value.toLowerCase().normalize("NFD").replace(DIACRITICS, "");
}

/**
 * La recette sent-elle la friture ?
 *
 * Portier volontairement déterministe : il ne décide rien du calcul, il décide
 * seulement s'il vaut la peine de payer un appel d'IA. Un faux positif coûte un
 * appel qui répondra « rien n'est frit » ; un faux négatif laisse une recette
 * mentir sur ses lipides — l'asymétrie justifie d'être large.
 */
export function looksFried(args: { rawCooklang?: string; ingredientNames?: string[] }): boolean {
  const haystack = foldForSearch(
    [args.rawCooklang ?? "", ...(args.ingredientNames ?? [])].join(" \n "),
  );
  if (!haystack.trim()) return false;
  return FRYING_PATTERNS.some((pattern) => pattern.test(haystack));
}

/**
 * Grammes d'huile réellement absorbés, plafonnés par le bain déclaré.
 *
 * `declaredOilGrams` vaut `null` quand la recette écrit « huile pour friture »
 * sans quantité, ou quand cette quantité ne se convertit pas en grammes :
 * l'absence de plafond ne doit pas annuler l'estimation, elle la laisse
 * simplement sans borne haute.
 */
export function computeAbsorbedOilGrams(args: {
  friedWeightGrams: number;
  absorptionRatio: number;
  declaredOilGrams?: number | null;
}): { grams: number; capped: boolean } {
  const { friedWeightGrams, absorptionRatio } = args;
  if (!Number.isFinite(friedWeightGrams) || friedWeightGrams <= 0) {
    return { grams: 0, capped: false };
  }
  if (!Number.isFinite(absorptionRatio) || absorptionRatio <= 0) {
    return { grams: 0, capped: false };
  }

  const ratio = Math.min(absorptionRatio, MAX_FRY_ABSORPTION_RATIO);
  const raw = friedWeightGrams * ratio;

  const declared = args.declaredOilGrams;
  if (typeof declared === "number" && Number.isFinite(declared) && declared > 0 && raw > declared) {
    return { grams: Math.round(declared * 10) / 10, capped: true };
  }
  return { grams: Math.round(raw * 10) / 10, capped: false };
}

/**
 * Empreinte de ce qui détermine l'absorption : la liste des ingrédients et le
 * texte qui décrit la cuisson.
 *
 * Le verdict se réutilise tant que cette empreinte ne bouge pas. Corriger une
 * faute de frappe dans une étape redemande un appel — c'est le prix d'une
 * empreinte qui ne cherche pas à deviner ce qui, dans le texte, parle de
 * cuisson.
 */
export function fryingSignature(args: { ingredientsKey: string; rawCooklang?: string }): string {
  const text = (args.rawCooklang ?? "").trim();
  // FNV-1a : le texte d'une recette n'a pas sa place dans un document Firestore
  // relu à chaque affichage, et seule l'égalité nous intéresse.
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `${args.ingredientsKey}#${hash.toString(16)}`;
}

const FRY_ABSORPTION_SCHEMA = {
  type: "object",
  properties: {
    frits: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
        },
        required: ["id"],
        additionalProperties: false,
      },
    },
    absorption_pct: { type: "number" },
  },
  required: ["frits", "absorption_pct"],
  additionalProperties: false,
};

export interface FryAbsorptionVerdict {
  /** Indices, dans la liste fournie, des ingrédients qui passent au bain. */
  friedIndices: number[];
  /** Part du poids de ces ingrédients absorbée en huile, entre 0 et 0,3. */
  absorptionRatio: number;
  /**
   * L'appel au modèle a échoué (erreur, délai, plafond atteint, réponse
   * illisible). Le verdict vaut alors « rien n'est frit » pour ce calcul-ci,
   * mais il ne doit pas être mémorisé : voir `fryFieldsToPersist`.
   */
  failed?: true;
}

export const NO_FRY_ABSORPTION: FryAbsorptionVerdict = { friedIndices: [], absorptionRatio: 0 };

/** Verdict d'un appel en échec : rien d'absorbé, et rien à mémoriser. */
export const FAILED_FRY_ABSORPTION: FryAbsorptionVerdict = {
  friedIndices: [],
  absorptionRatio: 0,
  failed: true,
};

/**
 * Les deux champs du snapshot qui mémorisent le verdict de friture.
 *
 * Un verdict en échec n'est pas mémorisé : `fry_signature` reste vide, et le
 * calcul suivant redemande l'appel. Mémoriser la signature avec
 * `fry_verdict: null` laissait la recette sans huile absorbée jusqu'à ce que
 * son texte change, puisque la signature identique dispensait de rappeler.
 *
 * Aucune boucle de déclencheurs : `fry_signature` n'est pas une entrée de
 * `onRecipeWritten` (`recipeTriggerInputsFingerprint`), l'écriture du snapshot
 * n'y relance pas la nutrition. Le prochain essai attend un calcul demandé par
 * ailleurs : une entrée modifiée, ou un recalcul manuel. Le rattrapage nocturne
 * ne le redemande pas : `catchUpDecision` ignore une recette dont
 * `nutritionIsIncomplete` est faux, et un verdict en échec ne rend pas la
 * nutrition incomplète. Il ne le refait qu'en passant, sur une recette reprise
 * pour une autre lacune.
 */
export function fryFieldsToPersist(
  verdict: FryAbsorptionVerdict,
  signature: string,
): {
  fry_verdict: { fried_indices: number[]; absorption_ratio: number } | null;
  fry_signature: string;
} {
  if (verdict.failed) return { fry_verdict: null, fry_signature: "" };
  return {
    fry_verdict:
      verdict.friedIndices.length > 0
        ? { fried_indices: verdict.friedIndices, absorption_ratio: verdict.absorptionRatio }
        : null,
    fry_signature: signature,
  };
}

/**
 * Demande au moteur ce qui est frit et combien d'huile cela absorbe.
 *
 * Best-effort : un échec rend « rien n'est frit » (`FAILED_FRY_ABSORPTION`,
 * marqué `failed`) plutôt que d'empêcher le calcul nutritionnel de la recette.
 * L'erreur reste tracée, et le verdict n'est pas mémorisé.
 *
 * `userId` : le compte auquel s'impute l'appel et son plafond quotidien — le
 * propriétaire de la recette (`recipeBudgetUserId`). `"system"` ne reste que
 * pour un appel sans recette ni propriétaire.
 */
export async function estimateFryAbsorptionWithAI(args: {
  ingredients: Array<{ name: string; qty: string; unit: string }>;
  rawCooklang?: string;
  recipeId?: string;
  userId?: string;
}): Promise<FryAbsorptionVerdict> {
  if (args.ingredients.length === 0) return NO_FRY_ABSORPTION;

  // Le texte sert à savoir *comment* on cuit : quelques milliers de caractères
  // suffisent, et la note de dressage en fin de recette n'apprend rien ici.
  const recipeText = (args.rawCooklang ?? "").trim().slice(0, 4000);

  const prompt = `Tu es un cuisinier professionnel. Voici une recette et sa liste d'ingrédients.

Dis quels ingrédients sont FRITS — plongés dans un bain d'huile ou saisis dans une
matière grasse qu'ils absorbent durablement — et quelle part de leur poids ils
absorbent en huile.

Règles :
- Ne retiens que ce qui passe réellement au bain, panure comprise (farine, œuf,
  chapelure, panko d'un aliment pané sont frits avec lui).
- Ignore ce qui est servi à côté (salade, sauce, accompagnement non frit).
- Ignore l'huile de friture elle-même : c'est le bain, pas l'aliment.
- Le pourcentage porte sur le poids des ingrédients frits, pas sur le bain.

Ordres de grandeur : aliment pané et frit 8 à 12 %, frite 6 à 8 %, beignet ou
pâte frite 15 à 25 %, légume ou viande frit sans panure 2 à 4 %, cuisson à la
poêle avec un fond de matière grasse 1 à 3 %.

Si rien n'est frit, réponds {"frits":[],"absorption_pct":0}.

Recette :
${recipeText || "(texte indisponible)"}

Ingrédients (identifiant : quantité nom) :
${args.ingredients
  .map((i, index) => `- "${index}" : ${[i.qty, i.unit, i.name].filter(Boolean).join(" ")}`)
  .join("\n")}

Format strict : {"frits":[{"id":"0"}],"absorption_pct":10}`;

  try {
    const verdict = await askJson({
      prompt,
      ctx: {
        correlationId: `fry-absorption-${args.recipeId ?? "norecipe"}`,
        feature: "estimate_fry_absorption",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
      outputSchema: {
        name: "fry_absorption",
        schema: FRY_ABSORPTION_SCHEMA as unknown as Record<string, unknown>,
      },
      validate: (parsed) => {
        const record = parsed as { frits?: unknown; absorption_pct?: unknown };
        if (!Array.isArray(record.frits)) return null;
        const pct = Number(record.absorption_pct);
        if (!Number.isFinite(pct)) return null;
        return { frits: record.frits, pct };
      },
    });

    const friedIndices: number[] = [];
    for (const entry of verdict.frits) {
      if (!entry || typeof entry !== "object") continue;
      const index = Number((entry as Record<string, unknown>).id);
      if (!Number.isInteger(index) || index < 0 || index >= args.ingredients.length) continue;
      if (!friedIndices.includes(index)) friedIndices.push(index);
    }

    // Le modèle répond en pourcentage ; un modèle qui répond « 0,1 » pour dix
    // pour cent n'est pas rattrapé ici — 0,1 % d'absorption est un résultat
    // plausible pour une cuisson à sec, et le deviner ferait plus de dégâts.
    const ratio = friedIndices.length === 0 ? 0 : Math.max(0, verdict.pct) / 100;

    await logInfo({
      message: `estimateFryAbsorptionWithAI: ${friedIndices.length} ingrédient(s) frit(s), ${verdict.pct} % absorbés`,
      extra: { recipeId: args.recipeId },
    });

    return {
      friedIndices,
      absorptionRatio: Math.min(ratio, MAX_FRY_ABSORPTION_RATIO),
    };
  } catch (err) {
    await logError({
      message: "estimateFryAbsorptionWithAI: échec, la recette est calculée sans huile absorbée",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { recipeId: args.recipeId, userId: args.userId ?? null },
    });
    return FAILED_FRY_ABSORPTION;
  }
}
