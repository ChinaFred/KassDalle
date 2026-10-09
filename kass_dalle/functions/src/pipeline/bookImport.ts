/**
 * Import d'un livre entier — le job `bookDocumentScan`.
 *
 * Ce job ne transcrit rien lui-même. Il ouvre le fichier, crée le livre s'il
 * n'existe pas, découpe le contenu en tranches et crée **un job d'import par
 * tranche**. Ces jobs sont des `recipeScan` ordinaires : ils passent par le
 * même pipeline qu'une page scannée, avec le même contrôle de fidélité, les
 * mêmes plafonds de dépense et la même file. Le livre ne demande donc aucun
 * traitement de recette de plus, seulement du découpage.
 *
 * Idempotent : Cloud Tasks peut rejouer ce traitement. Le livre et chaque job
 * enfant ont un identifiant déterminé par le job parent, et un enfant déjà créé
 * n'est jamais recréé — il a peut-être déjà commencé.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getDownloadURL, getStorage } from "firebase-admin/storage";

import { COLL_BOOKS, COLL_PROCESSING_JOBS } from "../config";
import {
  BookFileError,
  detectBookFileKind,
  openBookFile,
  type BookMetadata,
} from "../books/bookFile";
import { BudgetExceededError } from "../ai/budget";
import { effectiveImportLimitUsd, parseBudgetLimit, setImportCeiling } from "../ai/importBudget";
import { extractBookCover } from "../gemini/search";
import type { BookWindowInfo } from "../gemini/promptsExtraction";
import { logError, logInfo } from "../logging";

export interface BookImportContext {
  jobId: string;
  userId: string;
  correlationId: string;
  scanId?: string;
}

export interface BookImportResult {
  bookId: string;
  bookTitre: string;
  createdBook: boolean;
  windows: number;
}

/** Code gRPC d'un document qui existe déjà — ce que `create()` lève alors. */
const ALREADY_EXISTS = 6;

function pad(value: number, width: number): string {
  return String(value).padStart(width, "0");
}

/**
 * La tranche que porte un job d'import, telle que `runBookImport` l'a écrite.
 *
 * `undefined` pour un job ordinaire : une page scannée n'est la tranche de rien.
 */
export function parseBookWindow(value: unknown): BookWindowInfo | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  if (raw.kind !== "pdf" && raw.kind !== "text") return undefined;
  const context = Number(raw.context);
  const owned = Number(raw.owned);
  return {
    kind: raw.kind,
    context: Number.isFinite(context) && context > 0 ? context : 0,
    ...(Number.isFinite(owned) && owned > 0 ? { owned } : {}),
  };
}

/** Un nom de fichier sans extension, lisible : le repli quand rien d'autre ne nomme le livre. */
export function titleFromFileName(fileName: string | undefined): string {
  const base = (fileName ?? "").replace(/\.[A-Za-z0-9]{1,5}$/, "");
  const cleaned = base
    .replace(/^\d{10,}_/, "")
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned.length > 0 ? cleaned : "Livre importé";
}

/**
 * Ce que le livre dira de lui-même : l'IA d'abord pour un PDF, le fichier sinon.
 *
 * Un PDF n'a presque jamais de métadonnées fiables — le titre y vaut souvent
 * « scan0042 » ou « Microsoft Word - doc1 ». Sa première page est la couverture,
 * et la lire est le geste de « Scanner la couverture ». Un EPUB, lui, porte un
 * fichier de métadonnées précis : aucun appel d'IA.
 *
 * Une lecture qui échoue ne fait pas échouer l'import : le livre se crée avec ce
 * que le fichier dit, et l'utilisateur le corrigera. Seul un plafond de dépense
 * atteint remonte, puisque les jobs enfants échoueraient de la même façon.
 */
