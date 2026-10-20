/**
 * Cloud Function HTTPS Callable : `queryLogsFn`.
 *
 * Permet à un administrateur de requêter Cloud Logging depuis l'écran
 * d'administration Flutter, avec filtres :
 *   - severity (INFO / WARNING / ERROR / DEBUG)
 *   - correlationId, jobId, userId (labels indexés)
 *   - timeRangeMinutes (ex : 60 = dernière heure)
 *   - freeText (recherche plein-texte dans le message)
 *   - pageSize (1..200)
 *
 * Renvoie une liste de logs structurés `{ timestamp, severity, labels, payload }`
 * triés du plus récent au plus ancien.
 *
 * Sécurité :
 *   - Auth requise + rôle `admin` (cf. _auth.ts).
 *   - Pas d'accès direct à l'API Cloud Logging depuis le client.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";

import { getFirestore } from "firebase-admin/firestore";

import { REGION, LOG_NAME, MAX_CALLABLE_INSTANCES, COLL_AI_USAGE } from "../config";
import { requireAdmin } from "./_auth";
import { getUsdToEurRate } from "../ai/budget";
import { logError } from "../logging";

interface QueryLogsRequest {
  severity?: "INFO" | "WARNING" | "ERROR" | "DEBUG";
  correlationId?: string;
  /**
   * Scan de l'utilisateur — l'acte, pas le traitement.
   *
   * Filtrer sur `correlationId` ne rend qu'un des quatre traitements d'un
   * import. Ce filtre-ci les rend tous les quatre, et eux seuls.
   */
  scanId?: string;
  jobId?: string;
  userId?: string;
  /** Fenêtre de recherche en minutes (par défaut 60, max 7 jours = 10080). */
  timeRangeMinutes?: number;
  /** Recherche plein-texte dans `jsonPayload.message`. */
  freeText?: string;
  /** Taille de page (par défaut 100, max 200). */
  pageSize?: number;
  /**
   * Jeton rendu par l'appel précédent, pour continuer la même recherche.
   *
   * Sans pagination, l'écran ne montrait que les N premières entrées et rien
   * ne le disait : un import qui en produit davantage semblait s'arrêter en
   * chemin. Une liste tronquée qui ne s'annonce pas est pire qu'une liste
   * courte — on en tire des conclusions sur du vide.
   */
  pageToken?: string;
}

interface LogEntryDto {
  timestamp: string;
  severity: string;
  labels: Record<string, string>;
  payload: Record<string, unknown>;
  insertId?: string;
}

/**
 * Un appel de modèle, tel qu'il a été facturé.
 *
 * Il ne vient PAS des journaux mais de `ai_usage`, la collection que lisent
 * aussi les écrans de facturation. Chiffrer l'appel ici, depuis les jetons
 * écrits dans le journal, aurait produit un second montant calculé autrement
 * que le premier : deux écrans, deux chiffres, aucun moyen de dire lequel est
 * le bon. Il n'y a qu'une source de vérité pour un montant.
 *
 * `costUsd` vaut `null` quand la grille tarifaire était en panne au moment
 * de l'appel. L'écran affiche alors l'absence de montant, jamais zéro.
 */
interface AiCallDto {
  callId: string | null;
  correlationId: string | null;
  scanId: string | null;
  feature: string;
  provider: string;
  model: string;
  status: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  costUsd: number | null;
  timestamp: string | null;
}

/** Taille d'un lot `in` Firestore. */
const IN_CHUNK = 30;

function chunk<T>(values: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < values.length; i += size) out.push(values.slice(i, i + size));
  return out;
}

function readNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Les appels facturés qui se rattachent aux entrées de journal affichées.
 *
 * Deux clés de rapprochement, et pas une seule : `scan_id` rassemble les
 * quatre traitements d'un import — contrôle du fichier, pipeline, pages,
 * calculs d'après écriture — tandis que `correlation_id` couvre tout le
 * reste, y compris les journaux écrits avant que le scan existe.
 *
 * Une panne de lecture ne fait pas échouer l'écran : les journaux s'affichent
 * sans montant, et l'incident est écrit. Un écran de journaux vide serait une
 * perte plus grave qu'une colonne de coûts absente.
 */
