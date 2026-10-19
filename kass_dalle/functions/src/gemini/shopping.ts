import { extractJsonArray } from "./client";
import { callModel } from "../ai/router";
import { logError } from "../logging";
import { textPart, type ModelCallContext } from "../ai/types";
import { type AiUsageMeta } from "./tokenUsage";

export interface ShoppingIngredientInput {
  name: string;
  qty?: string | null;
  unit?: string | null;
  source?: string | null;
}

export interface ShoppingProductResult {
  name: string;
  qty: string;
  unit: string;
  ingredientIndices: number[];
}

export interface ShoppingConsolidationOptions {
  /**
   * Poste fonctionnel de l'appel — clé de routage ET d'imputation des coûts.
   *
   * Les deux étaient auparavant réglables séparément (`geminiFeature` pour le
   * log, `usageFeature` pour la facture). Deux noms pour un même appel rendaient
   * impossible de lire, sur la même clé, ce qu'un moteur coûte et ce qu'il rend.
   */
  feature?: string;
  /** Comptabilise la consommation (défaut : true). */
  recordUsage?: boolean;
  timeoutMs?: number;
  usageMeta?: AiUsageMeta;
}

function cleanText(value: string | null | undefined): string {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeIndices(value: unknown, max: number): number[] {
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(
      value
        .map((entry) => (typeof entry === "number" ? entry : Number(entry)))
        .filter((entry) => Number.isInteger(entry) && entry >= 0 && entry < max),
    ),
  ];
}

export async function consolidateShoppingList(
  apiKey: string,
  ingredients: ShoppingIngredientInput[],
  ctx: ModelCallContext,
  options: ShoppingConsolidationOptions = {},
): Promise<ShoppingProductResult[]> {
  if (ingredients.length === 0) return [];

  const lines: string[] = [];
  lines.push("Tu transformes une liste d'ingrédients culinaires en vraie liste de courses.");
  lines.push(
    "Objectif: retourner des produits achetables, consolidés, avec quantités totales pertinentes.",
  );
  lines.push("");
  lines.push("Règles impératives:");
  lines.push("- Tu retournes une LISTE DE COURSES, pas une liste d'ingrédients de recette.");
  lines.push(
    "- Fusionne les variantes d'un même produit: singulier/pluriel, genre, accents, qualificatifs de découpe/cuisson/préparation.",
  );
  lines.push(
    "- Exemples: ail, gousse d'ail, gousses d'ail => même produit ; oignon, oignon haché, oignon coupé, oignon brûlé => même produit 'oignons'.",
  );
  lines.push(
    "- Supprime les qualificatifs culinaires inutiles à l'achat: haché, émincé, coupé, ciselé, brûlé, frais si cela ne change pas le produit acheté.",
  );
  lines.push("- Conserve une séparation uniquement si le produit acheté est réellement différent.");
  lines.push("- Additionne les quantités quand c'est fiable et que l'unité est compatible.");
  lines.push(
    "- Si les unités ne sont pas compatibles, crée plusieurs lignes distinctes plutôt qu'un total faux.",
  );
  lines.push(
    '- Pour les produits comptés à la pièce, préfère un libellé naturel dans \'name\' et laisse \'unit\' vide. Exemple: {"name":"gousses d\'ail","qty":"5","unit":""}.',
  );
  lines.push(
    '- Pour les produits pondérés/mesurés, garde \'name\' simple et mets l\'unité dans \'unit\'. Exemple: {"name":"farine","qty":"500","unit":"g"}.',
  );
  lines.push("- Réponds UNIQUEMENT avec un tableau JSON valide.");
  lines.push("");
  lines.push("Format JSON attendu pour chaque ligne:");
  lines.push('{"name":"...","qty":"...","unit":"...","ingredient_indices":[0,2]}');
  lines.push("");
  lines.push("Contraintes JSON:");
  lines.push(
    "- 'ingredient_indices' doit contenir les indices exacts des lignes d'entrée fusionnées.",
  );
  lines.push("- 'name', 'qty' et 'unit' sont des chaînes.");
  lines.push("- N'invente aucun indice.");
  lines.push("- N'ajoute aucun commentaire, markdown ou texte hors JSON.");
  lines.push("");
  lines.push("Entrée:");
  ingredients.forEach((ingredient, index) => {
    const qty = cleanText(ingredient.qty);
    const unit = cleanText(ingredient.unit);
    const name = cleanText(ingredient.name);
    const source = cleanText(ingredient.source);
    const parts = [
      `#${index}`,
      qty.length > 0 ? `qty=${qty}` : "qty=?",
      unit.length > 0 ? `unit=${unit}` : "unit=",
      `name=${name}`,
      source.length > 0 ? `source=${source}` : "",
    ].filter((part) => part.length > 0);
    lines.push(`- ${parts.join(" | ")}`);
  });

  const result = await callModel({
    parts: [textPart(lines.join("\n"))],
    ctx: {
      ...ctx,
      feature: options.feature ?? "shopping_list",
      timeoutMs: options.timeoutMs ?? 2 * 60 * 1000,
    },
    recordUsage: options.recordUsage,
    usageMeta: options.usageMeta,
  });

  const text = result.text.trim();
  if (!text) return [];

  try {
    const parsed = JSON.parse(extractJsonArray(text)) as Array<{
      name?: unknown;
      qty?: unknown;
      unit?: unknown;
      ingredient_indices?: unknown;
      ingredientIndices?: unknown;
    }>;

    return parsed
      .map((entry) => {
        const name = cleanText(typeof entry.name === "string" ? entry.name : "");
        const qty = cleanText(typeof entry.qty === "string" ? entry.qty : "");
        const unit = cleanText(typeof entry.unit === "string" ? entry.unit : "");
        const ingredientIndices = normalizeIndices(
          entry.ingredient_indices ?? entry.ingredientIndices,
          ingredients.length,
        );

        if (name.length === 0 || ingredientIndices.length === 0) {
          return null;
        }

        return {
          name,
          qty,
          unit,
          ingredientIndices,
        } satisfies ShoppingProductResult;
      })
      .filter((entry): entry is ShoppingProductResult => entry !== null);
  } catch (err) {
    // Réponse du modèle illisible : la liste reste sans regroupement, et
    // l'appel facturé est visible dans les journaux (ticket #159). Ni le texte
    // de la réponse ni les ingrédients ne sont journalisés.
    await logError({
      message: "Courses : réponse du modèle illisible, aucun regroupement rendu",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: ctx.moduleType,
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      jobId: ctx.jobId,
      feature: options.feature ?? "shopping_list",
      extra: { ingredientCount: ingredients.length, responseChars: text.length },
    });
    return [];
  }
}
