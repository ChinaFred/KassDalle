/**
 * Lecture des rapports de violation CSP envoyés par les navigateurs.
 *
 * Deux formats coexistent :
 *  - `application/csp-report` (directive `report-uri`, Firefox et Safari) :
 *    un objet `{ "csp-report": { "violated-directive", "blocked-uri", … } }` ;
 *  - `application/reports+json` (directive `report-to`, Chromium) : un tableau
 *    de rapports `{ type: "csp-violation", body: { effectiveDirective,
 *    blockedURL, documentURL, … } }`.
 *
 * Le corps vient de n'importe quel navigateur, ou de n'importe qui : c'est
 * une entrée non fiable. Seuls des champs courts et réduits sont gardés.
 * Une URL se réduit à son origine (ressource bloquée) ou à son chemin
 * (document), sans requête ni fragment, qui peuvent porter un identifiant
 * ou un jeton. L'extrait de script (`script-sample`, `sample`) n'est jamais
 * repris.
 *
 * Module pur : aucun appel réseau, aucune écriture.
 */

/** Taille maximale d'un corps de rapport accepté, en octets. */
export const CSP_REPORT_MAX_BYTES = 16 * 1024;

/** Nombre maximal de violations lues dans un même corps `reports+json`. */
export const CSP_REPORT_MAX_ITEMS = 20;

/** Violations distinctes journalisées par instance et par fenêtre. */
export const CSP_LOG_PER_WINDOW = 30;

/** Durée d'une fenêtre de journalisation, en millisecondes. */
export const CSP_LOG_WINDOW_MS = 60_000;

/** Longueur maximale d'un champ texte gardé. */
const FIELD_MAX_CHARS = 200;

/** Une violation réduite aux champs journalisés. */
export interface CspViolation {
  /** Directive effectivement violée (`script-src-elem`, `connect-src`…). */
  directive: string;
  /** Origine de la ressource bloquée, ou mot-clé (`inline`, `eval`, `data`…). */
  blocked: string;
  /** Chemin du document, sans requête ni fragment. */
  documentPath: string;
  /** Fichier source de la violation, réduit à l'origine et au chemin. */
  sourceFile: string | null;
  line: number | null;
  column: number | null;
  /** `enforce` ou `report`. */
  disposition: string | null;
}

/** Les deux types de contenu acceptés, ou `null` pour tout autre. */
export function cspReportFormat(contentType: string | undefined): "csp-report" | "reports" | null {
  const type = (contentType ?? "").split(";")[0].trim().toLowerCase();
  if (type === "application/csp-report") return "csp-report";
  if (type === "application/reports+json") return "reports";
  // Certains navigateurs anciens envoient le format `csp-report` en JSON simple.
  if (type === "application/json") return "csp-report";
  return null;
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, FIELD_MAX_CHARS);
}

function int(value: unknown): number | null {
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return value;
  if (typeof value === "string" && /^\d{1,9}$/.test(value)) return Number(value);
  return null;
}

function parseUrl(value: string): URL | null {
  try {
    return new URL(value);
  } catch {
    // Une valeur qui n'est pas une URL est un mot-clé (`inline`, `eval`…) :
    // ce n'est pas une erreur, l'appelant la traite comme telle.
    return null;
  }
}

/**
 * La ressource bloquée, réduite : l'origine d'une URL http(s) ou ws(s), le
 * schéma seul pour `data:`, `blob:` et les autres, le mot-clé tel quel
 * (`inline`, `eval`, `wasm-eval`, `trusted-types-policy`…).
 */
export function reduceBlocked(value: unknown): string {
  const raw = text(value);
  if (!raw) return "(vide)";
  const url = parseUrl(raw);
  if (!url) return /^[a-z][a-z0-9-]{0,40}$/i.test(raw) ? raw.toLowerCase() : "(illisible)";
  if (["http:", "https:", "ws:", "wss:"].includes(url.protocol)) return url.origin;
  return url.protocol.replace(/:$/, "");
}

/** Le chemin d'un document, sans origine, requête ni fragment. */
export function reduceDocument(value: unknown): string {
  const raw = text(value);
  if (!raw) return "(vide)";
  const url = parseUrl(raw);
  if (!url) return "(illisible)";
  return url.pathname.slice(0, FIELD_MAX_CHARS);
}

/** Un fichier source réduit à l'origine et au chemin, ou `null`. */
export function reduceSource(value: unknown): string | null {
  const raw = text(value);
  if (!raw) return null;
  const url = parseUrl(raw);
  if (!url || !["http:", "https:"].includes(url.protocol)) return null;
  return `${url.origin}${url.pathname}`.slice(0, FIELD_MAX_CHARS);
}