async function loadAiCalls(entries: LogEntryDto[]): Promise<AiCallDto[]> {
  const scanIds = [...new Set(entries.map((e) => e.labels.scanId).filter(Boolean))] as string[];
  const correlationIds = [
    ...new Set(entries.map((e) => e.labels.correlationId).filter(Boolean)),
  ] as string[];
  if (scanIds.length === 0 && correlationIds.length === 0) return [];

  const db = getFirestore();
  const queries = [
    ...chunk(scanIds, IN_CHUNK).map((ids) =>
      db.collection(COLL_AI_USAGE).where("scan_id", "in", ids).get(),
    ),
    ...chunk(correlationIds, IN_CHUNK).map((ids) =>
      db.collection(COLL_AI_USAGE).where("correlation_id", "in", ids).get(),
    ),
  ];

  const snapshots = await Promise.all(queries);
  // Un même appel remonte par les deux chemins quand il porte les deux clés.
  // Sans cette déduplication, son coût serait compté deux fois dans le total
  // du scan — et un total faux ne se voit pas.
  const byDocId = new Map<string, AiCallDto>();
  for (const snap of snapshots) {
    for (const doc of snap.docs) {
      if (byDocId.has(doc.id)) continue;
      const d = doc.data() as Record<string, unknown>;
      const cost = d.estimated_cost_usd;
      const ts = d.timestamp as { toDate?: () => Date } | undefined;
      byDocId.set(doc.id, {
        callId: (d.call_id as string | null) ?? null,
        correlationId: (d.correlation_id as string | null) ?? null,
        scanId: (d.scan_id as string | null) ?? null,
        feature: String(d.feature ?? ""),
        provider: String(d.provider ?? ""),
        model: String(d.model ?? ""),
        status: String(d.status ?? "ok"),
        inputTokens: readNumber(d.input_tokens),
        outputTokens: readNumber(d.output_tokens) + readNumber(d.thinking_tokens),
        totalTokens: readNumber(d.total_tokens),
        costUsd: typeof cost === "number" && Number.isFinite(cost) ? cost : null,
        timestamp: ts?.toDate ? ts.toDate().toISOString() : null,
      });
    }
  }
  return [...byDocId.values()];
}

/**
 * Client Cloud Logging pour la LECTURE, chargé au premier appel.
 *
 * L'écriture des journaux a le sien, dans `logging.ts` : elle sert à toutes les
 * fonctions et doit rester immédiate. Celui-ci ne sert qu'à l'écran
 * Administration → Journaux, et l'importer au démarrage faisait payer à
 * cinquante fonctions le prix d'un écran qu'aucune n'ouvre.
 */
let loggingClient: import("@google-cloud/logging").Logging | null = null;
async function loggingApi(): Promise<import("@google-cloud/logging").Logging> {
  if (!loggingClient) {
    const { Logging } = await import("@google-cloud/logging");
    loggingClient = new Logging();
  }
  return loggingClient;
}

