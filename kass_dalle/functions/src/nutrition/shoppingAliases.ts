/**
 * Le produit qu'on achète pour un ingrédient — lu dans le référentiel, et
 * résolu auprès du modèle quand il manque.
 *
 * « 150 g de beurre fondu » n'est pas un produit : on achète du beurre. « 2
 * jaunes d'œuf » non plus : on achète des œufs. Ce jugement était rendu par le
 * modèle quand il composait la liste de courses ; l'addition qui l'a remplacé
 * ne le rend pas. Il vit maintenant dans `nutrition_ingredients.shopping_product`,
 * posé automatiquement pour un ingrédient neuf à l'écriture d'une recette
 * (`recipeNutritionAutoSync.ts`), rattrapé pour le passé par le backfill
 * « Produit acheté des ingrédients », et corrigé à la main depuis
 * Admin › Référentiels › Ingrédients.
 *
 * Trois états du champ :
 *  - absent : jamais examiné ;
 *  - vide : examiné, le nom est déjà le produit ;
 *  - renseigné : le produit acheté, qui remplace le nom sur la liste.
 */

import { askJson } from "../ai/askJson";
import { COLL_NUTRITION_INGREDIENTS } from "../config";
import { buildIngredientLookupIds } from "./ingredientName";
import { readDocsByIds } from "./firestoreBatch";
import { shoppingProductKey } from "./shoppingDerivation";

/**
 * Alias de courses des ingrédients nommés, indexés par nom tel que fourni.
 *
 * Un nom sans alias n'a pas d'entrée. Les identifiants sont essayés du plus
 * précis au plus général (`buildIngredientLookupIds`) ; le premier document
 * qui porte le champ décide, même vide — un « déjà le produit » sur le
 * document strict n'est pas contredit par un alias posé sur une forme plus
 * générale.
 */
export async function loadShoppingProductAliases(
  names: Iterable<string>,
): Promise<Map<string, string>> {
  const wanted = new Map<string, string[]>();
  for (const raw of names) {
    const name = (raw ?? "").trim();
    if (!name || wanted.has(name)) continue;
    wanted.set(name, buildIngredientLookupIds(name));
  }
  const out = new Map<string, string>();
  if (wanted.size === 0) return out;

  const ids = [...new Set([...wanted.values()].flat())];
  const docs = await readDocsByIds(COLL_NUTRITION_INGREDIENTS, ids);

  for (const [name, lookupIds] of wanted) {
    for (const id of lookupIds) {
      const doc = docs.get(id);
      if (!doc) continue;
      const alias = doc.shopping_product;
      if (typeof alias !== "string") continue;
      const trimmed = alias.trim();
      if (trimmed) out.set(name, trimmed);
      break;
    }
  }
  return out;
}

// ── Résolution auprès du modèle ──────────────────────────────────────────────

/** Ingrédient du référentiel sans produit acheté connu. */
export interface ShoppingAliasCandidate {
  id: string;
  name: string;
}

/** Résolution d'un candidat : ce qui est prêt à écrire dans `shopping_product`. */
export interface ShoppingAliasResolution {
  id: string;
  /** À écrire dans `shopping_product`. Vide = le nom lui-même. */
  product: string;
  /**
   * Vrai quand le produit a été aligné sur un ingrédient déjà connu du
   * référentiel, plutôt que sur le texte proposé tel quel par le modèle —
   * « beurre fondu » reprend l'orthographe exacte de l'ingrédient « beurre »
   * qui existe déjà, au lieu d'une variante inventée par le modèle qui ne
   * fusionnerait pas avec lui sur la liste de courses.
   */
  matchedExisting: boolean;
}

/** Ingrédients soumis au modèle en un appel. */
const ALIAS_BATCH_SIZE = 40;

const ALIAS_SCHEMA = {
  type: "object",
  properties: {
    produits: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          produit: { type: "string" },
        },
        required: ["id", "produit"],
        additionalProperties: false,
      },
    },
  },
  required: ["produits"],
  additionalProperties: false,
} as const;

function buildAliasPrompt(batch: readonly ShoppingAliasCandidate[]): string {
  return `Tu prépares une LISTE DE COURSES. Pour chaque ingrédient de recette ci-dessous,
donne le PRODUIT tel qu'on l'achète au magasin, au singulier, sans quantité.

Règles :
- Une préparation ou un état ramène au produit brut : « beurre fondu » → beurre,
  « oignon haché » → oignon, « chocolat fondu » → chocolat, « pommes de terre
  cuites » → pomme de terre.
- Une partie d'un produit ramène au produit : « jaune d'œuf » → œuf,
  « blanc d'œuf » → œuf, « gousse d'ail » → ail, « zeste de citron » → citron.
- Un produit qui s'achète tel quel garde son nom, à l'identique : « huile
  d'olive » → huile d'olive, « lait de coco » → lait de coco, « sauce soja »
  → sauce soja. Ne pas généraliser : « crème fraîche épaisse » n'est pas
  « crème », c'est un produit différent au rayon.
- Ne change ni la langue ni la nature du produit. Dans le doute, renvoie le
  nom inchangé.

Ingrédients (identifiant : nom) :
${batch.map((p, index) => `- "${index}" : ${p.name}`).join("\n")}

Format strict : {"produits":[{"id":"0","produit":"beurre"}]}`;
}

