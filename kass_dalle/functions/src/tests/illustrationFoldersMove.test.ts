/**
 * Rangement des illustrations hors des dossiers modérés : backfill « Ranger
 * les illustrations ». Logique pure : choix de la destination, réécriture des
 * champs d'une recette, décision de suppression de l'ancien fichier.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { Timestamp } from "firebase-admin/firestore";

import { LEGACY_APP_BUCKET, recipeIllustrationIssues } from "../backfills/illustrationFolders";
import {
  illustrationMimeOf,
  moveModerationId,
  movableSourceRefusal,
  movedIllustrationPath,
  objectKey,
  recipeMovePlan,
  referencedObjectKeys,
  rewriteIllustrationReferences,
  sourceFileDecision,
  sourceFingerprint,
  sourceFolder,
  flaggedPairKey,
  readFlaggedList,
  NOT_FLAGGED_REASON,
  citationVariants,
  downloadTokensOf,
  scrubbedErrorMessage,
  type MovedObject,
} from "../backfills/illustrationFoldersMove";
import { summarizeIllustrationFoldersMove } from "../callable/illustrationFoldersMoveBackfillCallable";

const BUCKET = "kassdale-6d948.firebasestorage.app";
const opts = { buckets: [BUCKET, LEGACY_APP_BUCKET] };

function downloadUrl(path: string, bucket = BUCKET, token = "t") {
  return `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/${encodeURIComponent(path)}?alt=media&token=${token}`;
}

const SCAN = { bucket: BUCKET, path: "scans/u1/page.jpg" };
const USER = { bucket: BUCKET, path: "users/u2/free_recipe_cover_1700000000000.jpg" };

/** Liste fermée qui contient tous les objets cités par la recette « r1 ». */
function scope(keys?: string[]) {
  const all = keys ?? [
    objectKey(SCAN),
    objectKey(USER),
    `${LEGACY_APP_BUCKET}/users/u/free_recipe_cover_1.png`,
  ];
  return { recipeId: "r1", flagged: new Set(all.map((k) => flaggedPairKey("r1", k))) };
}

describe("recipeMovePlan", () => {
  test("seules les images hors dossiers modérés, sans doublon", () => {
    const plan = recipeMovePlan(
      {
        image_urls: [downloadUrl(SCAN.path), downloadUrl("recipes/r1/a.jpg")],
        thumbnail_urls: [downloadUrl(SCAN.path, BUCKET, "autre"), downloadUrl(USER.path)],
      },
      opts,
      scope(),
    );
    assert.deepEqual(plan.refs, [SCAN, USER]);
    assert.deepEqual(plan.blocking, []);
  });

  test("ancien bucket : rangé depuis son bucket", () => {
    const plan = recipeMovePlan(
      { image_urls: [downloadUrl("users/u/free_recipe_cover_1.png", LEGACY_APP_BUCKET)] },
      opts,
      scope(),
    );
    assert.deepEqual(plan.refs, [
      { bucket: LEGACY_APP_BUCKET, path: "users/u/free_recipe_cover_1.png" },
    ]);
  });

  test("autre bucket, autre hôte, chemin nu, champ mal formé : non rangés, signalés", () => {
    const plan = recipeMovePlan(
      {
        image_urls: [
          downloadUrl("users/u/x.jpg", "autre-bucket"),
          "https://exemple.org/a.jpg",
          "scans/u/p.jpg",
        ],
        thumbnail_urls: "x",
      },
      opts,
      scope(),
    );
    assert.deepEqual(plan.refs, []);
    assert.deepEqual(plan.blocking, [
      "autre bucket",
      "hors du stockage de l'application",
      "chemin sans adresse",
      "thumbnail_urls n'est pas une liste",
    ]);
  });

  test("recette conforme : rien à faire", () => {
    const plan = recipeMovePlan(
      { image_urls: [downloadUrl("illustrations/u/a.jpg")] },
      opts,
      scope(),
    );
    assert.deepEqual(plan, { refs: [], blocking: [] });
  });
});

describe("liste fermée du contrôle", () => {
  test("une image scans/ absente de la liste ne se range pas", () => {
    const plan = recipeMovePlan({ image_urls: [downloadUrl(SCAN.path)] }, opts, scope([]));
    assert.deepEqual(plan.refs, []);
    assert.deepEqual(plan.blocking, [NOT_FLAGGED_REASON]);
  });

  test("la clé est signalée pour une autre recette : refusée", () => {
    const other = { recipeId: "r2", flagged: new Set([flaggedPairKey("r1", objectKey(SCAN))]) };
    const plan = recipeMovePlan({ image_urls: [downloadUrl(SCAN.path)] }, opts, other);
    assert.deepEqual(plan.refs, []);
    assert.equal(plan.blocking.length, 1);
  });

  test("lecture de la liste : absente, mal formée, entrées ignorées", () => {
    assert.equal(readFlaggedList(undefined), null);
    assert.equal(readFlaggedList("x"), null);
    assert.deepEqual(
      [
        ...(readFlaggedList([{ recipe_id: "r1", key: "b/scans/u/p.jpg" }, { recipe_id: "" }, 3]) ??
          []),
      ],
      [flaggedPairKey("r1", "b/scans/u/p.jpg")],
    );
    assert.equal(readFlaggedList([])?.size, 0);
  });
});