/** Échappe une valeur pour un filtre Cloud Logging (entoure de guillemets et échappe \"). */
function quote(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** Sérialise une valeur en JSON sûr (transforme Long/BigInt en string, supprime
 *  les fonctions/symbols, etc.). Évite l'erreur cliente
 *  `Int64 accessor not supported by dart2js` quand `@google-cloud/logging`
 *  renvoie des nombres encodés en `Long` (protobufjs). */
/**
 * Normalise en ISO-8601 le timestamp d'une entrée Cloud Logging.
 *
 * Trois formes possibles selon le chemin du SDK : chaîne ISO, `Date`, ou
 * protobuf `{seconds, nanos}` dont `seconds` est parfois un Long
 * (`{low, high, unsigned}`). Rendre la chaîne vide plutôt qu'une date fausse :
 * l'écran affiche alors la valeur brute, ce qui se remarque — là où une date à
 * l'epoch passe pour une vraie date et fait chercher au mauvais endroit.
 */
function toIsoTimestamp(value: unknown): string {
  if (typeof value === "string") return value;
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? "" : value.toISOString();
  }
  if (value && typeof value === "object") {
    const raw = (value as { seconds?: unknown }).seconds;
    let seconds: number | null = null;
    if (typeof raw === "number") {
      seconds = raw;
    } else if (typeof raw === "string") {
      const parsed = Number(raw);
      seconds = Number.isFinite(parsed) ? parsed : null;
    } else if (raw && typeof raw === "object") {
      // Long protobuf : `{low, high, unsigned}`.
      const low = Number((raw as { low?: unknown }).low ?? NaN);
      const high = Number((raw as { high?: unknown }).high ?? 0);
      if (Number.isFinite(low)) seconds = high * 2 ** 32 + (low >>> 0);
    }
    if (seconds != null && Number.isFinite(seconds) && seconds > 0) {
      return new Date(seconds * 1000).toISOString();
    }
  }
  return "";
}

function toJsonSafe(value: unknown): unknown {
  return JSON.parse(
    JSON.stringify(value, (_k, v) => {
      if (typeof v === "bigint") return v.toString();
      // protobufjs `Long` instances : { low, high, unsigned } + toString()
      if (
        v &&
        typeof v === "object" &&
        typeof (v as { low?: unknown }).low === "number" &&
        typeof (v as { high?: unknown }).high === "number" &&
        typeof (v as { unsigned?: unknown }).unsigned === "boolean" &&
        typeof (v as { toString?: unknown }).toString === "function"
      ) {
        return (v as { toString: () => string }).toString();
      }
      return v;
    }),
  );
}

/** Les sévérités que l'écran Admin › Journaux envoie (`logs_screen.dart`). */
const SEVERITIES = ["DEBUG", "INFO", "WARNING", "ERROR"] as const;

/**
 * La clause de sévérité du filtre Cloud Logging, ou `null` sans filtre.
 * Pure, testée.
 *
 * Seuil, pas égalité. Une sélection « INFO » qui excluait les ERROR était
 * un piège : on croyait tout voir en filtrant le bruit, et on masquait
 * les lignes qu'on cherchait. `DEBUG` reste exact — c'est le seul cas où
 * l'on veut l'instrumentation seule.
 *
 * Liste blanche : la valeur était recopiée telle quelle dans le filtre, si
 * bien qu'un `"INFO OR logName:…"` y ajoutait une clause de son choix (audit
 * #151, ticket #163). Toute valeur hors liste lève `invalid-argument`.
 * Absente, nulle ou vide : aucun filtre, comme avant.
 */
export function severityClause(severity: unknown): string | null {
  if (severity === undefined || severity === null || severity === "") return null;
  if (typeof severity !== "string" || !(SEVERITIES as readonly string[]).includes(severity)) {
    throw new HttpsError(
      "invalid-argument",
      `Sévérité inconnue : attendu ${SEVERITIES.join(", ")}.`,
    );
  }
  return severity === "DEBUG" ? "severity=DEBUG" : `severity>=${severity}`;
}

