/**
 * Périodes de facturation, au format `YYYY-MM`.
 *
 * Module volontairement pur : la réconciliation comptable choisit sa période
 * toute seule quand elle est planifiée, et un mois de décalage y produirait un
 * rapport faux mais crédible — le genre d'erreur qui ne se voit pas. Isolé ici,
 * ce calcul se teste sans charger BigQuery ni le runtime Functions.
 */

/**
 * Période `AAAA-MM` d'une date, en UTC.
 *
 * Ce calcul vivait en quatre exemplaires — consommation, coûts Anthropic,
 * agrégats mensuels, et ici. Quatre copies de trois lignes, dont personne ne
 * remarquerait la divergence : un mois décalé ne casse rien, il compare
 * simplement deux périodes différentes et présente l'écart comme un fait.
 *
 * L'UTC n'est pas un détail : une heure locale tardive un 31 au soir range
 * l'appel dans le mois suivant chez l'un et pas chez l'autre.
 */
export function periodOf(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

/** Mois en cours. */
export function nowPeriod(from: Date = new Date()): string {
  return periodOf(from);
}

/**
 * Mois précédent — période de référence du rapport planifié.
 *
 * L'export de facturation GCP se consolide avec quelques jours de retard : un
 * rapport sur le mois en cours comparerait un traçage partiel à une facturation
 * partielle, et l'écart obtenu ne voudrait rien dire.
 */
export function previousPeriod(from: Date = new Date()): string {
  const y = from.getUTCFullYear();
  const monthIndex = from.getUTCMonth(); // 0 = janvier
  const year = monthIndex === 0 ? y - 1 : y;
  const month = monthIndex === 0 ? 12 : monthIndex;
  return `${year}-${String(month).padStart(2, "0")}`;
}

/** Bornes UTC d'une période : début inclus, fin exclue. */
export function periodBounds(period: string): { start: Date; end: Date } | null {
  const match = /^(\d{4})-(\d{2})$/.exec(period);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || month < 1 || month > 12) {
    return null;
  }
  return {
    start: new Date(Date.UTC(year, month - 1, 1)),
    end: new Date(Date.UTC(year, month, 1)),
  };
}
