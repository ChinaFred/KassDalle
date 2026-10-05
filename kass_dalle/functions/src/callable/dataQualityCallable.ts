/**
 * Dashboard de qualité des données (Admin → Monitoring).
 *
 * Diagnostic en lecture seule des référentiels nutrition : aucune écriture,
 * contrairement aux backfills. Un seul passage sur `nutrition_ingredients`
 * détecte trois anomalies à la fois, un second sur `nutrition_units` la
 * quatrième.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import {
  REGION,
  COLL_NUTRITION_INGREDIENTS,
  COLL_NUTRITION_UNITS,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { ensureAdminWithAudit } from "./billingCallable";
import { hasPer100gValues } from "../nutrition/per100gEnrichment";
import { SALT_TO_SODIUM_FACTOR } from "../nutrition/nutrients";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Scan borné à 480 s : marge avant le timeout de 540 s de la fonction. */
const SCAN_DEADLINE_MS = 480_000;
const PAGE_SIZE = 500;
/** Nombre d'exemples renvoyés par catégorie — le total, lui, n'est jamais tronqué. */
const MAX_EXAMPLES = 200;

/**
 * Au-delà de 100 g de sel pour 100 g de produit, la valeur est impossible par
 * construction : un ingrédient ne peut pas peser plus de sel que son propre
 * poids. Même rôle que `MAX_PLAUSIBLE_KCAL` pour les calories — un plafond
 * physique, pas un seuil ajusté à la main.
 *
 * Ce plafond ne détecte PAS le doublement historique sel/sodium (corrigé dans
 * `nutrients.ts`) : ce bug produisait un sel et un sodium mutuellement
 * cohérents entre eux, seulement faux d'un facteur deux. Une incohérence
 * interne salt_g/sodium_mg ne se serait donc jamais levée sur les ingrédients
 * qu'il touchait.
 */
const MAX_PLAUSIBLE_SALT_G = 100;

interface DataQualityExample {
  id: string;
  label: string;
  detail: string;
}

interface DataQualityCheck {
  count: number;
  examples: DataQualityExample[];
  truncatedExamples: boolean;
}

interface GetDataQualityReportResponse {
  scanComplete: boolean;
  missingShoppingProduct: DataQualityCheck;
  incompleteNutrition: DataQualityCheck;
  implausibleSalt: DataQualityCheck;
  unconfirmedUnits: DataQualityCheck;
}

class CheckAccumulator {
  count = 0;
  private readonly examples: DataQualityExample[] = [];

  add(example: DataQualityExample): void {
    this.count++;
    if (this.examples.length < MAX_EXAMPLES) {
      this.examples.push(example);
    }
  }

  toCheck(): DataQualityCheck {
    return {
      count: this.count,
      examples: this.examples,
      truncatedExamples: this.count > this.examples.length,
    };
  }
}

function canonicalName(data: Record<string, unknown>, id: string): string {
  const name = data.canonical_name;
  return typeof name === "string" && name.trim().length > 0 ? name.trim() : id;
}

/** Sel stocké, ou dérivé du sodium quand seul celui-ci est renseigné. */
function resolveSaltG(per100g: Record<string, unknown>): number | null {
  const saltRaw = per100g.salt_g;
  if (typeof saltRaw === "number" && Number.isFinite(saltRaw)) return saltRaw;
  const sodiumRaw = per100g.sodium_mg;
  if (typeof sodiumRaw === "number" && Number.isFinite(sodiumRaw)) {
    return sodiumRaw / SALT_TO_SODIUM_FACTOR;
  }
  return null;
}

