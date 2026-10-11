/**
 * Import d'une recette depuis un lien — le travail du job `recipeUrlImport`.
 *
 * Le job est créé par `importRecipeFromUrlFn`, qui a déjà vérifié le rôle,
 * l'adresse, le plafond du jour et le doublon. Il suit ensuite le pipeline de
 * tout import : `jobDispatcher` → Cloud Tasks → `recipeProcessor`, qui appelle
 * ce module à la place du téléchargement d'un fichier.
 *
 * 1. **Lecture de la page** (`fetch`) : récupération protégée (`web/safeFetch`),
 *    l'adresse revérifiée — un job relancé n'a pas repassé par la callable.
 * 2. **Données structurées** : la recette `schema.org/Recipe` de la page,
 *    projetée sans modèle (`web/recipePage`). Sinon, le texte principal suit
 *    la chaîne du texte collé — poste `url_import_fallback`.
 * 3. **Traduction** si la recette n'est pas en français (`recipe_translation`).
 * 4. **Balisage** — poste `url_import`, même prompt que `recipe_tagging`.
 *
 * L'écriture du brouillon reste à `recipeProcessor` (`saveDraft`), qui la fait
 * pour tous les imports. La photo du site passe ensuite par la modération
 * (`attachWebPhoto`).
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getDownloadURL, getStorage } from "firebase-admin/storage";

import { COLL_BOOKS } from "../config";
import { logError, logInfo, logWarn } from "../logging";
import { isAdminAccount } from "../callable/_auth";
import { needsTranslation, transcribeText, type TranscribedRecipe } from "../gemini/transcription";
import { translateRecipe } from "../gemini/translation";
import { tagAndNormalize, type TaggedRecipe } from "../gemini/tagging";
import { checkFidelity, verbatimCooklang, type FidelityReport } from "../gemini/fidelity";
import { moderateAndPromote } from "../moderation/moderateAndPromote";
import {
  IMAGE_FETCH_OPTIONS,
  PAGE_FETCH_OPTIONS,
  WebFetchError,
  decodeHtml,
  fetchPublicResource,
} from "../web/safeFetch";
import {
  UrlRefusedError,
  assertPublicHost,
  parseImportUrl,
  type ParsedImportUrl,
} from "../web/urlGuard";
import {
  exceedsJsonLdBounds,
  isCompleteRecipe,
  parseRecipePage,
  projectJsonLdRecipe,
  recipeAsPlainText,
} from "../web/recipePage";

/** Formats d'image admis pour la photo d'une page. SVG exclu : c'est du code. */
const ACCEPTED_IMAGE_FORMATS = new Set(["jpeg", "png", "webp", "avif", "gif", "heif"]);

/** Type du job dans `processing_jobs`. */
export const URL_IMPORT_JOB_TYPE = "recipeUrlImport";

/** Poste de coût du balisage d'une recette lue sur une page web. */
export const URL_IMPORT_FEATURE = "url_import";
/** Poste de coût de la transcription d'une page sans données structurées. */
export const URL_IMPORT_FALLBACK_FEATURE = "url_import_fallback";

/** Tag interne du livre système « Mes recettes du web ». */
export const WEB_BOOK_TAG = "__web";
export const WEB_BOOK_TITLE = "Mes recettes du web";

/**
 * Code d'échec écrit sur le job (`error_code`), lu par la tuile du client.
 *
 * - `page_blocked` : le site refuse la lecture (401, 402, 403, 429, 451) ;
 * - `page_not_found` : 404 ou 410 ;
 * - `no_recipe` : la page ne contient aucune recette ;
 * - `timeout` : délai dépassé, réseau, erreur serveur du site ;
 * - `url_refused` : adresse non publique, trop de redirections, contenu qui
 *   n'est pas une page web, page trop volumineuse.
 */
export type UrlImportErrorCode =
  "page_blocked" | "page_not_found" | "no_recipe" | "timeout" | "url_refused";

/** Échec d'un import par lien, avec son code lisible. */
export class UrlImportError extends Error {
  constructor(
    readonly code: UrlImportErrorCode,
    detail: string,
    /** Vrai pour un échec passager : Cloud Tasks réessaie. */
    readonly retryable: boolean,
  ) {
    super(detail);
    this.name = "UrlImportError";
  }
}

