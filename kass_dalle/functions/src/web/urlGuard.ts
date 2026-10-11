/**
 * Adresse d'une page web à importer : la lire, la normaliser, refuser ce qui
 * n'est pas public.
 *
 * Le serveur va chercher la page lui-même. Une adresse fournie par un client
 * peut viser autre chose qu'un site public : `localhost`, le serveur de
 * métadonnées de Google Cloud (`169.254.169.254`, `metadata.google.internal`),
 * une adresse privée. Chaque étape le vérifie :
 *
 *  1. la forme de l'adresse (`parseImportUrl`) — schéma, longueur, identifiants,
 *     port, nom d'hôte ;
 *  2. la résolution DNS (`assertPublicHost`) — toutes les adresses rendues
 *     doivent être publiques ;
 *  3. la connexion elle-même (`guardedLookup`, dans `safeFetch.ts`) — l'adresse
 *     réellement utilisée par le socket est revérifiée, pour qu'un DNS qui
 *     répond « public » puis « privé » ne passe pas entre les deux.
 *
 * Les fonctions de classement sont pures et testées par
 * `tests/urlGuard.test.ts`.
 */

import { isIP } from "node:net";
import { lookup } from "node:dns/promises";

/** Longueur maximale d'une adresse acceptée. */
export const URL_MAX_CHARS = 2048;

/** Ports admis : ceux d'un site web. Un autre port sert à sonder un réseau. */
const ALLOWED_PORTS = new Set(["", "80", "443", "8080", "8443"]);

/** Noms d'hôte refusés tels quels, en plus des suffixes ci-dessous. */
const BLOCKED_HOSTNAMES = new Set(["localhost", "metadata.google.internal", "metadata"]);

/** Suffixes de domaines internes ou réservés. */
const BLOCKED_SUFFIXES = [".localhost", ".internal", ".local", ".localdomain", ".home.arpa"];

/** Paramètres de suivi retirés avant comparaison : ils ne changent pas la page. */
const TRACKING_PARAMS = new Set([
  "fbclid",
  "gclid",
  "dclid",
  "msclkid",
  "mc_cid",
  "mc_eid",
  "igshid",
  "_ga",
  "ref",
  "ref_src",
]);

/** Pourquoi une adresse est refusée. */
export type UrlRefusal =
  | "empty"
  | "too_long"
  | "malformed"
  | "scheme"
  | "credentials"
  | "port"
  | "hostname"
  | "private_address"
  | "dns";

/** Adresse refusée. `malformed`, `empty`, `too_long`, `scheme` : ce n'est pas un lien web. */
export class UrlRefusedError extends Error {
  constructor(
    readonly reason: UrlRefusal,
    detail: string,
  ) {
    super(detail);
    this.name = "UrlRefusedError";
  }

  /** Vrai quand l'adresse n'est pas un lien web, faux quand elle vise un hôte refusé. */
  get notAWebLink(): boolean {
    return (
      this.reason === "empty" ||
      this.reason === "too_long" ||
      this.reason === "malformed" ||
      this.reason === "scheme"
    );
  }
}

/** Adresse acceptée par `parseImportUrl`. */
export interface ParsedImportUrl {
  /** L'adresse telle qu'on la stocke et qu'on compare : voir `normalizeUrl`. */
  normalized: string;
  /** Le nom d'hôte en minuscules, sans `www.` — ce qu'on affiche (« marmiton.org »). */
  site: string;
  url: URL;
}

/**
 * Lit une adresse saisie par l'utilisateur, ou lève `UrlRefusedError`.
 *
 * Ne fait aucun appel réseau : la résolution DNS est l'affaire de
 * `assertPublicHost`.
 */
export function parseImportUrl(raw: unknown): ParsedImportUrl {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new UrlRefusedError("empty", "Adresse absente.");
  }
  const text = raw.trim();
  if (text.length > URL_MAX_CHARS) {
    throw new UrlRefusedError("too_long", `Adresse de plus de ${URL_MAX_CHARS} caractères.`);
  }
  if (!URL.canParse(text)) {
    throw new UrlRefusedError("malformed", "Adresse illisible.");
  }
  const url = new URL(text);
  assertAcceptableUrl(url);
  return { normalized: normalizeUrl(url), site: siteName(url.hostname), url };
}

/**
 * Contrôle de forme d'une URL déjà lue : celle de l'utilisateur, et chaque
 * cible de redirection. Lève `UrlRefusedError`.
 */