async function resolveMetadata(args: {
  fileMetadata: Partial<BookMetadata>;
  firstPagePdf: Buffer | null;
  fileName: string | undefined;
  apiKey: string;
  ctx: BookImportContext;
}): Promise<BookMetadata> {
  const { fileMetadata, firstPagePdf, fileName, apiKey, ctx } = args;
  let fromCover: Awaited<ReturnType<typeof extractBookCover>> | null = null;

  if (firstPagePdf) {
    try {
      fromCover = await extractBookCover(apiKey, firstPagePdf, "application/pdf", {
        ...ctx,
        feature: "book_cover",
        moduleType: "IMPORT",
      });
    } catch (err) {
      if (err instanceof BudgetExceededError) throw err;
      await logError({
        message:
          "Lecture de la première page du PDF impossible — le livre prendra le titre du fichier",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "IMPORT",
        ...ctx,
      });
    }
  }

  const titre =
    fromCover?.titre?.trim() || fileMetadata.titre?.trim() || titleFromFileName(fileName);
  const auteur = fromCover?.auteur?.trim() || fileMetadata.auteur?.trim() || "Auteur inconnu";
  return {
    titre,
    sousTitre: fromCover?.sous_titre ?? null,
    auteur,
    editeur: fromCover?.editeur ?? fileMetadata.editeur ?? null,
    serie: fromCover?.serie ?? null,
    annee: fromCover?.annee ?? fileMetadata.annee ?? null,
    langue: fromCover?.langue ?? fileMetadata.langue ?? "fr",
    isbn: fromCover?.isbn ?? fileMetadata.isbn ?? null,
    description: fromCover?.description ?? fileMetadata.description ?? null,
    tags: fromCover?.tags ?? [],
  };
}

/**
 * Exécute le job parent. Rend le livre et le nombre de jobs créés.
 *
 * Lève `BookFileError` pour un fichier illisible — message destiné à
 * l'utilisateur, jamais réessayé.
 */
