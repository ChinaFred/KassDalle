/**
 * Pages supplémentaires d'un job d'import — borne et téléchargement.
 *
 * `additional_file_urls` est écrit par le client. Le pipeline télécharge
 * chaque page et l'envoie au modèle : sans borne, un job écrit hors de
 * l'application pouvait en lister des centaines, toutes téléchargées en
 * parallèle dans la mémoire d'une seule instance (audit #151, ticket #156).
 *
 * La règle `processing_jobs` de `firestore.rules` porte la même borne ; ce
 * contrôle-ci couvre les jobs créés avant elle et ceux qu'un administrateur
 * modifie. `jobPages.test.ts` vérifie que les deux valeurs concordent.
 */

/** Pages supplémentaires admises par job, la première page en plus (21 au total). */
export const MAX_ADDITIONAL_FILE_URLS = 20;

/** Job dont la liste de pages dépasse la borne : refusé sans nouvel essai. */
export class TooManyPagesError extends Error {
  constructor(readonly count: number) {
    super(
      `Import refusé : ${count} pages supplémentaires, ${MAX_ADDITIONAL_FILE_URLS} au plus ` +
        `(${MAX_ADDITIONAL_FILE_URLS + 1} pages par import). Retirez des pages pour lancer l'analyse.`,
    );
    this.name = "TooManyPagesError";
  }
}

/**
 * La liste des pages supplémentaires d'un job, ou `TooManyPagesError` au-delà
 * de la borne. Absente ou d'un autre type que liste : aucune page (lecture
 * historique, inchangée). Les éléments ne sont pas filtrés ici : chacun passe
 * ensuite par `resolveJobSourcePath`, qui refuse ce qui n'est pas un chemin admis.
 */
export function readAdditionalFileUrls(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  if (raw.length > MAX_ADDITIONAL_FILE_URLS) throw new TooManyPagesError(raw.length);
  return raw as string[];
}

/**
 * Télécharge les pages une à une, dans l'ordre. Une page à la fois en
 * mémoire réseau au lieu de toutes à la fois ; l'ordre des octets rendus est
 * celui des chemins, comme avec `Promise.all`.
 */
export async function downloadInSequence(
  paths: readonly string[],
  download: (path: string) => Promise<Buffer>,
): Promise<Buffer[]> {
  const out: Buffer[] = [];
  for (const path of paths) {
    out.push(await download(path));
  }
  return out;
}

/**
 * Poids total d'un import de recette ou de couverture : page principale et
 * pages supplémentaires, 200 Mo au plus. Chaque page est bornée à 50 Mo à
 * l'envoi, mais 21 pages pouvaient peser plus d'un gigaoctet, téléchargé dans
 * la mémoire d'une seule instance. Un livre entier (`bookDocumentScan`) garde
 * sa propre borne, `MAX_BOOK_UPLOAD_SIZE_BYTES` (300 Mo), posée à l'envoi.
 */
export const MAX_IMPORT_TOTAL_BYTES = 200 * 1024 * 1024;

/** Import au-delà du poids total admis : refusé sans nouvel essai. */
export class ImportTooLargeError extends Error {
  constructor(
    readonly totalBytes: number | null,
    readonly maxBytes: number,
  ) {
    const mb = (n: number) => Math.round(n / (1024 * 1024));
    super(
      totalBytes == null
        ? "Import refusé : la taille d'un des fichiers est illisible."
        : `Import refusé : ${mb(totalBytes)} Mo au total, ${mb(maxBytes)} Mo au plus par import. ` +
            "Réduisez la taille ou le nombre des pages.",
    );
    this.name = "ImportTooLargeError";
  }
}

/**
 * Additionne la taille des fichiers d'un import, lue sur leurs métadonnées
 * Storage (`sizeOf`), avant tout téléchargement. Lève `ImportTooLargeError`
 * au-delà de `maxBytes`, ou si une taille n'est pas un entier positif ou nul
 * (Storage la rend en chaîne) : un poids inconnu ne passe pas. Rend le total.
 */
export async function assertImportSizeWithin(
  paths: readonly string[],
  sizeOf: (path: string) => Promise<unknown>,
  maxBytes: number,
): Promise<number> {
  let total = 0;
  for (const path of paths) {
    const raw = await sizeOf(path);
    const size = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw) : NaN;
    if (!Number.isSafeInteger(size) || size < 0) {
      throw new ImportTooLargeError(null, maxBytes);
    }
    total += size;
    if (total > maxBytes) throw new ImportTooLargeError(total, maxBytes);
  }
  return total;
}