/** Message affiché sur le job, en français, pour chaque code. */
export const URL_IMPORT_MESSAGES: Record<UrlImportErrorCode, string> = {
  page_blocked: "Ce site ne laisse pas Kass'Dalle lire la page.",
  page_not_found: "Cette page n'existe pas ou plus sur le site.",
  no_recipe: "Aucune recette trouvée sur cette page.",
  timeout: "La page n'a pas répondu à temps.",
  url_refused: "Ce lien ne peut pas être importé.",
};

/** Traduit un échec de récupération en échec d'import. Pure, testée. */
export function urlImportErrorFrom(err: WebFetchError | UrlRefusedError): UrlImportError {
  if (err instanceof UrlRefusedError) {
    return new UrlImportError("url_refused", err.message, false);
  }
  switch (err.failure) {
    case "blocked":
      return new UrlImportError("page_blocked", err.message, false);
    case "not_found":
      return new UrlImportError("page_not_found", err.message, false);
    case "timeout":
    case "network":
      return new UrlImportError("timeout", err.message, true);
    case "refused":
    case "not_html":
    case "too_large":
      return new UrlImportError("url_refused", err.message, false);
  }
}

type Ctx = { jobId: string; userId: string; correlationId: string; scanId?: string };

/** Ce que l'import prépare, avant l'écriture du brouillon. */
export interface PreparedUrlImport {
  parsed: ParsedImportUrl;
  recette: TranscribedRecipe;
  tagged: TaggedRecipe;
  fidelity: FidelityReport;
  cooklang: string;
  /** Combien de recettes la page contenait ; une seule est reprise. */
  recettesTrouvees: number;
  /** `json_ld` : sans modèle de lecture ; `text` : texte principal transcrit. */
  path: "json_ld" | "text";
  /** Photo de la page : image de la recette, sinon `og:image`. */
  imageUrl: string | null;
  /** Texte joint comme document original. */
  originalText: string;
}

/**
 * Lit la page et prépare la recette balisée. Lève `UrlImportError` pour un
 * échec lisible ; toute autre erreur (modèle, plafond) remonte telle quelle.
 */
