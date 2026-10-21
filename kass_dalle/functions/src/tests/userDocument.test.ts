/**
 * Contrôle des comptes (`backfillUsersSchemaCheckFn`, `security/userDocument.ts`).
 *
 * Ce que ces tests verrouillent : chaque écart qui casse la lecture par
 * `AppUser.fromFirestore`, les droits ou `isRevoked()` rend sa raison et son
 * effet ; ce qui ne bloque rien n'est pas signalé ; le libellé d'un compte ne
 * cite jamais l'adresse, et le ponctuel ne se marque
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
  const L = "la fiche n'apparaît pas dans Comptes";
  const R = "compte sans droit, affiché « en attente » dans Comptes";
  const V = "toute règle qui lit la révocation échoue pour ce compte";

  test("document complet et conforme : aucune raison", () => {
    assert.deepEqual(userDocumentIssues(valid()), []);
  });

  test("champs facultatifs absents ou nuls, is_revoked nul : conforme", () => {
    const d = valid();
    delete d.uid;
    delete d.preferred_name;
    delete d.import_illustrations;
    d.photo_url = null;
    d.free_recipe_cover_url = null;
    d.is_revoked = null;
    assert.deepEqual(userDocumentIssues(d), []);
  });

  test("les quatre rôles connus sont conformes", () => {
    for (const role of ["pending", "reader", "editor", "admin"]) {
      assert.deepEqual(userDocumentIssues({ ...valid(), role }), []);
    }
  });

  test("ce qui ne bloque rien n'est pas signalé", () => {
    const d = {
      ...valid(),
      uid: "autre",
      zzz: 1,
      "marie@example.com": true,
      display_name: "a".repeat(200),
      preferred_name: "b".repeat(200),
      photo_url: "h".repeat(5000),
      free_recipe_cover_url: "https://example.com/a.jpg",
    };
    assert.deepEqual(userDocumentIssues(d), []);
  });

  const cases: [string, (d: Record<string, unknown>) => void, string[]][] = [
    ["email absent", (d) => delete d.email, [`adresse e-mail absente (email) : ${L}`]],
    ["email nul", (d) => (d.email = null), [`adresse e-mail absente (email) : ${L}`]],
    ["email non texte", (d) => (d.email = 3), [`adresse e-mail n'est pas un texte (email) : ${L}`]],
    [
      "display_name absent",
      (d) => delete d.display_name,
      [`nom Google absent (display_name) : ${L}`],
    ],
    [
      "display_name non texte",
      (d) => (d.display_name = 1),
      [`nom Google n'est pas un texte (display_name) : ${L}`],
    ],
    [
      "preferred_name non texte",
      (d) => (d.preferred_name = 2),
      [`nom préféré n'est pas un texte (preferred_name) : ${L}`],
    ],
    ["rôle absent", (d) => delete d.role, [`rôle absent (role) : ${R}`]],
    ["rôle nul", (d) => (d.role = null), [`rôle absent (role) : ${R}`]],
    ["rôle inconnu", (d) => (d.role = "superadmin"), [`rôle inconnu (role) « superadmin » : ${R}`]],
    ["rôle avec espace", (d) => (d.role = "admin "), [`rôle inconnu (role) « admin  » : ${R}`]],
    ["rôle en majuscule", (d) => (d.role = "Admin"), [`rôle inconnu (role) « Admin » : ${R}`]],
    ["rôle nombre", (d) => (d.role = 1), [`rôle inconnu (role) 1 : ${R}`]],
    [
      "rôle qui contient @ : masqué",
      (d) => (d.role = "marie@example.com"),
      [`rôle inconnu (role) (valeur masquée) : ${R}`],
    ],
    [
      "is_revoked absent",
      (d) => delete d.is_revoked,
      [`indicateur de révocation absent (is_revoked) : ${V}`],
    ],
    [
      "is_revoked texte",
      (d) => (d.is_revoked = "false"),
      [`indicateur de révocation n'est pas un booléen (is_revoked) « false » : ${L}`],
    ],
    [
      "is_revoked texte qui contient @ : masqué",
      (d) => (d.is_revoked = "a@b.fr"),
      [`indicateur de révocation n'est pas un booléen (is_revoked) (valeur masquée) : ${L}`],
    ],
    [
      "created_at absent",
      (d) => delete d.created_at,
      [`date de création absente (created_at) : ${L}`],
    ],
    [
      "created_at texte",
      (d) => (d.created_at = "2024-01-01"),
      [`date de création n'est pas une date (created_at) : ${L}`],
    ],
    [
      "created_at nombre",
      (d) => (d.created_at = 1700000000),
      [`date de création n'est pas une date (created_at) : ${L}`],
    ],
    [
      "last_seen_at absent",
      (d) => delete d.last_seen_at,
      [`date de dernière visite absente (last_seen_at) : ${L}`],
    ],
    [
      "last_seen_at texte",
      (d) => (d.last_seen_at = "x"),
      [`date de dernière visite n'est pas une date (last_seen_at) : ${L}`],
    ],
    [
      "photo_url non texte",
      (d) => (d.photo_url = 5),
      [`photo n'est pas un texte (photo_url) : ${L}`],
    ],
    [
      "couverture non texte",
      (d) => (d.free_recipe_cover_url = { url: "x" }),
      [`couverture « Recette libre » n'est pas un texte (free_recipe_cover_url) : ${L}`],
    ],
  ];
  for (const [name, mutate, expected] of cases) {
    test(name, () => {
      const d = valid();
      mutate(d);
      assert.deepEqual(userDocumentIssues(d), expected);
    });
  }

  test("plusieurs écarts : tous listés, dans l'ordre des champs", () => {
    const d = valid();
    delete d.created_at;
    d.role = "boss";
    assert.deepEqual(userDocumentIssues(d), [
      `rôle inconnu (role) « boss » : ${R}`,
      `date de création absente (created_at) : ${L}`,
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
  test("prénom qui contient @ : écarté", () => {
    assert.equal(
      userReviewLabel(ID, { preferred_name: "marie@example.com", display_name: "Marie K" }),
      "Marie (abcdef…)",
    );
    assert.equal(
      userReviewLabel(ID, { display_name: "marie@example.com Kassbi" }),
      "Compte abcdef…",
    );
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
    d.role = "boss";
    assert.equal(checkUserDocument(ID, d, review), false);
    assert.deepEqual(review.toJSON(), {
      items: [
        {
          kind: "account",
          id: ID,
          label: "Marie (abcdef…)",
          reason:
            "rôle inconnu (role) « boss » : compte sans droit, affiché « en attente » dans " +
            "Comptes ; indicateur de révocation absent (is_revoked) : toute règle qui lit la " +
            "révocation échoue pour ce compte",
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
