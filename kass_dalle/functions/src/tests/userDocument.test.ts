/**
 * Contrôle des comptes (`backfillUsersSchemaCheckFn`, `security/userDocument.ts`).
 *
 * Ce que ces tests verrouillent : chaque contrôle de la règle `users/{uid}` de
 * `firestore.rules` qui casse une lecture ou une écriture rend sa raison, un document conforme n'en rend aucune, le
 * libellé d'un compte ne cite jamais l'adresse, et le ponctuel ne se marque
 * terminé que sur un parcours complet sans rien à revoir.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";

import { userDocumentIssues, userReviewLabel } from "../security/userDocument";
import {
  checkUserDocument,
  summarizeUsersSchemaCheck,
  type BackfillUsersSchemaCheckResponse,
} from "../callable/usersSchemaCheckBackfillCallable";
import { BackfillReview } from "../callable/_backfillReview";
import { shouldAutoMarkDone } from "../backfills/schedule";

const ID = "abcdef123456";
const COVER =
  "https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/users%2F" +
  `${ID}%2Ffree_recipe_cover_1700000000000.jpg?alt=media&token=x`;

function valid(): Record<string, unknown> {
  return {
    uid: ID,
    email: "marie@example.com",
    display_name: "Marie Kassbi",
    preferred_name: "Marie",
    photo_url: "https://lh3.googleusercontent.com/a/photo",
    free_recipe_cover_url: COVER,
    role: "reader",
    created_at: Timestamp.fromMillis(1_700_000_000_000),
    last_seen_at: Timestamp.fromMillis(1_700_000_100_000),
    is_revoked: false,
    import_illustrations: true,
  };
}

describe("userDocumentIssues", () => {
  test("document complet et conforme : aucune raison", () => {
    assert.deepEqual(userDocumentIssues(ID, valid()), []);
  });

  test("champs facultatifs absents ou nuls : conforme", () => {
    const d = valid();
    delete d.uid;
    delete d.preferred_name;
    delete d.import_illustrations;
    d.photo_url = null;
    d.free_recipe_cover_url = null;
    assert.deepEqual(userDocumentIssues(ID, d), []);
  });

  test("les quatre rôles connus sont conformes", () => {
    for (const role of ["pending", "reader", "editor", "admin"]) {
      assert.deepEqual(userDocumentIssues(ID, { ...valid(), role }), []);
    }
  });

  const cases: [string, (d: Record<string, unknown>) => void, string[]][] = [
    ["champ non permis", (d) => (d.zzz = 1), ["champ non permis : zzz"]],
    ["uid différent", (d) => (d.uid = "autre"), ["uid différent de l'identifiant"]],
    ["uid nul", (d) => (d.uid = null), ["uid différent de l'identifiant"]],
    ["email absent", (d) => delete d.email, ["email absent"]],
    ["email non texte", (d) => (d.email = 3), ["email n'est pas un texte"]],
    ["display_name absent", (d) => delete d.display_name, ["display_name absent"]],
    ["display_name nul", (d) => (d.display_name = null), ["display_name absent"]],
    ["display_name non texte", (d) => (d.display_name = 1), ["display_name n'est pas un texte"]],
    [
      "preferred_name non texte",
      (d) => (d.preferred_name = 2),
      ["preferred_name n'est pas un texte"],
    ],
    ["rôle absent", (d) => delete d.role, ["rôle absent"]],
    ["rôle nul", (d) => (d.role = null), ["rôle absent"]],
    ["rôle inconnu", (d) => (d.role = "superadmin"), ["rôle inconnu : « superadmin »"]],
    ["rôle avec espace", (d) => (d.role = "admin "), ["rôle inconnu : « admin  »"]],
    ["rôle en majuscule", (d) => (d.role = "Admin"), ["rôle inconnu : « Admin »"]],
    ["rôle nombre", (d) => (d.role = 1), ["rôle inconnu : 1"]],
    ["is_revoked absent", (d) => delete d.is_revoked, ["is_revoked absent"]],
    [
      "is_revoked texte",
      (d) => (d.is_revoked = "false"),
      ["is_revoked n'est pas un booléen : « false »"],
    ],
    ["is_revoked nul", (d) => (d.is_revoked = null), ["is_revoked n'est pas un booléen : null"]],
    ["created_at absent", (d) => delete d.created_at, ["created_at absent"]],
    ["created_at texte", (d) => (d.created_at = "2024-01-01"), ["created_at n'est pas une date"]],
    ["created_at Date JS", (d) => (d.created_at = 1700000000), ["created_at n'est pas une date"]],
    ["last_seen_at absent", (d) => delete d.last_seen_at, ["last_seen_at absent"]],
    ["last_seen_at texte", (d) => (d.last_seen_at = "x"), ["last_seen_at n'est pas une date"]],
    ["photo_url non texte", (d) => (d.photo_url = 5), ["photo_url n'est pas un texte"]],
    [
      "couverture non texte",
      (d) => (d.free_recipe_cover_url = { url: "x" }),
      ["free_recipe_cover_url n'est pas un texte"],
    ],
  ];
  for (const [name, mutate, expected] of cases) {
    test(name, () => {
      const d = valid();
      mutate(d);
      assert.deepEqual(userDocumentIssues(ID, d), expected);
    });
  }

  test("longueurs et forme de couverture : non signalées, elles ne bloquent rien", () => {
    const d = {
      ...valid(),
      display_name: "a".repeat(200),
      preferred_name: "b".repeat(200),
      photo_url: "h".repeat(5000),
      free_recipe_cover_url: "https://example.com/a.jpg",
    };
    assert.deepEqual(userDocumentIssues(ID, d), []);
  });

  test("plusieurs écarts : tous listés, champs non permis en tête", () => {
    const d = valid();
    d.b = 1;
    d.a = 2;
    delete d.created_at;
    d.role = "boss";
    assert.deepEqual(userDocumentIssues(ID, d), [
      "champ non permis : a",
      "champ non permis : b",
      "rôle inconnu : « boss »",
      "created_at absent",
    ]);
  });
});

describe("userReviewLabel", () => {
  test("nom préféré et début de l'identifiant", () => {
    assert.equal(userReviewLabel(ID, valid()), "Marie (abcdef…)");
  });
  test("sans nom préféré : premier mot du nom Google", () => {
    assert.equal(
      userReviewLabel(ID, { display_name: "Frédéric Kassbi", email: "f@x.fr" }),
      "Frédéric (abcdef…)",
    );
  });
  test("sans nom : jamais l'adresse", () => {
    const label = userReviewLabel(ID, { email: "marie@example.com" });
    assert.equal(label, "Compte abcdef…");
    assert.ok(!label.includes("@"));
  });
  test("nom long tronqué", () => {
    assert.equal(
      userReviewLabel("abc", { preferred_name: "x".repeat(40) }),
      `${"x".repeat(19)}… (abc)`,
    );
  });
});

describe("checkUserDocument", () => {
  test("compte non conforme : ajouté, raisons réunies", () => {
    const review = new BackfillReview();
    const d = valid();
    delete d.is_revoked;
    d.uid = "autre";
    assert.equal(checkUserDocument(ID, d, review), false);
    assert.deepEqual(review.toJSON(), {
      items: [
        {
          kind: "account",
          id: ID,
          label: "Marie (abcdef…)",
          reason: "uid différent de l'identifiant ; is_revoked absent",
        },
      ],
      total: 1,
    });
  });
  test("compte conforme : rien d'ajouté", () => {
    const review = new BackfillReview();
    assert.equal(checkUserDocument(ID, valid(), review), true);
    assert.equal(review.total, 0);
  });
});

describe("summarizeUsersSchemaCheck", () => {
  const base: BackfillUsersSchemaCheckResponse = {
    examines: 12,
    conformes: 12,
    nonConformes: 0,
    echoues: 0,
    collectionParcourue: true,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };
  test("parcours complet sans écart : ponctuel terminé", () => {
    assert.equal(shouldAutoMarkDone("ponctuel", summarizeUsersSchemaCheck(base)), true);
  });
  test("un compte à revoir : pas terminé", () => {
    const s = summarizeUsersSchemaCheck({
      ...base,
      conformes: 11,
      nonConformes: 1,
      aRevoir: { items: [], total: 1 },
    });
    assert.equal(s.complete, true);
    assert.equal(shouldAutoMarkDone("ponctuel", s), false);
  });
  test("parcours arrêté : reste inconnu, pas terminé", () => {
    const s = summarizeUsersSchemaCheck({
      ...base,
      collectionParcourue: false,
      stoppedByDeadline: true,
      completed: false,
    });
    assert.equal(s.remaining, null);
    assert.equal(shouldAutoMarkDone("ponctuel", s), false);
  });
});