export async function runBookImport(args: {
  job: Record<string, unknown>;
  bytes: Buffer;
  apiKey: string;
  ctx: BookImportContext;
  onProgress: (fields: Record<string, unknown>) => Promise<void>;
}): Promise<BookImportResult> {
  const { job, bytes, apiKey, ctx, onProgress } = args;
  const { jobId, userId } = ctx;
  const fileName = job.file_name as string | undefined;
  const fileUrl = (job.file_url as string | undefined) ?? "";

  const kind = detectBookFileKind(job.mime_type as string | undefined, fileName);
  if (!kind) {
    throw new BookFileError("Format non reconnu : un livre s'importe en PDF, EPUB ou Word.");
  }

  const opened = await openBookFile(bytes, kind);
  await logInfo({
    message: `Livre ouvert (${kind}) : ${opened.windows} tranche(s) à traiter`,
    moduleType: "IMPORT",
    ...ctx,
    extra: { kind, pages: opened.pages, characters: opened.characters, windows: opened.windows },
  });

  // Le plafond que l'utilisateur a fixé sur l'écran de confirmation, posé avant
  // que la première tranche existe : chacune le relit avant son premier appel
  // d'IA. La valeur vient du client : elle ne fait que réduire le maximum que
  // fixe le serveur, et un job sans plafond reçoit ce maximum.
  const clientLimitUsd = parseBudgetLimit(job.budget_limit_usd);
  const budgetLimitUsd = effectiveImportLimitUsd({
    clientLimitUsd,
    windows: opened.windows,
  });
  if (ctx.scanId) {
    await setImportCeiling({ scanId: ctx.scanId, userId, limitUsd: budgetLimitUsd });
    await logInfo({
      message: `Plafond de l'import posé : ${budgetLimitUsd} $`,
      moduleType: "IMPORT",
      ...ctx,
      extra: { budgetLimitUsd, clientLimitUsd, capped: budgetLimitUsd !== clientLimitUsd },
    });
  }

  const db = getFirestore();
  const bucket = getStorage().bucket();
  const folder = `scans/${userId}/book_import_${jobId}`;

  // Le livre : celui qu'on a choisi, ou un nouveau créé depuis le fichier.
  let bookId = typeof job.book_id === "string" ? job.book_id : "";
  let bookTitre = typeof job.book_titre === "string" ? job.book_titre : "";
  const createdBook = bookId.length === 0;

  if (createdBook) {
    await onProgress({ current_step: "gemini_call" });
    const metadata = await resolveMetadata({
      fileMetadata: opened.metadata,
      firstPagePdf: await opened.firstPagePdf(),
      fileName,
      apiKey,
      ctx,
    });

    let coverUrl: string | null = null;
    const cover = await opened.cover();
    if (cover) {
      const coverFile = bucket.file(`${folder}/couverture.jpg`);
      await coverFile.save(cover, {
        contentType: "image/jpeg",
        resumable: false,
        metadata: { metadata: { quarantine_status: "clean", source: "book_import" } },
      });
      coverUrl = await getDownloadURL(coverFile);
    }

    // Un identifiant déterminé : un rejeu réécrit le même livre au lieu d'en créer un second.
    const bookRef = db.collection(COLL_BOOKS).doc(`book_import_${jobId}`);
    const now = Timestamp.now();
    await bookRef.set({
      titre: metadata.titre,
      sous_titre: metadata.sousTitre,
      editeur: metadata.editeur,
      serie: metadata.serie,
      auteur: metadata.auteur,
      annee: metadata.annee,
      langue: metadata.langue,
      isbn: metadata.isbn,
      description: metadata.description,
      url_couverture: coverUrl,
      tags: metadata.tags,
      review_status: "validated",
      created_by: userId,
      created_at: now,
      updated_at: now,
      source_file_url: fileUrl,
      source_file_name: fileName ?? null,
      ai_processed_at: now,
      is_private: false,
    });
    bookId = bookRef.id;
    bookTitre = metadata.titre;
    await onProgress({ titre: bookTitre, created_book_id: bookId });
  }

  // Les tranches. Une à une : un PDF de trois cents pages ne tient pas deux
  // fois en mémoire, et l'envoi ne va pas plus vite en parallèle qu'il ne pèse.
  await onProgress({ current_step: "save", windows_total: opened.windows });
  let created = 0;
  let total = 0;
  try {
    for await (const chunk of opened.chunks()) {
      total += 1;
      const file = bucket.file(`${folder}/${pad(chunk.index, 4)}.${chunk.extension}`);
      await file.save(chunk.bytes, {
        contentType: chunk.mimeType,
        resumable: false,
        metadata: { metadata: { quarantine_status: "clean", source: "book_import" } },
      });
      const chunkUrl = await getDownloadURL(file);

      const now = Timestamp.now();
      try {
        await db
          .collection(COLL_PROCESSING_JOBS)
          .doc(`book_import_${jobId}_${pad(chunk.index, 4)}`)
          .create({
            type: "recipeScan",
            status: "queued",
            created_by: userId,
            created_at: now,
            updated_at: now,
            file_name: `${bookTitre} — ${chunk.label}`,
            file_url: chunkUrl,
            mime_type: chunk.mimeType,
            book_id: bookId,
            book_titre: bookTitre,
            created_recipe_ids: [],
            created_book_id: null,
            error_message: null,
            additional_file_urls: [],
            import_illustrations: false,
            ...(ctx.scanId ? { scan_id: ctx.scanId } : {}),
            parent_job_id: jobId,
            book_window: chunk.window,
          });
        created += 1;
      } catch (err) {
        // Un enfant déjà créé par une tentative précédente : on le laisse, il a
        // peut-être déjà commencé. Toute autre erreur remonte.
        if ((err as { code?: unknown }).code !== ALREADY_EXISTS) throw err;
      }

      if (total % 10 === 0) await onProgress({ windows_created: total });
    }
  } catch (err) {
    // Un livre neuf sans aucun job derrière lui n'est qu'une couverture vide :
    // on le retire, la nouvelle tentative le recréera. La vérification lit la
    // base : une tentative précédente a pu créer des jobs que celle-ci n'a pas
    // recréés, et le livre qui les porte doit rester.
    try {
      const children = await db
        .collection(COLL_PROCESSING_JOBS)
        .where("parent_job_id", "==", jobId)
        .limit(1)
        .get();
      if (createdBook && children.empty) {
        await db.collection(COLL_BOOKS).doc(bookId).delete();
      }
    } catch (cleanupErr) {
      await logError({
        message: "Retrait du livre vide échoué après l'échec de l'import",
        errorDescription: cleanupErr instanceof Error ? cleanupErr.message : String(cleanupErr),
        moduleType: "IMPORT",
        ...ctx,
        extra: { bookId },
      });
    }
    throw err;
  }

  await logInfo({
    message: `Import du livre : ${created} job(s) créé(s) sur ${total} tranche(s)`,
    moduleType: "IMPORT",
    ...ctx,
    extra: { bookId, created, total },
  });
  return { bookId, bookTitre, createdBook, windows: total };
}
