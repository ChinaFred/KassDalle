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

/**
 * Jobs lus pour retrouver ces scans.
 *
 * Les tranches d'un livre importé sont des jobs ordinaires : un seul livre en
 * compte une centaine, et remplissait à lui seul les quatre-vingts lus
 * autrefois. La lecture est plus large, et les tranches sont écartées plus bas.
 */
const SAMPLE_JOBS = 300;

/** Combien de livres importés servent de référence pour le coût d'une tranche. */
const SAMPLE_BOOKS = 3;

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
    .limit(SAMPLE_JOBS)
    .get();

  const candidates = jobs.docs
    .map((doc) => doc.data())
    .filter(
      (data) =>
        typeof data.scan_id === "string" &&
        data.scan_id.length > 0 &&
        (data.type === undefined || data.type === "recipeScan") &&
        // Une tranche de livre appartient à un scan de plusieurs dizaines de
        // jobs : sa somme n'est pas celle d'une page, et la mêler à la moyenne
        // l'aurait multipliée par le nombre de tranches du livre suivant.
        !data.book_window &&
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

export interface BookCostRow {
  /** Nombre de tranches du livre. */
  windows: number;
  /** Somme des appels d'IA du scan, ou `null` si l'un d'eux n'a pas de montant. */
  costUsd: number | null;
}

export interface BookCostReference {
  /** Coût moyen d'une tranche en dollars, ou `null` si aucun livre ne le mesure. */
  perWindowUsd: number | null;
  /** Nombre de livres qui ont servi à la mesure. */
  books: number;
}

/**
 * Coût moyen d'une tranche, mesuré sur des livres déjà importés.
 *
 * C'est la somme des coûts divisée par la somme des tranches, pas la moyenne des
 * coûts par tranche : un livre de trois cents tranches pèse trois cents fois
 * plus qu'un livre de dix. Un livre dont un appel n'a pas de montant est écarté,
 * pour la raison qui vaut pour les scans : sa somme serait inférieure à la
 * réalité, et rien ne l'indiquerait.
 */
export function costPerWindowOfBooks(rows: BookCostRow[]): BookCostReference {
  const complete = rows.filter(
    (row): row is { windows: number; costUsd: number } =>
      row.costUsd != null && row.costUsd > 0 && row.windows > 0,
  );
  if (complete.length === 0) return { perWindowUsd: null, books: 0 };
  const cost = complete.reduce((sum, row) => sum + row.costUsd, 0);
  const windows = complete.reduce((sum, row) => sum + row.windows, 0);
  return { perWindowUsd: cost / windows, books: complete.length };
}

/**
 * Le coût moyen d'une tranche de cet utilisateur, mesuré sur ses derniers livres.
 *
 * Une tranche de livre coûte plus qu'une page scannée : elle en lit trois, plus
 * une de contexte, et elle peut porter une recette entière. Quand un livre a déjà
 * été importé, sa mesure remplace celle des pages scannées.
 */
export async function referenceCostPerWindow(userId: string): Promise<BookCostReference> {
  const db = getFirestore();
  const parents = await db
    .collection(COLL_PROCESSING_JOBS)
    .where("created_by", "==", userId)
    .where("type", "==", "bookDocumentScan")
    .where("status", "==", "done")
    .limit(30)
    .get();

  const recent = parents.docs
    .map((doc) => doc.data())
    .filter(
      (data) =>
        typeof data.scan_id === "string" &&
        data.scan_id.length > 0 &&
        Number(data.windows_total) > 0,
    )
    .sort((a, b) => (b.created_at?.toMillis?.() ?? 0) - (a.created_at?.toMillis?.() ?? 0))
    .slice(0, SAMPLE_BOOKS);
  if (recent.length === 0) return { perWindowUsd: null, books: 0 };

  const rows = await Promise.all(
    recent.map(async (data): Promise<BookCostRow> => {
      const usage = await db
        .collection(COLL_AI_USAGE)
        .where("scan_id", "==", data.scan_id as string)
        .get();
      let sum = 0;
      let incomplete = false;
      for (const doc of usage.docs) {
        const cost = doc.data().estimated_cost_usd;
        if (typeof cost === "number" && Number.isFinite(cost)) sum += cost;
        else incomplete = true;
      }
      return { windows: Number(data.windows_total), costUsd: incomplete ? null : sum };
    }),
  );
  return costPerWindowOfBooks(rows);
}