describe("sources admises", () => {
  test("quarantaine, refus, ticket, couverture de livre : jamais copiés", () => {
    const plan = recipeMovePlan(
      {
        image_urls: [
          downloadUrl("quarantine/u/x.jpg"),
          downloadUrl("rejected/u/x.jpg"),
          downloadUrl("tickets/u/t/screenshot.png"),
          downloadUrl("covers/b/cover.jpg"),
        ],
      },
      opts,
      scope(),
    );
    assert.deepEqual(plan.refs, []);
    assert.equal(plan.blocking.length, 4);
    assert.match(plan.blocking[0], /^quarantine\//);
    assert.match(plan.blocking[1], /^rejected\//);
    assert.match(plan.blocking[2], /^tickets\//);
    assert.match(plan.blocking[3], /^covers\//);
  });

  test("sous users/{uid}/, tout fichier se range : couverture, découpes et vignettes", () => {
    const illus = { bucket: BUCKET, path: "users/u/illustrations/job1_0_1700000000000.jpg" };
    const thumb = { bucket: BUCKET, path: "users/u/thumbnails/job1_0_1700000000000_thumb.webp" };
    const plan = recipeMovePlan(
      { image_urls: [downloadUrl(illus.path), downloadUrl(USER.path)] },
      opts,
      scope([objectKey(illus), objectKey(USER)]),
    );
    assert.deepEqual(plan.refs, [illus, USER]);
    assert.deepEqual(plan.blocking, []);
    assert.equal(movableSourceRefusal(thumb.path), null);
    assert.equal(movableSourceRefusal("users/u/photo.jpg"), null);
  });

  test("users/ sans dossier de compte : refusé", () => {
    const plan = recipeMovePlan({ image_urls: [downloadUrl("users/photo.jpg")] }, opts, scope());
    assert.deepEqual(plan.refs, []);
    assert.equal(plan.blocking.length, 1);
    assert.match(plan.blocking[0], /^users\/ : chemin sans dossier de compte/);
  });

  test("racine du bucket et scans/ sans dossier de compte : refusés", () => {
    const plan = recipeMovePlan(
      { image_urls: [downloadUrl("a.jpg"), downloadUrl("scans/p.jpg")] },
      opts,
      scope(),
    );
    assert.deepEqual(plan.refs, []);
    assert.equal(plan.blocking.length, 2);
  });
});

describe("destination", () => {
  test("sous recipes/{id}/, nom stable dérivé du seul fichier source", () => {
    const a = movedIllustrationPath("r1", SCAN, "image/jpeg");
    assert.equal(a, `recipes/r1/illus_moved_${sourceFingerprint(SCAN)}.jpg`);
    assert.equal(movedIllustrationPath("r1", SCAN, "image/jpeg"), a, "relance : même chemin");
    assert.notEqual(movedIllustrationPath("r1", USER, "image/jpeg"), a);
    assert.equal(movedIllustrationPath("r1", USER, "image/png").endsWith(".png"), true);
    assert.equal(movedIllustrationPath("r1", USER, "image/webp").endsWith(".webp"), true);
  });

  test("même chemin dans deux buckets : deux destinations", () => {
    const legacy = { bucket: LEGACY_APP_BUCKET, path: SCAN.path };
    assert.notEqual(
      movedIllustrationPath("r1", SCAN, "image/jpeg"),
      movedIllustrationPath("r1", legacy, "image/jpeg"),
    );
  });

  test("identifiant de recette inutilisable : refusé", () => {
    assert.throws(() => movedIllustrationPath("a/b", SCAN, "image/jpeg"));
    assert.throws(() => movedIllustrationPath("..", SCAN, "image/jpeg"));
    assert.throws(() => movedIllustrationPath("", SCAN, "image/jpeg"));
  });

  test("la copie est conforme pour le contrôle « Dossiers des illustrations »", () => {
    const path = movedIllustrationPath("r1", SCAN, "image/jpeg");
    assert.deepEqual(recipeIllustrationIssues({ image_urls: [downloadUrl(path)] }, opts), []);
  });

  test("ligne de modération : identifiant stable par recette et par fichier", () => {
    assert.equal(moveModerationId("r1", SCAN), moveModerationId("r1", SCAN));
    assert.notEqual(moveModerationId("r1", SCAN), moveModerationId("r2", SCAN));
    assert.match(moveModerationId("r1", SCAN), /^illustration_move_[0-9a-f]{32}$/);
  });

  test("type lu sur les octets", () => {
    assert.equal(illustrationMimeOf(Buffer.from([0xff, 0xd8, 0xff, 0xe0])), "image/jpeg");
    assert.equal(
      illustrationMimeOf(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
      "image/png",
    );
    assert.equal(
      illustrationMimeOf(Buffer.from("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ")),
      "image/webp",
    );
    assert.equal(illustrationMimeOf(Buffer.from("%PDF-1.7")), null);
    assert.equal(illustrationMimeOf(Buffer.alloc(0)), null);
  });

  test("dossier cité sans uid", () => {
    assert.equal(sourceFolder("scans/u1/p.jpg"), "scans/");
    assert.equal(sourceFolder("p.jpg"), "racine du bucket");
  });
});

describe("rewriteIllustrationReferences", () => {
  const moved: MovedObject = {
    path: "recipes/r1/illus_moved_x.jpg",
    url: downloadUrl("recipes/r1/illus_moved_x.jpg", BUCKET, "neuf"),
  };
  const moves = new Map([[objectKey(SCAN), moved]]);

  test("illustrations, vignettes, CookLang et champ imbriqué réécrits", () => {
    const old = downloadUrl(SCAN.path);
    const data = {
      image_urls: [old, downloadUrl("recipes/r1/a.jpg")],
      thumbnail_urls: [downloadUrl(SCAN.path, BUCKET, "vignette")],
      raw_cooklang: `Étape.\n\n![schéma](${old})\n`,
      draft_cooklang: null,
      plating: { etapes: [{ image_url: old, texte: "x" }] },
      titre: "T",
    };
    const { update, replaced } = rewriteIllustrationReferences(data, moves, opts);
    assert.deepEqual(update.image_urls, [moved.url, downloadUrl("recipes/r1/a.jpg")]);
    assert.deepEqual(update.thumbnail_urls, [moved.url]);
    assert.equal(update.raw_cooklang, `Étape.\n\n![schéma](${moved.url})\n`);
    assert.deepEqual(update.plating, { etapes: [{ image_url: moved.url, texte: "x" }] });
    assert.equal("titre" in update, false, "un champ inchangé n'est pas écrit");
    assert.equal("draft_cooklang" in update, false);
    assert.equal(replaced, 4);
  });

  test("champs du fichier importé : jamais réécrits", () => {
    const old = downloadUrl(SCAN.path);
    const { update } = rewriteIllustrationReferences(
      { source_file_url: old, additional_source_file_urls: [old], image_urls: [old] },
      moves,
      opts,
    );
    assert.deepEqual(Object.keys(update), ["image_urls"]);
  });

  test("chemin nu : remplacé par le chemin de la copie", () => {
    const { update } = rewriteIllustrationReferences({ image_path: SCAN.path }, moves, opts);
    assert.equal(update.image_path, moved.path);
  });

  test("horodatage et autre fichier : intacts", () => {
    const at = Timestamp.fromMillis(0);
    const { update } = rewriteIllustrationReferences(
      { created_at: at, image_urls: [downloadUrl(USER.path)] },
      moves,
      opts,
    );
    assert.deepEqual(update, {});
  });

  test("aucun déplacement : rien à écrire", () => {
    assert.deepEqual(
      rewriteIllustrationReferences({ image_urls: [downloadUrl(SCAN.path)] }, new Map(), opts),
      { update: {}, replaced: 0 },
    );
  });
});

describe("referencedObjectKeys", () => {
  const wanted = new Set([objectKey(SCAN), objectKey(USER)]);

  test("URL, URL dans un texte, chemin nu, à toute profondeur", () => {
    assert.deepEqual(
      [...referencedObjectKeys({ file_url: SCAN.path }, wanted, opts)],
      [objectKey(SCAN)],
    );
    assert.deepEqual(
      [...referencedObjectKeys({ a: [{ b: `voir ${downloadUrl(USER.path)} ici` }] }, wanted, opts)],
      [objectKey(USER)],
    );
    assert.deepEqual(
      [
        ...referencedObjectKeys(
          { free_recipe_cover_url: `gs://${BUCKET}/${USER.path}` },
          wanted,
          opts,
        ),
      ],
      [objectKey(USER)],
    );
  });

  test("rien de recherché, ou un autre fichier : aucune référence", () => {
    assert.equal(referencedObjectKeys({ x: downloadUrl("recipes/r/a.jpg") }, wanted, opts).size, 0);
    assert.equal(referencedObjectKeys({ x: downloadUrl(SCAN.path) }, new Set(), opts).size, 0);
    assert.equal(referencedObjectKeys(Timestamp.fromMillis(0), wanted, opts).size, 0);
  });

  test("après réécriture, la recette ne cite plus l'image rangée", () => {
    const moves = new Map([
      [objectKey(SCAN), { path: "recipes/r1/x.jpg", url: downloadUrl("recipes/r1/x.jpg") }],
    ]);
    const data = { image_urls: [downloadUrl(SCAN.path)], source_file_url: downloadUrl(USER.path) };
    const after = { ...data, ...rewriteIllustrationReferences(data, moves, opts).update };
    assert.deepEqual([...referencedObjectKeys(after, wanted, opts)], [objectKey(USER)]);
  });
});

describe("sourceFileDecision", () => {
  test("plus personne ne le cite, lecture complète : supprimé", () => {
    assert.equal(
      sourceFileDecision({ holders: new Set(), indexComplete: true, sourceExists: true }),
      "delete",
    );
    assert.equal(
      sourceFileDecision({ holders: undefined, indexComplete: true, sourceExists: true }),
      "delete",
    );
  });

  test("cité ailleurs : conservé", () => {
    assert.equal(
      sourceFileDecision({
        holders: new Set(["processing_jobs/j1"]),
        indexComplete: true,
        sourceExists: true,
      }),
      "keep_referenced",
    );
  });

  test("lecture inachevée : conservé, à reprendre", () => {
    assert.equal(
      sourceFileDecision({ holders: new Set(), indexComplete: false, sourceExists: true }),
      "keep_unverified",
    );
  });

  test("déjà absent : rien à supprimer", () => {
    assert.equal(
      sourceFileDecision({ holders: new Set(), indexComplete: true, sourceExists: false }),
      "missing",
    );
  });
});

describe("summarizeIllustrationFoldersMove", () => {
  const base = {
    listeAbsente: false,
    examinees: 616,
    aRanger: 21,
    rangees: 21,
    imagesCopiees: 23,
    copiesRetrouvees: 0,
    nonDeplacables: 0,
    echouees: 0,
    restantes: 0,
    anciensSupprimes: 5,
    anciensConservesCites: 18,
    anciensEnAttente: 0,
    anciensIntrouvables: 0,
    referencesLues: 900,
    indexComplet: true,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("tout rangé, rien en attente : terminé", () => {
    assert.deepEqual(summarizeIllustrationFoldersMove(base), {
      complete: true,
      remaining: 0,
      toReview: 0,
      spendCapHit: false,
      unresolved: 0,
    });
  });

  test("recettes restantes ou anciens fichiers en attente : pas terminé", () => {
    assert.equal(summarizeIllustrationFoldersMove({ ...base, restantes: 2 }).complete, false);
    const pending = summarizeIllustrationFoldersMove({ ...base, anciensEnAttente: 1 });
    assert.equal(pending.complete, false);
    assert.equal(pending.remaining, 1);
  });

  test("liste du contrôle absente : rien fait, jamais terminé", () => {
    const s = summarizeIllustrationFoldersMove({ ...base, listeAbsente: true });
    assert.equal(s.complete, false);
    assert.equal(s.remaining, null);
  });

  test("recettes pas toutes lues : reste inconnu", () => {
    const s = summarizeIllustrationFoldersMove({ ...base, completed: false });
    assert.equal(s.complete, false);
    assert.equal(s.remaining, null);
  });
});

describe("messages d'erreur et relecture", () => {
  test("aucun chemin ni adresse dans le message, code gardé", () => {
    const err = Object.assign(
      new Error(`No such object: ${BUCKET}/scans/uid123/page.jpg (see https://x.test/a?b=c)`),
      { code: 404 },
    );
    const msg = scrubbedErrorMessage(err);
    assert.equal(msg.includes("uid123"), false);
    assert.equal(msg.includes("users/"), false);
    assert.equal(msg.includes("https://"), false);
    assert.match(msg, /^404 : No such object: \[chemin\]/);
    assert.equal(scrubbedErrorMessage(new Error("users/u9/free_recipe_cover_1.jpg")), "[chemin]");
    assert.equal(scrubbedErrorMessage(new Error("")), "erreur inconnue");
  });

  test("formes relues avant suppression : URL lues, jetons, URL publique, chemin nu, gs://", () => {
    assert.deepEqual(citationVariants(SCAN, [downloadUrl(SCAN.path), ""], ["j1", " j2 ", ""]), [
      downloadUrl(SCAN.path),
      downloadUrl(SCAN.path, BUCKET, "j1"),
      downloadUrl(SCAN.path, BUCKET, "j2"),
      `https://storage.googleapis.com/${BUCKET}/${SCAN.path}`,
      SCAN.path,
      `gs://${BUCKET}/${SCAN.path}`,
    ]);
    assert.deepEqual(downloadTokensOf({ firebaseStorageDownloadTokens: "a, b" }), ["a", "b"]);
    assert.deepEqual(downloadTokensOf(undefined), []);
  });
});
