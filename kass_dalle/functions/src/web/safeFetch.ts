/**
 * Récupération d'une ressource web publique, protégée contre le SSRF.
 *
 * Écrit sur `node:http` / `node:https` plutôt que sur `fetch`. `fetch` résout
 * le nom d'hôte lui-même, après notre contrôle : un DNS qui répond une adresse
 * publique au contrôle puis `169.254.169.254` à la connexion passerait entre
 * les deux. Ici, la résolution utilisée par le socket EST le contrôle
 * (`guardedLookup`) : aucune adresse non publique n'atteint `connect()`.
 * Aucune dépendance de plus : ce sont les modules natifs de Node.
 *
 * Bornes : trois redirections au plus, chacune revérifiée ; un délai total ;
 * une taille maximale comptée après décompression ; un type de contenu exigé.
 */

import { request as httpRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";
import { lookup as dnsLookup, type LookupAddress } from "node:dns";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";
import type { Readable } from "node:stream";

import { UrlRefusedError, assertAcceptableUrl, isPublicAddress } from "./urlGuard";

/** User-Agent annoncé aux sites : il dit qui lit la page, et pour quoi. */
export const KASSDALLE_USER_AGENT =
  "KassDalle-RecipeImport/1.0 (+https://kassdale-6d948.web.app; import d'une recette par un membre)";

/** Nombre maximal de redirections suivies. */
export const MAX_REDIRECTS = 3;

/** Pourquoi une récupération a échoué. */
export type FetchFailure =
  | "blocked" // 401, 402, 403, 429, 451 : le site refuse
  | "not_found" // 404, 410
  | "timeout" // délai dépassé
  | "network" // DNS, connexion, 5xx
  | "refused" // adresse non publique, trop de redirections
  | "not_html" // type de contenu inattendu
  | "too_large"; // au-delà de la taille admise

export class WebFetchError extends Error {
  constructor(
    readonly failure: FetchFailure,
    detail: string,
    readonly httpStatus: number | null = null,
  ) {
    super(detail);
    this.name = "WebFetchError";
  }
}

export interface FetchedResource {
  /** Adresse finale, après redirections. */
  finalUrl: string;
  status: number;
  /** Type de contenu, en minuscules, sans paramètres. */
  contentType: string;
  /** `charset` annoncé par l'en-tête, s'il y en a un. */
  charset: string | null;
  body: Buffer;
}

export interface FetchOptions {
  /** Types de contenu admis : un type exact (`text/html`) ou un préfixe (`image/`). */
  accept: string[];
  maxBytes: number;
  timeoutMs: number;
  /** En-tête `Accept` envoyé. */
  acceptHeader: string;
}

/** Classe un statut HTTP final en échec, ou `null` s'il est exploitable. */
export function failureForStatus(status: number): FetchFailure | null {
  if (status >= 200 && status < 300) return null;
  if ([401, 402, 403, 429, 451, 999].includes(status)) return "blocked";
  if (status === 404 || status === 410) return "not_found";
  return "network";
}

/** Vrai si le type reçu fait partie des types admis. */
export function contentTypeAccepted(contentType: string, accept: string[]): boolean {
  return accept.some((a) => (a.endsWith("/") ? contentType.startsWith(a) : contentType === a));
}

/** Lit `type/sous-type; charset=…`. */
export function parseContentType(header: string | undefined): {
  type: string;
  charset: string | null;
} {
  if (!header) return { type: "", charset: null };
  const [type, ...params] = header.split(";");
  let charset: string | null = null;
  for (const p of params) {
    const [k, v] = p.split("=");
    if (k?.trim().toLowerCase() === "charset" && v) {
      charset = v
        .trim()
        .replace(/^["']|["']$/g, "")
        .toLowerCase();
    }
  }
  return { type: type.trim().toLowerCase(), charset };
}

/**
 * La résolution DNS du socket, filtrée.
 *
 * Node l'appelle au moment de la connexion. Toute adresse non publique fait
 * échouer la connexion avant le moindre octet envoyé. Avec `all: true` (cas de
 * l'« autoSelectFamily » de Node 22), toutes les adresses sont vérifiées.
 */
export function guardedLookup(
  hostname: string,
  options: { all?: boolean; family?: number | string },
  callback: (
    err: NodeJS.ErrnoException | null,
    address: string | LookupAddress[],
    family?: number,
  ) => void,
): void {
  dnsLookup(hostname, { all: true, verbatim: true }, (err, addresses) => {
    if (err) {
      callback(err, "", 0);
      return;
    }
    const list = addresses as LookupAddress[];
    const blocked = list.find((a) => !isPublicAddress(a.address));
    if (list.length === 0 || blocked) {
      const refusal = new Error(
        `Connexion refusée : ${hostname} résout vers ${blocked?.address ?? "aucune adresse"}`,
      ) as NodeJS.ErrnoException;
      refusal.code = "EKASSDALLE_PRIVATE_ADDRESS";
      callback(refusal, "", 0);
      return;
    }
    if (options.all) {
      callback(null, list);
      return;
    }
    callback(null, list[0].address, list[0].family);
  });
}

/** Une requête, une réponse : sans suivre les redirections. */
function requestOnce(
  url: URL,
  opts: FetchOptions,
  signal: AbortSignal,
): Promise<{ res: IncomingMessage }> {
  return new Promise((resolve, reject) => {
    const request = url.protocol === "https:" ? httpsRequest : httpRequest;
    const req = request(
      url,
      {
        method: "GET",
        lookup: guardedLookup as unknown as typeof dnsLookup,
        signal,
        headers: {
          "User-Agent": KASSDALLE_USER_AGENT,
          Accept: opts.acceptHeader,
          "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.6",
          "Accept-Encoding": "gzip, deflate, br",
        },
      },
      (res) => resolve({ res }),
    );
    req.on("error", reject);
    req.end();
  });
}

/**
 * Décompresse le corps selon `Content-Encoding`.
 *
 * `res.pipe(décompresseur)` ne propage pas la destruction de la réponse : un
 * délai dépassé détruisait `res`, et la lecture du flux décompressé attendait
 * une fin qui ne venait jamais — jusqu'aux 540 s de la tâche. Ici, toute
 * erreur ou fermeture prématurée de la réponse détruit aussi le décompresseur,
 * et sa lecture échoue aussitôt.
 */
export function decodedStream(res: Readable & { complete?: boolean }, encoding: string): Readable {
  const enc = encoding.toLowerCase();
  const decoder =
    enc === "gzip" || enc === "x-gzip"
      ? createGunzip()
      : enc === "deflate"
        ? createInflate()
        : enc === "br"
          ? createBrotliDecompress()
          : null;
  if (!decoder) return res;
  const fail = (err?: Error) => {
    if (!decoder.destroyed) {
      decoder.destroy(err ?? new Error("Réponse interrompue avant sa fin."));
    }
  };
  res.on("error", fail);
  res.on("close", () => {
    if (res.complete === false) fail();
  });
  res.pipe(decoder);
  return decoder;
}

/** Lit le corps en s'arrêtant à `maxBytes`, comptés après décompression. */
async function readBounded(res: IncomingMessage, maxBytes: number): Promise<Buffer> {
  const declared = Number(res.headers["content-length"] ?? NaN);
  if (Number.isFinite(declared) && declared > maxBytes) {
    res.destroy();
    throw new WebFetchError("too_large", `Contenu annoncé de ${declared} octets.`);
  }
  const stream = decodedStream(res, String(res.headers["content-encoding"] ?? ""));
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of stream) {
    const buf = chunk as Buffer;
    total += buf.length;
    if (total > maxBytes) {
      res.destroy();
      throw new WebFetchError("too_large", `Contenu au-delà de ${maxBytes} octets.`);
    }
    chunks.push(buf);
  }
  return Buffer.concat(chunks);
}

/** Traduit une erreur réseau brute en `WebFetchError`. */
export function classifyNetworkError(err: unknown, timedOut: boolean): WebFetchError {
  if (err instanceof WebFetchError) return err;
  if (err instanceof UrlRefusedError) return new WebFetchError("refused", err.message);
  const code = (err as NodeJS.ErrnoException | null)?.code;
  const message = err instanceof Error ? err.message : String(err);
  if (code === "EKASSDALLE_PRIVATE_ADDRESS") return new WebFetchError("refused", message);
  if (timedOut || code === "ABORT_ERR" || (err as Error | null)?.name === "AbortError") {
    return new WebFetchError("timeout", "La page n'a pas répondu à temps.");
  }
  return new WebFetchError("network", `${code ?? "erreur"} : ${message}`);
}

/**
 * Récupère une ressource publique en suivant au plus `MAX_REDIRECTS`
 * redirections, chacune revérifiée. Lève `WebFetchError`.
 */
export async function fetchPublicResource(
  startUrl: URL,
  opts: FetchOptions,
): Promise<FetchedResource> {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, opts.timeoutMs);
  try {
    let url = startUrl;
    for (let hop = 0; ; hop++) {
      assertAcceptableUrl(url);
      const { res } = await requestOnce(url, opts, controller.signal);
      const status = res.statusCode ?? 0;
      if (status >= 300 && status < 400 && res.headers.location) {
        res.resume();
        if (hop >= MAX_REDIRECTS) {
          throw new WebFetchError("refused", `Plus de ${MAX_REDIRECTS} redirections.`, status);
        }
        const next = URL.canParse(res.headers.location, url.toString())
          ? new URL(res.headers.location, url)
          : null;
        if (!next) throw new WebFetchError("refused", "Redirection illisible.", status);
        url = next;
        continue;
      }
      const failure = failureForStatus(status);
      if (failure) {
        res.resume();
        throw new WebFetchError(failure, `Réponse HTTP ${status}.`, status);
      }
      const { type, charset } = parseContentType(res.headers["content-type"]);
      if (!contentTypeAccepted(type, opts.accept)) {
        res.resume();
        throw new WebFetchError(
          "not_html",
          `Type de contenu refusé : ${type || "absent"}.`,
          status,
        );
      }
      const body = await readBounded(res, opts.maxBytes);
      return { finalUrl: url.toString(), status, contentType: type, charset, body };
    }
  } catch (err) {
    // Rien n'est avalé : l'erreur est classée et relancée, l'appelant la
    // journalise avec son contexte.
    throw classifyNetworkError(err, timedOut);
  } finally {
    clearTimeout(timer);
  }
}

/** Page HTML : 3 Mo, 10 s. */
export const PAGE_FETCH_OPTIONS: FetchOptions = {
  accept: ["text/html", "application/xhtml+xml"],
  maxBytes: 3 * 1024 * 1024,
  timeoutMs: 10_000,
  acceptHeader: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
};

/** Photo de la page : 8 Mo, 10 s. */
export const IMAGE_FETCH_OPTIONS: FetchOptions = {
  accept: ["image/"],
  maxBytes: 8 * 1024 * 1024,
  timeoutMs: 10_000,
  acceptHeader: "image/avif,image/webp,image/jpeg,image/png,image/*;q=0.8",
};

/** Encodages de texte reconnus. Tout autre retombe en UTF-8. */
const KNOWN_CHARSETS: Record<string, string> = {
  "utf-8": "utf-8",
  utf8: "utf-8",
  "iso-8859-1": "latin1",
  latin1: "latin1",
  "iso-8859-15": "iso-8859-15",
  "windows-1252": "windows-1252",
  cp1252: "windows-1252",
};

/**
 * Décode le HTML : `charset` de l'en-tête, sinon `<meta charset>` lu dans le
 * premier kilo-octet, sinon UTF-8.
 */
export function decodeHtml(body: Buffer, headerCharset: string | null): string {
  let charset = headerCharset;
  if (!charset) {
    const head = body.subarray(0, 2048).toString("latin1");
    const m = /<meta[^>]+charset\s*=\s*["']?([a-z0-9_-]+)/i.exec(head);
    charset = m ? m[1].toLowerCase() : null;
  }
  const label = (charset && KNOWN_CHARSETS[charset]) || "utf-8";
  return new TextDecoder(label).decode(body);
}