export const queryLogsFn = onCall<QueryLogsRequest>(
  {
    region: REGION,
    timeoutSeconds: 60,
    memory: "256MiB",
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    await requireAdmin(req, "consultation_journaux");

    const data = req.data ?? {};
    const projectId = process.env.GCLOUD_PROJECT ?? process.env.GCP_PROJECT;
    if (!projectId) {
      throw new HttpsError("internal", "Project ID indisponible.");
    }

    // Borne les paramètres.
    const pageSize = Math.min(Math.max(data.pageSize ?? 100, 1), 200);
    const minutes = Math.min(Math.max(data.timeRangeMinutes ?? 60, 1), 10080);
    const sinceIso = new Date(Date.now() - minutes * 60_000).toISOString();

    // Construit le filtre Cloud Logging.
    const filters: string[] = [
      `logName=${quote(`projects/${projectId}/logs/${LOG_NAME}`)}`,
      `timestamp >= ${quote(sinceIso)}`,
    ];
    const severity = severityClause(data.severity);
    if (severity) filters.push(severity);
    if (data.correlationId) {
      filters.push(`labels.correlationId=${quote(data.correlationId)}`);
    }
    if (data.scanId) {
      filters.push(`labels.scanId=${quote(data.scanId)}`);
    }
    if (data.jobId) {
      filters.push(`labels.jobId=${quote(data.jobId)}`);
    }
    if (data.userId) {
      filters.push(`labels.userId=${quote(data.userId)}`);
    }
    if (data.freeText) {
      filters.push(`jsonPayload.message:${quote(data.freeText)}`);
    }

    const filter = filters.join(" AND ");

    try {
      // `autoPaginate: false` est indispensable : par défaut le client suit les
      // pages tout seul jusqu'à épuisement, ce qui ignore `pageSize` et peut
      // ramener des dizaines de milliers d'entrées dans une callable de 60 s.
      const [entries, nextQuery] = await (
        await loggingApi()
      ).getEntries({
        filter,
        pageSize,
        orderBy: "timestamp desc",
        autoPaginate: false,
        ...(data.pageToken ? { pageToken: data.pageToken } : {}),
      });
      const nextPageToken =
        (nextQuery as { pageToken?: string } | null | undefined)?.pageToken ?? null;

      const result: LogEntryDto[] = entries.map((e) => {
        const meta = (e.metadata ?? {}) as {
          timestamp?: string | Date | { seconds?: unknown; nanos?: number };
          severity?: string | number;
          labels?: Record<string, string>;
          insertId?: string;
        };
        // Le SDK Cloud Logging rend le timestamp sous trois formes selon le
        // chemin : une chaîne ISO, un objet `Date`, ou un protobuf
        // `{seconds, nanos}` dont `seconds` peut être un Long (`{low, high}`)
        // et non un nombre.
        //
        // Le code ne traitait que la chaîne et le protobuf, et un `Date` —
        // le cas réel en lecture — tombait dans la branche protobuf où
        // `seconds` est absent : `Number(undefined ?? 0)` valait 0, donc
        // l'epoch. Toutes les lignes s'affichaient « 01/01 01:00:00 », ce qui
        // rendait l'écran inutilisable pour situer un appel dans le temps.
        const ts = toIsoTimestamp(meta.timestamp);
        const sev =
          typeof meta.severity === "string" ? meta.severity : String(meta.severity ?? "DEFAULT");

        const payload = (e.data as Record<string, unknown> | undefined) ?? {};

        return {
          timestamp: ts,
          severity: sev,
          labels: meta.labels ?? {},
          payload: toJsonSafe(payload) as Record<string, unknown>,
          insertId: meta.insertId,
        };
      });

      // Les montants et le taux du jour ne font pas échouer la lecture des
      // journaux : ils l'accompagnent. Une grille tarifaire en panne ou un
      // taux absent laisse l'écran afficher les appels sans montant — ce qui
      // se voit — plutôt qu'un chiffre inventé — ce qui ne se voit pas.
      let calls: AiCallDto[] = [];
      let usdToEur: number | null = null;
      try {
        [calls, usdToEur] = await Promise.all([loadAiCalls(result), getUsdToEurRate()]);
      } catch (costErr) {
        await logError({
          message: "queryLogsFn : coûts des appels illisibles, journaux rendus sans montant",
          errorDescription: costErr instanceof Error ? costErr.message : String(costErr),
          extra: { filter },
        });
      }

      return {
        entries: toJsonSafe(result) as LogEntryDto[],
        calls: toJsonSafe(calls) as AiCallDto[],
        usdToEur,
        filter,
        nextPageToken,
      };
    } catch (err) {
      await logError({
        message: "queryLogsFn failed",
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { filter },
      });
      throw new HttpsError(
        "internal",
        `Échec de la requête Cloud Logging : ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  },
);