export async function prepareUrlImport(args: {
  sourceUrl: unknown;
  ctx: Ctx;
  onStep: (step: string, fields?: Record<string, unknown>) => Promise<void>;
}): Promise<PreparedUrlImport> {
  const { ctx, onStep } = args;
  let parsed: ParsedImportUrl;
  let html: string;
  let finalUrl: string;
  try {
    parsed = parseImportUrl(args.sourceUrl);
    await onStep("fetch");
    await assertPublicHost(parsed.url);
    const page = await fetchPublicResource(parsed.url, PAGE_FETCH_OPTIONS);
    html = decodeHtml(page.body, page.charset);
    finalUrl = page.finalUrl;
  } catch (err) {
    if (err instanceof WebFetchError || err instanceof UrlRefusedError) {
      throw urlImportErrorFrom(err);
    }
    throw err;
  }

  const page = parseRecipePage(html, finalUrl);
  if (page.invalidBlocks.length > 0) {
    await logWarn({
      message: `Page web : ${page.invalidBlocks.length} bloc(s) JSON-LD illisible(s), ignoré(s)`,
      moduleType: "IMPORT",
      ...ctx,
      extra: { site: parsed.site, blocs: page.invalidBlocks.slice(0, 3) },
    });
  }

  const structured = page.recipes.find(isCompleteRecipe);
  // Une recette publiée au-delà des bornes (`JSON_LD_BOUNDS`) n'est pas envoyée
  // au modèle, ni par la projection ni par le texte de la page.
  if (!structured && page.recipes.some(exceedsJsonLdBounds)) {
    throw new UrlImportError(
      "no_recipe",
      "Recette publiée au-delà des bornes (longueur, ingrédients, étapes).",
      false,
    );
  }
  let recette: TranscribedRecipe;
  let recettesTrouvees: number;
  let path: "json_ld" | "text";
  let imageUrl: string | null;

  if (structured) {
    recette = projectJsonLdRecipe(structured, page.htmlLang);
    recettesTrouvees = page.recipes.filter(isCompleteRecipe).length;
    path = "json_ld";
    imageUrl = structured.image ?? page.ogImage;
  } else {
    if (page.mainText.trim().length < 80) {
      throw new UrlImportError("no_recipe", "Page sans texte exploitable.", false);
    }
    await onStep("gemini_call");
    const transcription = await transcribeText(
      page.mainText,
      { ...ctx, feature: URL_IMPORT_FALLBACK_FEATURE, moduleType: "IMPORT" },
      URL_IMPORT_FALLBACK_FEATURE,
    );
    const first = transcription.recettes[0];
    if (!first) {
      throw new UrlImportError(
        "no_recipe",
        `Aucune recette dans le texte de la page (${transcription.pageType}).`,
        false,
      );
    }
    // Une page sans `lang` ni langue lue vaut "fr" : la transcription la lit.
    recette = first;
    recettesTrouvees = transcription.recettes.length;
    path = "text";
    imageUrl = page.ogImage;
  }

  await logInfo({
    message: `Page web lue (${path}) : « ${recette.titre} »`,
    moduleType: "IMPORT",
    ...ctx,
    extra: { site: parsed.site, path, recettesTrouvees, image: imageUrl != null },
  });
  await onStep("parse", {
    titre: recette.titre || null,
    recettes_trouvees: recettesTrouvees,
  });

  if (needsTranslation(recette)) {
    // `translated` garde le jalon « Traduction » dans le fil du client.
    await onStep("translate", { translated: true });
    recette = await translateRecipe(recette, {
      ...ctx,
      feature: "recipe_translation",
      moduleType: "IMPORT",
    });
    await onStep("translate", { titre: recette.titre || null });
  }

  await onStep("tagging");
  const taggedRaw = await tagAndNormalize(
    recette,
    { ...ctx, feature: URL_IMPORT_FEATURE, moduleType: "IMPORT" },
    URL_IMPORT_FEATURE,
  );
  const tagged = { ...taggedRaw, ingredients: boundIngredients(taggedRaw.ingredients) };
  if (tagged.ingredients.length < taggedRaw.ingredients.length) {
    await logWarn({
      message: `Import par lien : ${taggedRaw.ingredients.length - tagged.ingredients.length} ligne(s) d'ingrédient hors bornes écartée(s)`,
      moduleType: "IMPORT",
      ...ctx,
      extra: { avant: taggedRaw.ingredients.length, apres: tagged.ingredients.length },
    });
  }
  const fidelity = checkFidelity(recette, tagged);
  if (fidelity.findings.length > 0) {
    const entry = {
      message: `Contrôle de fidélité (${fidelity.level}) : ${fidelity.findings
        .map((f) => f.message)
        .join(" ")}`,
      moduleType: "IMPORT" as const,
      ...ctx,
      extra: { titre: recette.titre, niveau: fidelity.level },
    };
    if (fidelity.rejette) await logError(entry);
    else await logInfo(entry);
  }

  const header = `Source : ${parsed.normalized}\nLu le : ${new Date().toISOString()}\n\n`;
  const body =
    page.mainText.trim().length > 0
      ? page.mainText
      : structured
        ? recipeAsPlainText(structured)
        : "";

  return {
    parsed,
    recette,
    tagged,
    fidelity,
    cooklang: fidelity.rejette ? verbatimCooklang(recette) : tagged.cooklang,
    recettesTrouvees,
    path,
    imageUrl,
    originalText: header + body,
  };
}

/**
 * Bornes d'une ligne d'ingrédient écrite par l'import par lien.
 *
 * La normalisation qui suit (`normalizeRecipeReferentialsCore`) crée ou
 * complète un document `nutrition_ingredients` par nom, et y ajoute le nom
 * comme alias. Le nom vient du balisage d'un texte tiers : sans borne, une
 * page pouvait créer des centaines de référentiels aux noms de plusieurs
 * kilo-octets.
 */
export const INGREDIENT_BOUNDS = { count: 200, nameChars: 120, unitChars: 40 } as const;

/** Écarte les lignes hors bornes et garde au plus `INGREDIENT_BOUNDS.count` lignes. Pure, testée. */
export function boundIngredients<T extends { nom: string; unite: string }>(lines: T[]): T[] {
  return lines
    .filter(
      (l) =>
        l.nom.trim().length > 0 &&
        l.nom.length <= INGREDIENT_BOUNDS.nameChars &&
        l.unite.length <= INGREDIENT_BOUNDS.unitChars,
    )
    .slice(0, INGREDIENT_BOUNDS.count);
}

