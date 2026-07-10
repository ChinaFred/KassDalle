import { getFirestore } from "firebase-admin/firestore";
import { COLL_APP_CONFIG } from "../config";

export interface NutritionSourcePriority {
  source: string;
  rank: number;
  enabled: boolean;
}

export interface NutritionSourcePolicy {
  version: number;
  source_priority: NutritionSourcePriority[];
  nutrient_aliases: Record<string, string>;
  fallback_policy: "off" | "strict" | "permissive";
  quality_policy: {
    minCoverageForPartial: number;
    minCoverageForPer100g: number;
    kcalConsistencyWarnDeltaPct: number;
  };
  updated_at?: FirebaseFirestore.FieldValue | FirebaseFirestore.Timestamp;
}

export const NUTRITION_POLICY_DOC_ID = "nutrition_source_policy";

export const DEFAULT_NUTRITION_POLICY: NutritionSourcePolicy = {
  version: 1,
  source_priority: [
    { source: "user_validated", rank: 1, enabled: true },
    { source: "internal_reference", rank: 2, enabled: true },
    { source: "external_reference", rank: 3, enabled: true },
    { source: "ai_estimated", rank: 4, enabled: true },
  ],
  nutrient_aliases: {
    sodium: "sodium_mg",
    sel: "salt_g",
    salt: "salt_g",
    kcal: "kcal",
  },
  fallback_policy: "strict",
  quality_policy: {
    minCoverageForPartial: 0.7,
    minCoverageForPer100g: 0.9,
    kcalConsistencyWarnDeltaPct: 0.15,
  },
};

export async function getNutritionSourcePolicy(): Promise<NutritionSourcePolicy> {
  const db = getFirestore();
  const ref = db.collection(COLL_APP_CONFIG).doc(NUTRITION_POLICY_DOC_ID);
  const snap = await ref.get();
  if (!snap.exists) {
    return DEFAULT_NUTRITION_POLICY;
  }

  const data = snap.data() as Partial<NutritionSourcePolicy> | undefined;
  if (!data) return DEFAULT_NUTRITION_POLICY;

  return {
    version: typeof data.version === "number" ? data.version : DEFAULT_NUTRITION_POLICY.version,
    source_priority: Array.isArray(data.source_priority) && data.source_priority.length > 0
      ? data.source_priority
      : DEFAULT_NUTRITION_POLICY.source_priority,
    nutrient_aliases: data.nutrient_aliases ?? DEFAULT_NUTRITION_POLICY.nutrient_aliases,
    fallback_policy: data.fallback_policy ?? DEFAULT_NUTRITION_POLICY.fallback_policy,
    quality_policy: {
      minCoverageForPartial:
        data.quality_policy?.minCoverageForPartial ?? DEFAULT_NUTRITION_POLICY.quality_policy.minCoverageForPartial,
      minCoverageForPer100g:
        data.quality_policy?.minCoverageForPer100g ?? DEFAULT_NUTRITION_POLICY.quality_policy.minCoverageForPer100g,
      kcalConsistencyWarnDeltaPct:
        data.quality_policy?.kcalConsistencyWarnDeltaPct ??
        DEFAULT_NUTRITION_POLICY.quality_policy.kcalConsistencyWarnDeltaPct,
    },
  };
}
