/**
 * Chemin Storage reçu d'un client : le lire, le normaliser, le borner.
 *
 * Le serveur lit le bucket avec les droits de l'Admin SDK, hors règles Storage.
 * Un chemin posé par le client — `file_url` d'un job d'import, URL d'une
 * illustration à améliorer, visuel de dressage stocké sur une recette — ouvrait
 * donc tout le bucket à qui pouvait écrire ce champ : `rejected/…`, la
 * quarantaine d'un autre compte, ses scans. Le fichier partait ensuite au
 * modèle, et la réponse revenait à l'appelant (audit sécurité, faille 6).
 *
 * Toute lecture d'un chemin venu d'un client passe par `resolveAllowedStoragePath` :
 * le chemin est extrait de sa forme (chemin nu, `gs://`, URL de téléchargement
 * `firebasestorage.googleapis.com`), normalisé, puis comparé à la liste de
 * préfixes du flux. Un refus a lieu avant tout téléchargement et tout appel de
 * modèle.
 *
 * Pur : aucun accès au bucket, testé par `tests/storagePath.test.ts`.
 */

/** Hôte des URL rendues par `getDownloadURL`, côté client comme côté serveur. */
const DOWNLOAD_HOST = "firebasestorage.googleapis.com";

/** Hôtes de l'émulateur Storage, acceptés seulement quand l'émulateur tourne. */
const EMULATOR_HOSTS = new Set(["localhost", "127.0.0.1"]);

/** Chemin Storage refusé : hors des dossiers du flux, ou mal formé. Ne se rejoue pas. */
export class StoragePathRefusedError extends Error {
  constructor(
    readonly reference: string,
    detail: string,
  ) {
    super(detail);
    this.name = "StoragePathRefusedError";
  }
}

/**
 * Dossiers publiés : ce qu'une recette ou un livre affiche, lisible par tout
 * compte actif. Seule source admise pour une image déjà publiée qu'on relit
 * (amélioration d'une illustration, visuel de dressage précédent).
 */
export const PUBLISHED_IMAGE_PREFIXES: readonly string[] = ["illustrations/", "recipes/"];

/**
 * Dossier des fichiers promus d'un compte : là, et là seulement, qu'un import
 * lit sa source. `scanAndPromoteUploadFn` y dépose la page ou le livre contrôlé
 * (`scans/{uid}/…`, `scans/{uid}/livres/…`), et l'import d'un livre y découpe
 * ses tranches (`scans/{uid}/book_import_{jobId}/…`).
 */
export function promotedScanPrefix(uid: string): string {
  return `scans/${uid}/`;
}

/**
 * Extrait le chemin d'objet d'une référence Storage, ou `null` si la forme
 * n'est pas reconnue.
 *
 * - chemin nu : `scans/uid/page.jpg` ;
 * - `gs://<bucket>/<chemin>` ;
 * - `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<chemin encodé>?…`.
 *
 * Toute autre URL — un autre hôte, un autre schéma — est refusée. Si
 * `bucketName` est fourni, une référence qui nomme un autre bucket l'est aussi :
 * le serveur ne lit que le bucket par défaut, et lirait sinon le même chemin
 * chez lui.
 *
 * `silent` coupe la trace d'un refus (`warnRefused`), qui recopie la
 * référence brute — jeton `token=` et chemin `scans/{uid}/…` compris.
 * L'appelant qui l'active compte lui-même ses refus, sans la référence
 * (contrôle « Dossiers des illustrations »). Désactivé par défaut.
 */