/** Vrai si un livre existant est bien le livre « Mes recettes du web » de `uid`. Pure, testée. */
export function isOwnWebBook(data: Record<string, unknown> | undefined, uid: string): boolean {
  const tags = data?.tags;
  return (
    data?.created_by === uid && Array.isArray(tags) && (tags as unknown[]).includes(WEB_BOOK_TAG)
  );
}

/**
 * Le livre système « Mes recettes du web » du compte, créé avec les autres
 * livres système (`ensureWebBookFn`) ou, à défaut, au premier import.
 *
 * Identifiant déterministe (`web_{uid}`) : deux imports simultanés ne créent
 * pas deux livres. Privé à son propriétaire, et marqué du tag `__web` qui le
 * rend non supprimable (règles Firestore). Il se renomme comme les autres
 * livres système : on garde le titre qu'il porte.
 *
 * Un document `web_{uid}` qui n'est pas ce livre — un autre compte l'aurait
 * créé pour y faire tomber les brouillons, public — n'est jamais réutilisé.
 * Les règles refusent désormais cette création au client ; si le document
 * existe quand même, le livre du compte est cherché par son tag, sinon créé
 * sous `web2_{uid}` en transaction, et l'incident est journalisé une fois.
 */
export async function findOrCreateWebBook(
  uid: string,
  ctx?: Pick<Ctx, "userId" | "correlationId"> & Partial<Ctx>,
): Promise<{ id: string; titre: string }> {
  const db = getFirestore();
  const ref = db.collection(COLL_BOOKS).doc(`web_${uid}`);
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists) {
      if (!isOwnWebBook(snap.data(), uid)) return null;
      const titre = snap.get("titre");
      return { id: ref.id, titre: typeof titre === "string" && titre ? titre : WEB_BOOK_TITLE };
    }
    tx.set(ref, webBookDocument(uid));
    return { id: ref.id, titre: WEB_BOOK_TITLE };
  });
  if (outcome) return outcome;

  // `web_{uid}` est occupé par un document étranger au compte. Le livre du
  // compte est d'abord cherché par son tag (repli déjà créé, éventuellement
  // sous un identifiant aléatoire par une version précédente).
  const byTag = await db
    .collection(COLL_BOOKS)
    .where("created_by", "==", uid)
    .where("tags", "array-contains", WEB_BOOK_TAG)
    .limit(1)
    .get();
  if (!byTag.empty) {
    const doc = byTag.docs[0];
    const titre = doc.get("titre");
    return { id: doc.id, titre: typeof titre === "string" && titre ? titre : WEB_BOOK_TITLE };
  }

  // Sinon, repli sous un second identifiant déterministe, créé en transaction :
  // deux appels simultanés ne créent pas deux livres. Les règles refusent au
  // client tout identifiant `web…_` (`web_`, `web2_`).
  const fallbackRef = db.collection(COLL_BOOKS).doc(`web2_${uid}`);
  const fallback = await db.runTransaction(async (tx) => {
    const snap = await tx.get(fallbackRef);
    if (snap.exists) {
      if (!isOwnWebBook(snap.data(), uid)) return "foreign" as const;
      const titre = snap.get("titre");
      return {
        created: false,
        id: fallbackRef.id,
        titre: typeof titre === "string" && titre ? titre : WEB_BOOK_TITLE,
      };
    }
    tx.create(fallbackRef, webBookDocument(uid));
    return { created: true, id: fallbackRef.id, titre: WEB_BOOK_TITLE };
  });
  if (fallback === "foreign") {
    const message = `Livres web_${uid} et web2_${uid} étrangers au compte : aucun livre web`;
    await logError({ message, moduleType: "IMPORT", ...(ctx ?? { userId: uid }) });
    throw new Error(message);
  }
  if (fallback.created) {
    // Un seul journal, au moment où le repli est créé : les appels suivants
    // retrouvent le livre par son tag sans rien journaliser.
    await logError({
      message: `Livre web_${uid} existant mais étranger au compte : repli web2_${uid} créé`,
      moduleType: "IMPORT",
      ...(ctx ?? { userId: uid }),
    });
  }
  return { id: fallback.id, titre: fallback.titre };
}

