/**
 * Estimation du coût d'un import de livre, d'après ce que les imports
 * précédents ont réellement coûté.
 *
 * Aucun prix figé, aucun coût moyen écrit dans le code : le projet interdit
 * d'afficher une valeur plausible à la place d'une mesure. L'estimation est la
 * moyenne constatée sur les derniers scans de l'utilisateur, multipliée par le
 * nombre de tranches du livre. Sans assez de scans pour la mesurer, elle est
 * absente — et l'écran le dit.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_AI_USAGE, COLL_PROCESSING_JOBS } from "../config";

/** Combien de scans passés servent de référence. `in` accepte trente valeurs au plus. */
const SAMPLE_SCANS = 15;

/** En dessous, une moyenne ne mesure rien : elle serait un ou deux imports isolés. */
const MIN_SCANS = 3;

export interface UsageRow {
  scanId: string;
  /** `null` pour un appel enregistré pendant une panne de la grille tarifaire. */
  costUsd: number | null;
}

export interface CostReference {
  /** Coût moyen d'un scan en dollars, ou `null` si la mesure manque. */
  meanUsd: number | null;
  /** Nombre de scans complets qui ont servi à la mesure. */
  scans: number;
}

/**
 * Moyenne, par scan, de la somme des appels d'IA qu'il a déclenchés.
 *
 * Un scan dont un appel n'a pas de montant est écarté : sa somme serait
 * inférieure à la réalité, et la moyenne la tirerait vers le bas sans que rien
 * ne l'indique. Un coût manquant se voit ; un coût faux, non.
 */
export function meanCostPerScan(rows: UsageRow[], minScans: number = MIN_SCANS): CostReference {
  const totals = new Map<string, { sum: number; incomplete: boolean }>();
  for (const row of rows) {
    const total = totals.get(row.scanId) ?? { sum: 0, incomplete: false };
    if (row.costUsd == null) total.incomplete = true;
    else total.sum += row.costUsd;
    totals.set(row.scanId, total);
  }
  const complete = [...totals.values()].filter((t) => !t.incomplete && t.sum > 0);
  if (complete.length < minScans) return { meanUsd: null, scans: complete.length };
  const mean = complete.reduce((sum, t) => sum + t.sum, 0) / complete.length;
  return { meanUsd: mean, scans: complete.length };
}

/** Le coût moyen d'un scan de cet utilisateur, mesuré sur ses derniers imports réussis. */
export async function referenceCostPerScan(userId: string): Promise<CostReference> {
  const db = getFirestore();
  const jobs = await db
    .collection(COLL_PROCESSING_JOBS)
    .where("created_by", "==", userId)
    .where("status", "==", "done")
    .limit(80)
    .get();

  const candidates = jobs.docs
    .map((doc) => doc.data())
    .filter(
      (data) =>
        typeof data.scan_id === "string" &&
        data.scan_id.length > 0 &&
        (data.type === undefined || data.type === "recipeScan") &&
        Array.isArray(data.created_recipe_ids) &&
        data.created_recipe_ids.length > 0,
    )
    .sort((a, b) => {
      const at = a.created_at?.toMillis?.() ?? 0;
      const bt = b.created_at?.toMillis?.() ?? 0;
      return bt - at;
    });

  const scanIds = [...new Set(candidates.map((data) => data.scan_id as string))].slice(
    0,
    SAMPLE_SCANS,
  );
  if (scanIds.length === 0) return { meanUsd: null, scans: 0 };

  const usage = await db.collection(COLL_AI_USAGE).where("scan_id", "in", scanIds).get();
  const rows: UsageRow[] = usage.docs.map((doc) => {
    const data = doc.data();
    const cost = data.estimated_cost_usd;
    return {
      scanId: data.scan_id as string,
      costUsd: typeof cost === "number" && Number.isFinite(cost) ? cost : null,
    };
  });
  return meanCostPerScan(rows);
}
