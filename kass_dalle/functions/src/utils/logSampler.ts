/**
 * Échantillonnage d'une ligne de journal répétée.
 *
 * Un refus répété (signature de webhook invalide, accès administrateur refusé)
 * n'écrit qu'un relevé par intervalle et par instance au plus, qui porte le
 * nombre de refus depuis le précédent. Un envoi massif de requêtes n'écrit
 * donc qu'une ligne par minute, et le nombre reste lisible.
 *
 * Les refus d'une rafale qui s'arrête avant la fin de l'intervalle ne sont
 * comptés qu'au relevé suivant de la même clé, sur la même instance : sans
 * nouveau refus, ils ne sont jamais écrits. La première ligne identifie déjà
 * l'émetteur ; seul le volume de la fin de rafale manque.
 *
 * Sans dépendance : testé seul (`tests/logSampler.test.ts`).
 */

/** Un relevé par intervalle au plus, avec le nombre d'événements depuis le précédent. */
export class LogSampler {
  private pending = 0;
  private lastLoggedAt: number | null = null;

  constructor(private readonly intervalMs = 60_000) {}

  /** Compte un événement ; rend le nombre à journaliser, ou `null` s'il faut se taire. */
  record(now: number): number | null {
    this.pending++;
    if (this.lastLoggedAt !== null && now - this.lastLoggedAt < this.intervalMs) return null;
    const count = this.pending;
    this.pending = 0;
    this.lastLoggedAt = now;
    return count;
  }
}

/**
 * Un [LogSampler] par clé (par exemple opération et compte) : les refus d'un
 * compte ne taisent pas ceux d'un autre.
 *
 * Le nombre de clés est borné (`maxKeys`) : au-delà, la clé la plus ancienne
 * (ordre d'insertion de la `Map`) est retirée, et seules ses données sont
 * perdues. Une clé de plus ne fait donc jamais grossir la mémoire de
 * l'instance sans limite.
 */
export class KeyedLogSampler {
  private readonly samplers = new Map<string, LogSampler>();

  constructor(
    private readonly intervalMs = 60_000,
    private readonly maxKeys = 500,
  ) {}

  /** Compte un événement de `key` ; rend le nombre à journaliser, ou `null`. */
  record(key: string, now: number): number | null {
    let sampler = this.samplers.get(key);
    if (!sampler) {
      if (this.samplers.size >= this.maxKeys) {
        const oldest = this.samplers.keys().next().value;
        if (oldest !== undefined) this.samplers.delete(oldest);
      }
      sampler = new LogSampler(this.intervalMs);
      this.samplers.set(key, sampler);
    }
    return sampler.record(now);
  }
}