function webBookDocument(uid: string): Record<string, unknown> {
  const now = Timestamp.now();
  return {
    titre: WEB_BOOK_TITLE,
    sous_titre: null,
    editeur: null,
    serie: null,
    auteur: "Kass'Dalle",
    annee: null,
    langue: "fr",
    isbn: null,
    description: "Les recettes importées depuis un lien vers une page web.",
    url_couverture: null,
    tags: [WEB_BOOK_TAG],
    review_status: "validated",
    created_by: uid,
    created_at: now,
    updated_at: now,
    source_file_url: null,
    source_file_name: null,
    ai_processed_at: null,
    is_private: true,
  };
}

/**
 * Dépose le texte de la page comme document original, dans le dossier promu
 * du compte — là où l'écran « Document original » lit le texte collé.
 */
export async function uploadOriginalText(args: {
  uid: string;
  jobId: string;
  site: string;
  text: string;
}): Promise<{ url: string; name: string }> {
  const safeSite = args.site.replace(/[^a-z0-9.-]/gi, "_").slice(0, 60);
  const name = `page_web_${safeSite}.txt`;
  const file = getStorage().bucket().file(`scans/${args.uid}/web_${args.jobId}_${name}`);
  await file.save(Buffer.from(args.text, "utf8"), {
    contentType: "text/plain; charset=utf-8",
    resumable: false,
  });
  return { url: await getDownloadURL(file), name };
}

/**
 * Récupère la photo de la page et la soumet à la modération, rattachée à la
 * recette (`attachOnApproval`).
 *
 * Best-effort, sans jamais faire échouer le job : refusée, illisible ou
 * injoignable, la recette reste sans photo et l'incident est journalisé.
 * Approuvée tout de suite, elle rejoint la recette ; en attente, elle la
 * rejoindra quand la modération l'acceptera.
 */
export async function attachWebPhoto(args: {
  imageUrl: string | null;
  recipeId: string;
  ctx: Ctx;
}): Promise<"attached" | "held" | "refused" | "none" | "failed"> {
  const { imageUrl, recipeId, ctx } = args;
  if (!imageUrl) return "none";
  const quarantinePath = `quarantine/${ctx.userId}/web_${ctx.jobId}.jpg`;
  try {
    const parsed = parseImportUrl(imageUrl);
    await assertPublicHost(parsed.url);
    const image = await fetchPublicResource(parsed.url, IMAGE_FETCH_OPTIONS);
    // JPEG, redressée, au plus 1600 px : la modération n'accepte que JPEG et
    // PNG, et un site sert souvent du WebP ou de l'AVIF. La conversion retire
    // aussi les métadonnées de l'image.
    const { default: sharp } = await import("sharp");
    // Bornes de décodage : 40 mégapixels au plus (une image « bombe » de
    // quelques kilo-octets se décompresse en gigaoctets), et une image
    // corrompue échoue au lieu d'être décodée à moitié.
    const decoderOptions = { limitInputPixels: 40_000_000, failOn: "error" as const };
    const meta = await sharp(image.body, decoderOptions).metadata();
    if (!ACCEPTED_IMAGE_FORMATS.has(meta.format ?? "")) {
      throw new Error(`Format d'image refusé : ${meta.format ?? "inconnu"}`);
    }
    const jpeg = await sharp(image.body, decoderOptions)
      .rotate()
      .resize({ width: 1600, height: 1600, fit: "inside", withoutEnlargement: true })
      .jpeg({ quality: 85 })
      .toBuffer();
    await getStorage().bucket().file(quarantinePath).save(jpeg, {
      contentType: "image/jpeg",
      resumable: false,
    });
    const { results } = await moderateAndPromote({
      items: [
        {
          quarantinePath,
          targetKind: "recipe_illustration",
          ownerId: recipeId,
          contentType: "image/jpeg",
          origin: "user",
          attachOnApproval: true,
        },
      ],
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      isAdmin: isAdminAccount,
    });
    const status = results[0]?.status;
    await logInfo({
      message: `Photo de la page : ${status ?? "inconnu"}`,
      moduleType: "MODERATION",
      ...ctx,
      extra: { recipeId, status: status ?? null },
    });
    if (status === "approved") return "attached";
    if (status === "rejected") return "refused";
    return "held";
  } catch (err) {
    await logError({
      message: "Photo de la page non importée (recette gardée sans photo)",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "MODERATION",
      ...ctx,
      extra: { recipeId, imageUrl: imageUrl.slice(0, 300) },
    });
    return "failed";
  }
}
