import { getKnownUnitMetadata } from "./quantityConversion";

export type UnitResolutionSource =
  | "explicit_known"
  | "explicit_unknown"
  | "inferred_from_ingredient"
  | "empty";

export interface UnitResolvedIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string | null;
  unit_raw: string;
  unit_canonical: string;
  unit_resolution_source: UnitResolutionSource;
  unit_resolution_confidence: number;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asCategory(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function resolveIngredientUnitFields(ingredient: {
  name?: unknown;
  qty?: unknown;
  unit?: unknown;
  category?: unknown;
}): UnitResolvedIngredient {
  const name = asString(ingredient.name).trim();
  const qty = asString(ingredient.qty);
  const unit = asString(ingredient.unit).trim();
  const category = asCategory(ingredient.category);

  const metadata = getKnownUnitMetadata(unit, name);
  if (unit.length > 0) {
    if (metadata) {
      return {
        name,
        qty,
        unit,
        category,
        unit_raw: unit,
        unit_canonical: metadata.normalizedUnit,
        unit_resolution_source: "explicit_known",
        unit_resolution_confidence: 1,
      };
    }
    return {
      name,
      qty,
      unit,
      category,
      unit_raw: unit,
      unit_canonical: "",
      unit_resolution_source: "explicit_unknown",
      unit_resolution_confidence: 0.2,
    };
  }

  const inferred = getKnownUnitMetadata("", name);
  if (inferred) {
    return {
      name,
      qty,
      unit: "",
      category,
      unit_raw: "",
      unit_canonical: inferred.normalizedUnit,
      unit_resolution_source: "inferred_from_ingredient",
      unit_resolution_confidence: 0.75,
    };
  }

  return {
    name,
    qty,
    unit: "",
    category,
    unit_raw: "",
    unit_canonical: "",
    unit_resolution_source: "empty",
    unit_resolution_confidence: 0,
  };
}

/**
 * Recouvre un ingrédient stocké de ses seuls champs d'unité recalculés.
 *
 * La résolution d'unité ne possède que sept champs. Reconstruire un objet neuf
 * à partir d'eux efface tout ce que les autres traitements ont écrit : la
 * catégorie (donc la section CookLang à l'affichage) et l'identité
 * référentielle. Cette fonction existe pour que cet oubli ne soit plus
 * possible en écrivant `{ name, qty, unit, … }` à la main.
 */
export function withResolvedUnitFields<T extends Record<string, unknown>>(
  stored: T,
  resolved: UnitResolvedIngredient,
): Record<string, unknown> {
  return {
    ...stored,
    name: resolved.name,
    qty: resolved.qty,
    unit: resolved.unit,
    unit_raw: resolved.unit_raw,
    unit_canonical: resolved.unit_canonical,
    unit_resolution_source: resolved.unit_resolution_source,
    unit_resolution_confidence: resolved.unit_resolution_confidence,
  };
}

export function enrichIngredientsWithUnitResolution(ingredients: unknown[]): UnitResolvedIngredient[] {
  return ingredients
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => resolveIngredientUnitFields(item));
}