export function storageObjectPathOf(
  reference: string,
  opts: { bucketName?: string; allowEmulator?: boolean; silent?: boolean } = {},
): string | null {
  if (typeof reference !== "string" || reference.length === 0) return null;
  const { bucketName, allowEmulator = false, silent = false } = opts;

  if (reference.startsWith("gs://")) {
    const rest = reference.substring("gs://".length);
    const slash = rest.indexOf("/");
    if (slash <= 0) return null;
    const bucket = rest.substring(0, slash);
    if (bucketName && bucket !== bucketName) return null;
    return rest.substring(slash + 1);
  }

  if (/^[a-z][a-z0-9+.-]*:/i.test(reference)) {
    let url: URL;
    try {
      url = new URL(reference);
    } catch (err) {
      // Une URL illisible n'est pas une erreur du serveur : c'est un refus,
      // tracé. `console.warn` plutôt que `logWarn` : ce module reste pur et
      // testable sans Cloud Logging, et la sortie console d'une fonction est
      // collectée par Cloud Logging.
      if (!silent) warnRefused("URL illisible", reference, err);
      return null;
    }
    const isProd = url.protocol === "https:" && url.hostname === DOWNLOAD_HOST;
    const isEmulator =
      allowEmulator &&
      (url.protocol === "http:" || url.protocol === "https:") &&
      EMULATOR_HOSTS.has(url.hostname);
    if (!isProd && !isEmulator) return null;
    const match = url.pathname.match(/^\/v0\/b\/([^/]+)\/o\/([^/]+)$/);
    if (!match) return null;
    if (bucketName && decodeSafe(match[1], silent) !== bucketName) return null;
    return decodeSafe(match[2], silent);
  }

  return reference;
}

function decodeSafe(value: string, silent = false): string | null {
  try {
    return decodeURIComponent(value);
  } catch (err) {
    // Encodage invalide (`%E0%A4%A`) : refusé, comme toute référence illisible.
    // `silent` : l'appelant compte le refus lui-même, sans la référence.
    if (!silent) warnRefused("encodage invalide", value, err);
    return null;
  }
}

/** Trace un refus de lecture dû à une référence illisible. */
function warnRefused(cause: string, reference: string, err: unknown): void {
  console.warn(
    JSON.stringify({
      severity: "WARNING",
      message: `storagePath : référence refusée (${cause})`,
      reference: reference.slice(0, 300),
      errorDescription: err instanceof Error ? err.message : String(err),
    }),
  );
}

/**
 * Un chemin d'objet bien formé : pas de segment vide, `.` ou `..`, pas de
 * barre oblique inverse, pas de caractère de contrôle, pas de `/` en tête.
 *
 * GCS ne résout pas `..` — un objet peut littéralement s'appeler
 * `scans/uid/../x`. Le refuser évite qu'une comparaison de préfixe et un
 * outil qui, lui, résout le chemin ne lisent pas le même fichier.
 */
export function isWellFormedObjectPath(path: string): boolean {
  if (path.length === 0 || path.length > 1024) return false;
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f\\]/.test(path)) return false;
  const segments = path.split("/");
  return segments.every((s) => s.length > 0 && s !== "." && s !== "..");
}

/**
 * Le chemin d'objet si la référence est bien formée et commence par l'un des
 * préfixes admis ; `null` sinon. Un préfixe se termine par `/` : `scans/ab/`
 * n'admet pas `scans/abc/…`.
 */
export function allowedStoragePath(
  reference: string,
  allowedPrefixes: readonly string[],
  opts: { bucketName?: string; allowEmulator?: boolean } = {},
): string | null {
  const path = storageObjectPathOf(reference, opts);
  if (path == null || !isWellFormedObjectPath(path)) return null;
  const ok = allowedPrefixes.some(
    (prefix) =>
      prefix.endsWith("/") &&
      isWellFormedObjectPath(prefix.slice(0, -1)) &&
      path.startsWith(prefix) &&
      path.length > prefix.length,
  );
  return ok ? path : null;
}

/** Variante qui lève `StoragePathRefusedError`. */
export function resolveAllowedStoragePath(
  reference: string,
  allowedPrefixes: readonly string[],
  opts: { bucketName?: string; allowEmulator?: boolean } = {},
): string {
  const path = allowedStoragePath(reference, allowedPrefixes, opts);
  if (path == null) {
    throw new StoragePathRefusedError(
      typeof reference === "string" ? reference.slice(0, 300) : "",
      "Fichier source hors des dossiers autorisés pour ce traitement.",
    );
  }
  return path;
}

/** L'émulateur Storage tourne : ses URL `http://localhost:9199/…` sont admises. */
export function storageEmulatorActive(): boolean {
  return (
    process.env.FUNCTIONS_EMULATOR === "true" || Boolean(process.env.FIREBASE_STORAGE_EMULATOR_HOST)
  );
}
