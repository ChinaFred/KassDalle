/**
 * Point de collecte des rapports de violation de la Content Security Policy.
 *
 * Les navigateurs y envoient un rapport chaque fois que la page enfreint la
 * politique posée par `firebase.json` (`report-uri` et `report-to`). Hosting
 * réécrit `/csp-report` vers cette fonction : le rapport part vers la même
 * origine que la page, et la politique n'a pas à autoriser un autre domaine.
 *
 * Fonction HTTPS publique (`invoker: "public"`) : un navigateur ne présente
 * ni jeton d'authentification ni jeton App Check en envoyant un rapport.
 * Elle n'écrit donc rien, et n'appelle aucun modèle ni aucun service :
 * une requête coûte une invocation et, au plus, une ligne de journal.
 *
 *  - corps borné à 16 Ko (413 au-delà) ;
 *  - types de contenu acceptés : `application/csp-report`,
 *    `application/reports+json`, et `application/json` (format `csp-report`
 *    de navigateurs anciens) ; 415 pour les autres, 400 pour un JSON illisible ;
 *  - une violation déjà vue dans la minute n'est pas rejournalisée, et au plus
 *    trente violations distinctes par minute et par instance le sont ; les
 *    écartées et les corps refusés sont comptés et journalisés en une ligne à
 *    la minute suivante ;
 *  - `maxInstances: 1` borne le débit total : au-delà de ce qu'une instance
 *    absorbe, Cloud Run répond 429 sans exécuter le code.
 *
 * Journalisation par `logWarn` : un rapport en mode `report` (politique non
 * bloquante) est un avertissement, un rapport `enforce` (ressource bloquée)
 * aussi — l'écran des journaux les montre sous le filtre « WARN+ ».
 */

import { onRequest } from "firebase-functions/v2/https";

import { REGION } from "../config";
import { logInfo, logWarn, newCorrelationId } from "../logging";
import {
  CSP_REPORT_MAX_BYTES,
  CspLogBudget,
  cspReportFormat,
  parseCspReports,
  violationKey,
} from "./reports";

const budget = new CspLogBudget();

export const cspReportFn = onRequest(
  {
    region: REGION,
    invoker: "public",
    maxInstances: 1,
    timeoutSeconds: 10,
  },
  async (req, res) => {
    const previous = budget.roll(Date.now());
    if (previous) {
      await logInfo({
        message:
          `cspReport : ${previous.dropped} violation(s) non journalisée(s) (doublons ou ` +
          `plafond) et ${previous.refused} corps refusé(s) pendant la minute précédente`,
        correlationId: newCorrelationId("csp"),
        extra: { dropped: previous.dropped, refused: previous.refused },
      });
    }

    if (req.method !== "POST") {
      res.status(405).send("");
      return;
    }
    const declaredLength = Number(req.get("content-length") ?? 0);
    const rawBody: Buffer = req.rawBody ?? Buffer.alloc(0);
    if (declaredLength > CSP_REPORT_MAX_BYTES || rawBody.length > CSP_REPORT_MAX_BYTES) {
      budget.refuse();
      res.status(413).send("");
      return;
    }
    const format = cspReportFormat(req.get("content-type"));
    if (!format) {
      budget.refuse();
      res.status(415).send("");
      return;
    }
    const violations = parseCspReports(format, rawBody.toString("utf8"));
    if (violations === null) {
      budget.refuse();
      res.status(400).send("");
      return;
    }

    const correlationId = newCorrelationId("csp");
    for (const v of violations) {
      if (!budget.admit(violationKey(v))) continue;
      await logWarn({
        message: `cspReport : ${v.directive} a refusé ${v.blocked} sur ${v.documentPath}`,
        correlationId,
        extra: {
          directive: v.directive,
          blocked: v.blocked,
          document: v.documentPath,
          source_file: v.sourceFile,
          line: v.line,
          column: v.column,
          disposition: v.disposition,
          format,
        },
      });
    }
    res.status(204).send("");
  },
);