/**
 * Résout UN lot (quarante au plus) de candidats auprès du modèle.
 *
 * Un produit identique au nom — au singulier, à la casse et aux accents près
 * — n'est pas un alias : `product` vaut alors chaîne vide, la convention du
 * champ pour « déjà le produit ». Sinon, si le produit proposé correspond à
 * un ingrédient déjà présent dans le référentiel, l'orthographe de CET
 * ingrédient remplace celle du modèle — deux appels ne doivent pas inventer
 * deux graphies pour le même achat. Un candidat que le modèle n'a pas traité
 * est simplement absent du résultat : à l'appelant de décider s'il redemande.
 *
 * Jette en cas d'échec de l'appel — réseau, JSON illisible : à l'appelant de
 * décider s'il réessaie ce lot ou l'abandonne.
 */
export async function resolveShoppingAliasBatch(
  batch: readonly ShoppingAliasCandidate[],
  ctx: { correlationId: string; userId?: string; feature: string },
): Promise<ShoppingAliasResolution[]> {
  if (batch.length === 0) return [];

  const answers = await askJson({
    prompt: buildAliasPrompt(batch),
    ctx: {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      feature: ctx.feature,
      moduleType: "DESIGN",
      timeoutMs: 60_000,
    },
    outputSchema: {
      name: "shopping_product_aliases",
      schema: ALIAS_SCHEMA as unknown as Record<string, unknown>,
    },
    validate: (parsed) => {
      const list = (parsed as { produits?: unknown }).produits;
      return Array.isArray(list) ? list : null;
    },
  });

  // Une seule passe sur la réponse : les indices valides, avec leur produit
  // brut — « déjà le produit » compris, distingué par une chaîne vide.
  const answered = new Map<number, string>();
  for (const entry of answers) {
    if (!entry || typeof entry !== "object") continue;
    const record = entry as Record<string, unknown>;
    const index = Number(record.id);
    if (!Number.isInteger(index) || index < 0 || index >= batch.length) continue;
    if (typeof record.produit !== "string") continue;
    const alias = record.produit.trim();
    if (!alias) continue;
    const sameAsName = shoppingProductKey(alias) === shoppingProductKey(batch[index].name);
    answered.set(index, sameAsName ? "" : alias);
  }

  // Une seule lecture pour tout le lot : est-ce que l'un des produits
  // proposés correspond à un ingrédient déjà présent dans le référentiel ?
  const lookupIds = new Set<string>();
  for (const alias of answered.values()) {
    if (!alias) continue;
    for (const id of buildIngredientLookupIds(alias)) lookupIds.add(id);
  }
  const existing =
    lookupIds.size > 0
      ? await readDocsByIds(COLL_NUTRITION_INGREDIENTS, [...lookupIds])
      : new Map<string, Record<string, unknown>>();

  const out: ShoppingAliasResolution[] = [];
  for (const [index, alias] of answered) {
    const candidate = batch[index];
    if (!alias) {
      out.push({ id: candidate.id, product: "", matchedExisting: false });
      continue;
    }
    let product = alias;
    let matchedExisting = false;
    for (const id of buildIngredientLookupIds(alias)) {
      if (id === candidate.id) continue;
      const doc = existing.get(id);
      if (!doc) continue;
      const canonical = typeof doc.canonical_name === "string" ? doc.canonical_name.trim() : "";
      if (canonical) {
        product = canonical;
        matchedExisting = true;
      }
      break;
    }
    out.push({ id: candidate.id, product, matchedExisting });
  }

  return out;
}

/**
 * Résout autant de lots que nécessaire, sans jamais lever d'erreur : un lot en
 * échec est journalisé et sauté, le reste continue. Pour un appel best-effort
 * — l'écriture d'une recette — où l'important est de récupérer ce qu'on peut,
 * pas de tout interrompre pour un lot malchanceux.
 */
export async function resolveShoppingProductsWithAI(
  candidates: readonly ShoppingAliasCandidate[],
  ctx: { correlationId: string; userId?: string; feature: string },
  onBatchError: (error: unknown, batch: readonly ShoppingAliasCandidate[]) => void,
): Promise<ShoppingAliasResolution[]> {
  const out: ShoppingAliasResolution[] = [];
  for (let i = 0; i < candidates.length; i += ALIAS_BATCH_SIZE) {
    const batch = candidates.slice(i, i + ALIAS_BATCH_SIZE);
    try {
      out.push(...(await resolveShoppingAliasBatch(batch, ctx)));
    } catch (err) {
      onBatchError(err, batch);
    }
  }
  return out;
}