export function assertAcceptableUrl(url: URL): void {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new UrlRefusedError("scheme", `Schéma refusé : ${url.protocol}`);
  }
  if (url.username || url.password) {
    throw new UrlRefusedError("credentials", "Adresse avec identifiants refusée.");
  }
  if (!ALLOWED_PORTS.has(url.port)) {
    throw new UrlRefusedError("port", `Port refusé : ${url.port}`);
  }
  const host = hostOf(url);
  if (host.length === 0) throw new UrlRefusedError("hostname", "Nom d'hôte absent.");
  const family = isIP(host);
  if (family !== 0) {
    if (!isPublicAddress(host)) {
      throw new UrlRefusedError("private_address", `Adresse non publique : ${host}`);
    }
    return;
  }
  if (isBlockedHostname(host)) {
    throw new UrlRefusedError("hostname", `Nom d'hôte refusé : ${host}`);
  }
}

/** Nom d'hôte sans crochets IPv6 ni point final, en minuscules. */
export function hostOf(url: URL): string {
  let host = url.hostname.toLowerCase();
  if (host.startsWith("[") && host.endsWith("]")) host = host.slice(1, -1);
  if (host.endsWith(".")) host = host.slice(0, -1);
  return host;
}

/**
 * Un nom d'hôte interne : `localhost`, `metadata.google.internal`, un suffixe
 * réservé, ou un nom sans point (« metadata », « intranet »), que seul un
 * résolveur interne sait servir.
 */
export function isBlockedHostname(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (BLOCKED_HOSTNAMES.has(h)) return true;
  if (BLOCKED_SUFFIXES.some((s) => h.endsWith(s))) return true;
  return !h.includes(".");
}

/** « www.marmiton.org » → « marmiton.org ». */
export function siteName(hostname: string): string {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  return host.startsWith("www.") ? host.slice(4) : host;
}

/**
 * Forme stockée et comparée d'une adresse.
 *
 * Retire ce qui ne change pas la page : le fragment, les paramètres de suivi
 * (`utm_*`, `fbclid`…), le port par défaut, la barre oblique finale. Trie les
 * paramètres restants. Le schéma et `www.` restent : ils font partie de
 * l'adresse qu'on rouvre.
 */
export function normalizeUrl(input: URL): string {
  const url = new URL(input.toString());
  url.hash = "";
  url.hostname = url.hostname.toLowerCase();
  const kept = [...url.searchParams.entries()]
    .filter(([key]) => {
      const k = key.toLowerCase();
      return !k.startsWith("utm_") && !TRACKING_PARAMS.has(k);
    })
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  url.search = "";
  for (const [k, v] of kept) url.searchParams.append(k, v);
  let out = url.toString();
  if (url.pathname.length > 1 && out.endsWith("/") && url.search.length === 0) {
    out = out.slice(0, -1);
  }
  return out;
}

// ── Classement des adresses IP ───────────────────────────────────────────────

/** Plages IPv4 non publiques : [adresse de réseau, longueur du préfixe]. */
const BLOCKED_V4: ReadonlyArray<[string, number]> = [
  ["0.0.0.0", 8], // « ce réseau »
  ["10.0.0.0", 8], // privé
  ["100.64.0.0", 10], // CGNAT
  ["127.0.0.0", 8], // boucle locale
  ["169.254.0.0", 16], // lien local, dont 169.254.169.254 (métadonnées)
  ["172.16.0.0", 12], // privé
  ["192.0.0.0", 24], // affectations IETF
  ["192.0.2.0", 24], // documentation
  ["192.88.99.0", 24], // relais 6to4
  ["192.168.0.0", 16], // privé
  ["198.18.0.0", 15], // bancs d'essai
  ["198.51.100.0", 24], // documentation
  ["203.0.113.0", 24], // documentation
  ["224.0.0.0", 4], // multidiffusion
  ["240.0.0.0", 4], // réservé, dont 255.255.255.255
];

function v4ToInt(address: string): number | null {
  const parts = address.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    const n = Number(p);
    if (n > 255) return null;
    value = value * 256 + n;
  }
  return value;
}

function isPublicV4(address: string): boolean {
  const ip = v4ToInt(address);
  if (ip == null) return false;
  for (const [net, bits] of BLOCKED_V4) {
    const base = v4ToInt(net)!;
    const size = 2 ** (32 - bits);
    if (ip >= base && ip < base + size) return false;
  }
  return true;
}

/** Les huit groupes de 16 bits d'une adresse IPv6, ou `null` si illisible. */
export function expandV6(address: string): number[] | null {
  let text = address.toLowerCase();
  const zone = text.indexOf("%");
  if (zone >= 0) text = text.slice(0, zone);
  // Fin en notation IPv4 (« ::ffff:10.0.0.1 ») : convertie en deux groupes.
  const lastColon = text.lastIndexOf(":");
  const tail = text.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = v4ToInt(tail);
    if (v4 == null) return null;
    text = `${text.slice(0, lastColon + 1)}${Math.floor(v4 / 65536).toString(16)}:${(v4 % 65536).toString(16)}`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const parse = (s: string) => (s.length === 0 ? [] : s.split(":"));
  const head = parse(halves[0]);
  const rest = halves.length === 2 ? parse(halves[1]) : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 && head.length !== 8) return null;
  if (halves.length === 2 && missing < 1) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...rest];
  if (groups.length !== 8) return null;
  const out: number[] = [];
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    out.push(parseInt(g, 16));
  }
  return out;
}

