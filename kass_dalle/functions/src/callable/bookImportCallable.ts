/**
 * Analyse d'un livre avant son import.
 *
 * Importer un livre entier déclenche des dizaines d'appels d'IA facturés. Avant
 * de les lancer, l'utilisateur voit ce que le fichier contient — nombre de pages
 * ou de tranches — et ce que cela coûtera d'après ses imports précédents. Cette
 * fonction ne dépense rien : elle ouvre le fichier et compte.
 *
 * Le même appel, avec `discard`, supprime le fichier quand l'utilisateur renonce :
 * sans lui, un livre de plusieurs centaines de mégaoctets resterait dans
 * `scans/` sans que rien ne le référence.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getStorage } from "firebase-admin/storage";

import { REGION, MAX_CALLABLE_INSTANCES } from "../config";
import { requireEditor } from "./_auth";
import { getUsdToEurRate } from "../ai/budget";
import {
  BOOK_UPLOAD_FOLDER,
  BookFileError,
  detectBookFileKind,
  openBookFile,
} from "../books/bookFile";
import { referenceCostPerScan, referenceCostPerWindow } from "../books/importEstimate";
import { suggestImportBudgetUsd } from "../ai/importBudget";
import { logError, logInfo, logWarn } from "../logging";
import { isWellFormedObjectPath } from "../utils/storagePath";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

export const analyzeBookFileFn = onCall(
  {
    region: REGION,
    // Un PDF de trois cents mégaoctets se charge en mémoire pour être compté.
    memory: "2GiB",
    timeoutSeconds: 300,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireEditor(req, "book_import_analysis");
    const { storagePath, discard } = (req.data ?? {}) as {
      storagePath?: string;
      discard?: boolean;
    };

    // Le dossier de l'appelant, et lui seul : cette fonction lit et supprime.
    //
    // La suppression accepte aussi la quarantaine : un livre abandonné pendant
    // son envoi, ou avant la fin du contrôle, n'est pas encore promu. Ce chemin
    // ne sert qu'à supprimer — l'analyse ne lit jamais ce qui n'a pas été
    // contrôlé.
    const promotedPrefix = `scans/${ctx.userId}/${BOOK_UPLOAD_FOLDER}/`;
    const quarantinePrefix = `quarantine/${ctx.userId}/${BOOK_UPLOAD_FOLDER}/`;
    const allowed =
      typeof storagePath === "string" &&
      isWellFormedObjectPath(storagePath) &&
      (storagePath.startsWith(promotedPrefix) ||
        (discard === true && storagePath.startsWith(quarantinePrefix)));
    if (typeof storagePath !== "string" || !allowed) {
      await logWarn({
        message: "analyzeBookFileFn : chemin de livre refusé",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        extra: { storagePath: String(storagePath ?? "").slice(0, 300), discard: discard === true },
      });
      throw new HttpsError("permission-denied", "Chemin de livre invalide.");
    }
    const file = getStorage().bucket().file(storagePath);

    if (discard === true) {
      await file.delete({ ignoreNotFound: true });
      await logInfo({
        message: "Livre abandonné avant l'import : fichier supprimé",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        extra: { storagePath },
      });
      return { discarded: true };
    }

    try {
      const [meta] = await file.getMetadata();
      const fileName = storagePath.split("/").pop() ?? "livre";
      const kind = detectBookFileKind(meta.contentType, fileName);
      if (!kind) {
        throw new BookFileError("Format non reconnu : un livre s'importe en PDF, EPUB ou Word.");
      }
      const [bytes] = await file.download();
      const opened = await openBookFile(bytes, kind);

      const [bookReference, pageReference, usdToEur] = await Promise.all([
        referenceCostPerWindow(ctx.userId),
        referenceCostPerScan(ctx.userId),
        getUsdToEurRate(),
      ]);

      // Un livre déjà importé mesure ce que coûte une tranche. À défaut, la
      // moyenne des pages scannées : une tranche est facturée comme l'une d'elles.
      const referenceKind =
        bookReference.perWindowUsd != null
          ? "books"
          : pageReference.meanUsd != null
            ? "pages"
            : null;
      const costPerWindowUsd =
        referenceKind === "books" ? bookReference.perWindowUsd : pageReference.meanUsd;
      const estimatedCostUsd = costPerWindowUsd != null ? costPerWindowUsd * opened.windows : null;

      return {
        kind,
        sizeBytes: bytes.length,
        pages: opened.pages,
        characters: opened.characters,
        windows: opened.windows,
        titre: opened.metadata.titre ?? null,
        auteur: opened.metadata.auteur ?? null,
        // Absent quand la mesure manque : le client affiche « indisponible », pas zéro.
        costPerWindowUsd,
        estimatedCostUsd,
        referenceKind,
        referenceScans: referenceKind === "books" ? bookReference.books : pageReference.scans,
        // Une décision, pas une mesure : le plafond proposé existe même sans
        // estimation, et l'utilisateur le règle sur l'écran.
        suggestedBudgetUsd: suggestImportBudgetUsd({ windows: opened.windows, estimatedCostUsd }),
        usdToEur,
      };
    } catch (err) {
      if (err instanceof BookFileError) {
        throw new HttpsError("failed-precondition", err.message);
      }
      if (err instanceof HttpsError) throw err;
      await logError({
        message: "Analyse du livre en échec technique",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        extra: { storagePath },
      });
      throw new HttpsError(
        "internal",
        err instanceof Error ? err.message : "Analyse du livre impossible.",
      );
    }
  },
);