export const getDataQualityReportFn = onCall(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<GetDataQualityReportResponse> => {
    await ensureAdminWithAudit(req, "data_quality_dashboard");

    const db = getFirestore();
    const deadline = Date.now() + SCAN_DEADLINE_MS;

    const missingShoppingProduct = new CheckAccumulator();
    const incompleteNutrition = new CheckAccumulator();
    const implausibleSalt = new CheckAccumulator();
    const unconfirmedUnits = new CheckAccumulator();

    let scanComplete = true;

    // ── nutrition_ingredients : trois contrôles en un seul passage ──────────
    {
      let lastDocId: string | null = null;
      for (;;) {
        if (Date.now() > deadline) {
          scanComplete = false;
          break;
        }
        let query = db.collection(COLL_NUTRITION_INGREDIENTS).orderBy("__name__").limit(PAGE_SIZE);
        if (lastDocId) query = query.startAfter(lastDocId);

        const snap = await query.get();
        if (snap.empty) break;

        for (const doc of snap.docs) {
          lastDocId = doc.id;
          const data = doc.data() as Record<string, unknown>;
          const name = canonicalName(data, doc.id);

          if (data.shopping_product == null) {
            missingShoppingProduct.add({ id: doc.id, label: name, detail: "jamais examiné" });
          }

          const per100g = data.per100g;
          const hasNutrition = hasPer100gValues(per100g);
          const qualityStatus = data.quality_status;
          if (!hasNutrition || qualityStatus === "estimation_failed") {
            incompleteNutrition.add({
              id: doc.id,
              label: name,
              detail: hasNutrition ? "estimation_failed" : "per100g vide",
            });
          }

          if (per100g && typeof per100g === "object") {
            const saltG = resolveSaltG(per100g as Record<string, unknown>);
            if (saltG != null && saltG > MAX_PLAUSIBLE_SALT_G) {
              implausibleSalt.add({
                id: doc.id,
                label: name,
                detail: `${saltG.toFixed(1)} g de sel / 100 g`,
              });
            }
          }
        }

        if (snap.size < PAGE_SIZE) break;
      }
    }

    // ── nutrition_units : unités non confirmées ─────────────────────────────
    //
    // Collection bien plus petite que nutrition_ingredients (quelques
    // dizaines à quelques centaines d'unités) : la garder entière en mémoire
    // pour la trier par nombre de vues avant de tronquer l'échantillon est
    // sans risque, contrairement à un passage sur le référentiel nutrition.
    const unconfirmed: Array<{ id: string; label: string; seenCount: number }> = [];
    if (Date.now() <= deadline) {
      let lastDocId: string | null = null;
      for (;;) {
        if (Date.now() > deadline) {
          scanComplete = false;
          break;
        }
        let query = db.collection(COLL_NUTRITION_UNITS).orderBy("__name__").limit(PAGE_SIZE);
        if (lastDocId) query = query.startAfter(lastDocId);

        const snap = await query.get();
        if (snap.empty) break;

        for (const doc of snap.docs) {
          lastDocId = doc.id;
          const data = doc.data() as Record<string, unknown>;
          if (data.status !== "known") {
            unconfirmed.push({
              id: doc.id,
              label:
                typeof data.display_label === "string" && data.display_label
                  ? data.display_label
                  : doc.id,
              seenCount: typeof data.seen_count === "number" ? data.seen_count : 0,
            });
          }
        }

        if (snap.size < PAGE_SIZE) break;
      }
    } else {
      scanComplete = false;
    }

    // Les unités les plus rencontrées d'abord : ce sont celles qu'un admin
    // veut confirmer en priorité.
    unconfirmed.sort((a, b) => b.seenCount - a.seenCount);
    for (const unit of unconfirmed) {
      unconfirmedUnits.add({
        id: unit.id,
        label: unit.label,
        detail: `vue ${unit.seenCount} fois`,
      });
    }

    return {
      scanComplete,
      missingShoppingProduct: missingShoppingProduct.toCheck(),
      incompleteNutrition: incompleteNutrition.toCheck(),
      implausibleSalt: implausibleSalt.toCheck(),
      unconfirmedUnits: unconfirmedUnits.toCheck(),
    };
  },
);