function isPublicV6(address: string): boolean {
  const g = expandV6(address);
  if (!g) return false;
  const allZero = (from: number, to: number) => g.slice(from, to).every((x) => x === 0);
  // :: et ::1
  if (allZero(0, 7) && (g[7] === 0 || g[7] === 1)) return false;
  // ::ffff:a.b.c.d (IPv4 mappée) et ::a.b.c.d (compatible, obsolète)
  if (allZero(0, 5) && (g[5] === 0xffff || g[5] === 0)) {
    return isPublicV4(groupsToV4(g[6], g[7]));
  }
  // ::ffff:0:a.b.c.d (SIIT, ::ffff:0:0:0/96) : traduction d'adresse, refusée.
  if (allZero(0, 4) && g[4] === 0xffff && g[5] === 0) return false;
  // 64:ff9b:1::/48 (NAT64 local) : réseau privé de traduction, refusé.
  if (g[0] === 0x64 && g[1] === 0xff9b && g[2] === 1) return false;
  // 2001:0::/32 (Teredo) : encapsule une adresse IPv4 arbitraire, refusée.
  if (g[0] === 0x2001 && g[1] === 0) return false;
  // 64:ff9b::/96 (NAT64) : l'adresse IPv4 embarquée décide.
  if (g[0] === 0x64 && g[1] === 0xff9b && allZero(2, 6)) {
    return isPublicV4(groupsToV4(g[6], g[7]));
  }
  if ((g[0] & 0xfe00) === 0xfc00) return false; // fc00::/7, ULA
  if ((g[0] & 0xffc0) === 0xfe80) return false; // fe80::/10, lien local
  if ((g[0] & 0xffc0) === 0xfec0) return false; // fec0::/10, site local (obsolète)
  if ((g[0] & 0xff00) === 0xff00) return false; // ff00::/8, multidiffusion
  if (g[0] === 0x2001 && g[1] === 0x0db8) return false; // documentation
  if (g[0] === 0x0100 && allZero(1, 4)) return false; // 100::/64, rebut
  if (g[0] === 0x2002) return false; // 6to4 : peut encapsuler une adresse privée
  return true;
}

function groupsToV4(hi: number, lo: number): string {
  return [hi >> 8, hi & 0xff, lo >> 8, lo & 0xff].join(".");
}

/**
 * Vrai si l'adresse IP est routable sur Internet public. Faux pour toute
 * adresse illisible : sans preuve, on ne se connecte pas.
 */
export function isPublicAddress(address: string): boolean {
  const family = isIP(address.split("%")[0]);
  if (family === 4) return isPublicV4(address);
  if (family === 6) return isPublicV6(address);
  return false;
}

/** Résolveur injectable, pour les tests. */
export type Resolver = (host: string) => Promise<Array<{ address: string; family: number }>>;

/** Résolution système, toutes familles. */
export const systemResolver: Resolver = (host) => lookup(host, { all: true, verbatim: true });

/**
 * Résout le nom d'hôte et refuse si **une** des adresses n'est pas publique.
 *
 * Une seule adresse privée suffit : le socket peut choisir n'importe laquelle.
 * Une résolution en échec lève `UrlRefusedError("dns")`.
 */
export async function assertPublicHost(
  url: URL,
  resolve: Resolver = systemResolver,
): Promise<void> {
  const host = hostOf(url);
  if (isIP(host) !== 0) {
    if (!isPublicAddress(host)) {
      throw new UrlRefusedError("private_address", `Adresse non publique : ${host}`);
    }
    return;
  }
  let addresses: Array<{ address: string; family: number }>;
  try {
    addresses = await resolve(host);
  } catch (err) {
    // Pas un incident à journaliser ici : l'appelant journalise le refus avec
    // son contexte (utilisateur, job). Le détail part dans le message.
    throw new UrlRefusedError(
      "dns",
      `Nom d'hôte introuvable : ${host} (${err instanceof Error ? err.message : String(err)})`,
    );
  }
  if (addresses.length === 0) {
    throw new UrlRefusedError("dns", `Nom d'hôte sans adresse : ${host}`);
  }
  const blocked = addresses.find((a) => !isPublicAddress(a.address));
  if (blocked) {
    throw new UrlRefusedError(
      "private_address",
      `${host} résout vers une adresse non publique (${blocked.address}).`,
    );
  }
}