/** La directive, réduite à son nom (le reste de la politique n'est pas repris). */
function reduceDirective(value: unknown): string | null {
  const raw = text(value);
  if (!raw) return null;
  const name = raw.split(/\s+/)[0].toLowerCase();
  return /^[a-z-]{1,40}$/.test(name) ? name : null;
}

function fromLegacy(report: Record<string, unknown>): CspViolation | null {
  const directive =
    reduceDirective(report["effective-directive"]) ?? reduceDirective(report["violated-directive"]);
  if (!directive) return null;
  return {
    directive,
    blocked: reduceBlocked(report["blocked-uri"]),
    documentPath: reduceDocument(report["document-uri"]),
    sourceFile: reduceSource(report["source-file"]),
    line: int(report["line-number"]),
    column: int(report["column-number"]),
    disposition: text(report.disposition),
  };
}

function fromReportingApi(item: unknown): CspViolation | null {
  if (!item || typeof item !== "object") return null;
  const report = item as Record<string, unknown>;
  if (report.type !== "csp-violation") return null;
  const body = report.body;
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const directive = reduceDirective(b.effectiveDirective);
  if (!directive) return null;
  return {
    directive,
    blocked: reduceBlocked(b.blockedURL),
    documentPath: reduceDocument(b.documentURL ?? report.url),
    sourceFile: reduceSource(b.sourceFile),
    line: int(b.lineNumber),
    column: int(b.columnNumber),
    disposition: text(b.disposition),
  };
}

/**
 * Les violations lues dans un corps, au plus [CSP_REPORT_MAX_ITEMS].
 *
 * Rend `null` quand le corps n'est pas du JSON lisible dans le format
 * annoncé ; un tableau vide quand le JSON est lisible mais ne porte aucune
 * violation CSP (autres types de rapport de la Reporting API).
 */
export function parseCspReports(
  format: "csp-report" | "reports",
  raw: string,
): CspViolation[] | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // Corps illisible : l'appelant le compte et le journalise.
    return null;
  }
  if (format === "csp-report") {
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const inner = (parsed as Record<string, unknown>)["csp-report"];
    if (!inner || typeof inner !== "object") return null;
    const violation = fromLegacy(inner as Record<string, unknown>);
    return violation ? [violation] : [];
  }
  if (!Array.isArray(parsed)) return null;
  const violations: CspViolation[] = [];
  for (const item of parsed.slice(0, CSP_REPORT_MAX_ITEMS)) {
    const violation = fromReportingApi(item);
    if (violation) violations.push(violation);
  }
  return violations;
}

/** Clé de regroupement : une même violation n'est journalisée qu'une fois par fenêtre. */
export function violationKey(v: CspViolation): string {
  return [v.directive, v.blocked, v.documentPath, v.sourceFile ?? "", v.line ?? ""].join("|");
}

/**
 * Plafond de journalisation par instance.
 *
 * Dans une fenêtre de [CSP_LOG_WINDOW_MS], une violation déjà vue n'est pas
 * rejournalisée, et au plus [CSP_LOG_PER_WINDOW] violations distinctes le
 * sont. Le reste est compté, avec les corps refusés : le premier passage de
 * la fenêtre suivante rend ces comptes, que l'appelant journalise en une ligne. Une page qui rapporte la
 * même violation à chaque chargement, ou un envoi massif, écrit donc au plus
 * une trentaine de lignes par minute et par instance.
 */
export class CspLogBudget {
  private windowStart: number | null = null;
  private seen = new Set<string>();
  private dropped = 0;
  private refused = 0;

  constructor(
    private readonly perWindow = CSP_LOG_PER_WINDOW,
    private readonly windowMs = CSP_LOG_WINDOW_MS,
  ) {}

  /**
   * Ouvre une nouvelle fenêtre si la précédente est échue, et rend ce qu'elle
   * a écarté : violations non journalisées et corps refusés. `null` quand la
   * fenêtre court encore ou que rien n'a été écarté.
   */
  roll(now: number): { dropped: number; refused: number } | null {
    if (this.windowStart !== null && now - this.windowStart < this.windowMs) return null;
    const result = { dropped: this.dropped, refused: this.refused };
    this.windowStart = now;
    this.seen = new Set();
    this.dropped = 0;
    this.refused = 0;
    return result.dropped > 0 || result.refused > 0 ? result : null;
  }

  /** Vrai si la violation doit être journalisée ; sinon elle est comptée. */
  admit(key: string): boolean {
    if (this.seen.has(key) || this.seen.size >= this.perWindow) {
      this.dropped++;
      return false;
    }
    this.seen.add(key);
    return true;
  }

  /** Compte un corps refusé (trop gros, format inconnu, JSON illisible). */
  refuse(): void {
    this.refused++;
  }
}
