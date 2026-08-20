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
import { Logging } from "@google-cloud/logging";

import { REGION, LOG_NAME, MAX_CALLABLE_INSTANCES } from "../config";
import { requireAdmin } from "./_auth";
import { logError } from "../logging";

interface QueryLogsRequest {
  severity?: "INFO" | "WARNING" | "ERROR" | "DEBUG";
  correlationId?: string;
  jobId?: string;
  userId?: string;
  /** Fenêtre de recherche en minutes (par défaut 60, max 7 jours = 10080). */
  timeRangeMinutes?: number;
  /** Recherche plein-texte dans `jsonPayload.message`. */
  freeText?: string;
  /** Taille de page (par défaut 100, max 200). */
  pageSize?: number;
}

interface LogEntryDto {
  timestamp: string;
  severity: string;
  labels: Record<string, string>;
  payload: Record<string, unknown>;
  insertId?: string;
}

const logging = new Logging();

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
    if (data.severity) {
      // Seuil, pas égalité. Une sélection « INFO » qui excluait les ERROR était
      // un piège : on croyait tout voir en filtrant le bruit, et on masquait
      // précisément les lignes qu'on cherchait. `DEBUG` reste exact — c'est le
      // seul cas où l'on veut l'instrumentation seule.
      filters.push(data.severity === "DEBUG" ? "severity=DEBUG" : `severity>=${data.severity}`);
    }
    if (data.correlationId) {
      filters.push(`labels.correlationId=${quote(data.correlationId)}`);
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
      const [entries] = await logging.getEntries({
        filter,
        pageSize,
        orderBy: "timestamp desc",
      });

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

      return { entries: toJsonSafe(result) as LogEntryDto[], filter };
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
