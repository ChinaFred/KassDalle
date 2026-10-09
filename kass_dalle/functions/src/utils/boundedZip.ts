/**
 * Lecture bornée d'une archive ZIP (DOCX, EPUB).
 *
 * Un DOCX et un EPUB sont des archives ZIP envoyées par l'utilisateur. Une
 * archive de quelques mégaoctets peut se déplier en plusieurs gigaoctets (bombe
 * zip), ou déclarer des centaines de milliers d'entrées : la fonction qui la
 * lit dépasse alors sa mémoire et tombe, à chaque relance du job (audit
 * sécurité, « Faible »).
 *
 * Trois bornes, vérifiées pendant la lecture et non sur les tailles déclarées
 * dans l'archive, qui se falsifient :
 *
 *  - le nombre d'entrées de l'archive ;
 *  - la taille dépliée d'une entrée ;
 *  - la taille dépliée cumulée de tout ce qu'on lit dans l'archive.
 *
 * La lecture s'arrête dès qu'une borne est franchie : on ne déplie jamais plus
 * que la borne, plus un bloc.
 */

import JSZip from "jszip";

export interface ZipLimits {
  /** Nombre d'entrées (fichiers et dossiers) que l'archive peut contenir. */
  maxEntries: number;
  /** Taille dépliée d'une entrée, en octets. */
  maxEntryBytes: number;
  /** Taille dépliée cumulée de toutes les entrées lues, en octets. */
  maxTotalBytes: number;
}

/**
 * Bornes par défaut. Une décision, pas une mesure : un livre EPUB courant
 * compte quelques centaines d'entrées et quelques dizaines de mégaoctets
 * dépliés ; un DOCX, un seul `word/document.xml` de quelques mégaoctets.
 * Les bornes laissent un facteur dix au moins au-dessus.
 */
export const DEFAULT_ZIP_LIMITS: ZipLimits = {
  maxEntries: 10_000,
  maxEntryBytes: 50 * 1024 * 1024,
  maxTotalBytes: 200 * 1024 * 1024,
};

/** L'archive franchit une borne. Le message est lisible par l'utilisateur. */
export class ZipLimitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ZipLimitError";
  }
}

const MIB = 1024 * 1024;

function mib(bytes: number): string {
  return `${Math.round(bytes / MIB)} Mo`;
}

/** Une archive ouverte, dont chaque lecture compte contre les bornes. */
export class BoundedZip {
  private readBytes = 0;

  private constructor(
    private readonly archive: JSZip,
    private readonly limits: ZipLimits,
  ) {}

  /**
   * Ouvre l'archive et vérifie le nombre d'entrées. Ne déplie rien.
   *
   * Le nombre d'entrées se contrôle **avant** `JSZip.loadAsync`, en comptant
   * les signatures d'en-tête central dans tout le buffer
   * (`countCentralSignatures`). JSZip construit un objet par en-tête, et une
   * archive qui en porte des millions saturerait la mémoire avant tout contrôle.
   */
  static async open(bytes: Buffer, limits: ZipLimits = DEFAULT_ZIP_LIMITS): Promise<BoundedZip> {
    // Compté sur les octets, pas sur les annonces de l'archive : l'EOCD se
    // falsifie, et JSZip ne s'arrête pas à son compteur.
    const signatures = countCentralSignatures(bytes, limits.maxEntries + 1);
    if (signatures > limits.maxEntries) {
      throw new ZipLimitError(
        `archive trop fragmentée : plus de ${limits.maxEntries} en-têtes d'entrée`,
      );
    }
    const archive = await JSZip.loadAsync(bytes);
    // Second contrôle, filet de sécurité : le nombre d'entrées que JSZip a lues.
    const entries = Object.keys(archive.files).length;
    if (entries > limits.maxEntries) {
      throw new ZipLimitError(
        `archive trop fragmentée : ${entries} entrées, au-delà de ${limits.maxEntries}`,
      );
    }
    return new BoundedZip(archive, limits);
  }

  /** Vrai si l'entrée existe et n'est pas un dossier. */
  has(path: string): boolean {
    return this.archive.file(path) != null;
  }

  /** Contenu d'une entrée en texte UTF-8, ou `null` si elle n'existe pas. */
  async text(path: string): Promise<string | null> {
    const bytes = await this.bytes(path);
    return bytes == null ? null : bytes.toString("utf8");
  }

  /** Contenu brut d'une entrée, ou `null` si elle n'existe pas. */
  async bytes(path: string): Promise<Buffer | null> {
    const entry = this.archive.file(path);
    if (!entry) return null;
    return this.readBounded(entry, path);
  }

  private readBounded(entry: JSZip.JSZipObject, path: string): Promise<Buffer> {
    const { maxEntryBytes, maxTotalBytes } = this.limits;
    return new Promise<Buffer>((resolve, reject) => {
      const chunks: Buffer[] = [];
      let entryBytes = 0;
      let settled = false;
      const stream = entry.nodeStream("nodebuffer");

      const fail = (err: Error) => {
        if (settled) return;
        settled = true;
        stream.pause();
        stream.removeAllListeners("data");
        reject(err);
      };

      stream.on("data", (chunk: Buffer) => {
        if (settled) return;
        entryBytes += chunk.length;
        this.readBytes += chunk.length;
        if (entryBytes > maxEntryBytes) {
          fail(
            new ZipLimitError(
              `entrée « ${path} » trop volumineuse une fois dépliée : au-delà de ${mib(maxEntryBytes)}`,
            ),
          );
          return;
        }
        if (this.readBytes > maxTotalBytes) {
          fail(
            new ZipLimitError(
              `archive trop volumineuse une fois dépliée : au-delà de ${mib(maxTotalBytes)}`,
            ),
          );
          return;
        }
        chunks.push(chunk);
      });
      stream.on("error", (err: unknown) => {
        fail(err instanceof Error ? err : new Error(String(err)));
      });
      stream.on("end", () => {
        if (settled) return;
        settled = true;
        resolve(Buffer.concat(chunks));
      });
    });
  }
}

/** Signature d'un en-tête du répertoire central : `PK\x01\x02`. */
const CENTRAL_HEADER_SIGNATURE = Buffer.from([0x50, 0x4b, 0x01, 0x02]);

/**
 * Nombre d'occurrences de la signature d'en-tête central (`50 4B 01 02`) dans
 * tout le buffer, compté jusqu'à `stopAt` au plus.
 *
 * Chaque entrée que JSZip construit commence par cette signature, à une
 * position distincte : ce compte majore toujours le nombre d'entrées de JSZip,
 * quel que soit l'endroit d'où il part (EOCD hors de sa fenêtre de recherche,
 * octets préfixés, en-tête leurre, ZIP64 au localisateur forgé). Il ne lit
 * aucune annonce de l'archive, qui se falsifie. Une signature qui apparaît
 * par hasard dans des données compressées compte en trop : le compte ne peut
 * que surestimer, jamais laisser passer.
 */
export function countCentralSignatures(bytes: Buffer, stopAt: number): number {
  let count = 0;
  let from = 0;
  while (count < stopAt) {
    const at = bytes.indexOf(CENTRAL_HEADER_SIGNATURE, from);
    if (at < 0) break;
    count++;
    from = at + 1;
  }
  return count;
}
