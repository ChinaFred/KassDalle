// Suggestions de repas : meal_suggestions/{id}.
//
// Un membre d'un groupe actif, autre que le propriétaire, lecteur compris,
// suggère un plat pour un jour du planning du groupe. Le propriétaire et
// l'auteur lisent la suggestion ; les autres membres non. Aucune mise à
// jour ; l'auteur ou le propriétaire la supprime.

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";
import { PERSONAS, as, createEnv, seedDocs, seedUsers } from "./helpers.mjs";

let env;

const { FieldValue } = firebase.firestore;
const db = (name) => as(env, name).firestore();

const READER = PERSONAS.reader.uid;
const OTHER = PERSONAS.otherReader.uid;
const EDITOR = PERSONAS.editor.uid;
const ADMIN = PERSONAS.admin.uid;
const STRANGER = PERSONAS.stranger.uid;

/// Une suggestion de recette de [author] au groupe `gp` (propriétaire : l'éditeur).
const recipeSuggestion = (author, extra = {}) => ({
  group_id: "gp",
  group_owner_id: EDITOR,
  author_uid: author,
  day: "2026-10-17",
  recipe_id: "r1",
  recipe_titre: "Lasagnes",
  note: "Pour l'anniversaire de Léo",
  created_at: FieldValue.serverTimestamp(),
  ...extra,
});

/// Une suggestion d'un nom libre.
const freeSuggestion = (author, extra = {}) => ({
  group_id: "gp",
  group_owner_id: EDITOR,
  author_uid: author,
  day: "2026-10-17",
  free_title: "Raclette",
  created_at: FieldValue.serverTimestamp(),
  ...extra,
});

before(async () => {
  env = await createEnv();
});

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await seedUsers(env);
  await seedDocs(env, {
    // `gp` : groupe actif de l'éditeur, le lecteur et l'administrateur y
    // sont membres, l'autre lecteur invité.
    "groups/gp": {
      name: "Famille Dupont",
      owner_id: EDITOR,
      member_ids: [EDITOR, READER, ADMIN],
      invited_ids: [OTHER],
    },
    // `gpause` : groupe en pause, son propriétaire (l'autre lecteur) n'est
    // plus éditeur.
    "groups/gpause": { name: "Cousins", owner_id: OTHER, member_ids: [OTHER, READER] },
    "planning_reach/editor": { uids: [], group_ids: ["gp"], masked_group_ids: [] },
    "planning_reach/reader": { uids: [], group_ids: ["gp"], masked_group_ids: ["gpause"] },
    "planning_reach/admin": { uids: [], group_ids: ["gp"], masked_group_ids: [] },
    "planning_reach/other-reader": { uids: [], group_ids: [], masked_group_ids: ["gpause"] },
    "meal_suggestions/s-reader": {
      group_id: "gp",
      group_owner_id: EDITOR,
      author_uid: READER,
      day: "2026-10-17",
      free_title: "Crêpes",
      created_at: new Date("2026-10-13T10:00:00Z"),
    },
  });
});

describe("meal_suggestions — création", () => {
  it("un membre lecteur suggère une recette ou un nom libre", async () => {
    await assertSucceeds(db("reader").doc("meal_suggestions/new1").set(recipeSuggestion(READER)));
    await assertSucceeds(db("reader").doc("meal_suggestions/new2").set(freeSuggestion(READER)));
  });

  it("un membre administrateur non propriétaire suggère aussi", async () => {
    await assertSucceeds(db("admin").doc("meal_suggestions/new").set(recipeSuggestion(ADMIN)));
  });

  it("sans mot : accepté", async () => {
    const data = recipeSuggestion(READER);
    delete data.note;
    await assertSucceeds(db("reader").doc("meal_suggestions/new").set(data));
  });

  it("le propriétaire ne se suggère rien", async () => {
    await assertFails(db("editor").doc("meal_suggestions/new").set(recipeSuggestion(EDITOR)));
  });

  it("un invité ne suggère rien", async () => {
    await assertFails(db("otherReader").doc("meal_suggestions/new").set(recipeSuggestion(OTHER)));
  });

  it("un compte hors du groupe ne suggère rien", async () => {
    await assertFails(db("stranger").doc("meal_suggestions/new").set(recipeSuggestion(STRANGER)));
  });

  it("groupe en pause : refusé", async () => {
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new")
        .set(recipeSuggestion(READER, { group_id: "gpause", group_owner_id: OTHER })),
    );
  });

  it("membre sorti du groupe, portée pas encore recalculée : refusé", async () => {
    await seedDocs(env, {
      "groups/gp": { name: "Famille Dupont", owner_id: EDITOR, member_ids: [EDITOR, ADMIN] },
    });
    await assertFails(db("reader").doc("meal_suggestions/new").set(recipeSuggestion(READER)));
  });

  it("group_owner_id faux : refusé", async () => {
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new")
        .set(recipeSuggestion(READER, { group_owner_id: ADMIN })),
    );
  });

  it("au nom d'un autre membre : refusé", async () => {
    await assertFails(db("reader").doc("meal_suggestions/new").set(recipeSuggestion(ADMIN)));
  });

  it("compte en attente ou révoqué : refusé", async () => {
    await assertFails(
      db("pending").doc("meal_suggestions/new").set(recipeSuggestion(PERSONAS.pending.uid)),
    );
    await assertFails(
      db("revokedStaleToken")
        .doc("meal_suggestions/new")
        .set(recipeSuggestion(PERSONAS.revokedStaleToken.uid)),
    );
  });

  it("groupe inexistant : refusé", async () => {
    await assertFails(
      db("reader").doc("meal_suggestions/new").set(recipeSuggestion(READER, { group_id: "absent" })),
    );
  });
});

describe("meal_suggestions — bornes", () => {
  it("un mot de 200 caractères passe, 201 non", async () => {
    await assertSucceeds(
      db("reader")
        .doc("meal_suggestions/new1")
        .set(recipeSuggestion(READER, { note: "a".repeat(200) })),
    );
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new2")
        .set(recipeSuggestion(READER, { note: "a".repeat(201) })),
    );
  });

  it("un nom libre de 60 caractères passe, 61 non, vide non", async () => {
    await assertSucceeds(
      db("reader")
        .doc("meal_suggestions/new1")
        .set(freeSuggestion(READER, { free_title: "a".repeat(60) })),
    );
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new2")
        .set(freeSuggestion(READER, { free_title: "a".repeat(61) })),
    );
    await assertFails(
      db("reader").doc("meal_suggestions/new3").set(freeSuggestion(READER, { free_title: "" })),
    );
  });

  it("un titre de recette de 201 caractères est refusé", async () => {
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new")
        .set(recipeSuggestion(READER, { recipe_titre: "a".repeat(201) })),
    );
  });

  it("recette ET nom libre, ou ni l'un ni l'autre : refusé", async () => {
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new1")
        .set(recipeSuggestion(READER, { free_title: "Raclette" })),
    );
    const neither = freeSuggestion(READER);
    delete neither.free_title;
    await assertFails(db("reader").doc("meal_suggestions/new2").set(neither));
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new3")
        .set(freeSuggestion(READER, { recipe_titre: "Raclette" })),
    );
  });

  it("recette sans titre copié : refusé", async () => {
    const data = recipeSuggestion(READER);
    delete data.recipe_titre;
    await assertFails(db("reader").doc("meal_suggestions/new").set(data));
  });

  it("jour mal formé : refusé", async () => {
    await assertFails(
      db("reader").doc("meal_suggestions/new1").set(recipeSuggestion(READER, { day: "17/10/2026" })),
    );
    await assertFails(
      db("reader").doc("meal_suggestions/new2").set(recipeSuggestion(READER, { day: 20261017 })),
    );
  });

  it("champ inconnu, ou date de création fournie par le client : refusé", async () => {
    await assertFails(
      db("reader").doc("meal_suggestions/new1").set(recipeSuggestion(READER, { status: "open" })),
    );
    await assertFails(
      db("reader")
        .doc("meal_suggestions/new2")
        .set(recipeSuggestion(READER, { created_at: new Date("2020-01-01T00:00:00Z") })),
    );
  });
});

describe("meal_suggestions — lecture", () => {
  it("l'auteur lit sa suggestion, et sa requête", async () => {
    await assertSucceeds(db("reader").doc("meal_suggestions/s-reader").get());
    await assertSucceeds(
      db("reader")
        .collection("meal_suggestions")
        .where("author_uid", "==", READER)
        .where("day", ">=", "2026-07-15")
        .orderBy("day")
        .get(),
    );
  });

  it("le propriétaire du groupe la lit, et sa requête", async () => {
    await assertSucceeds(db("editor").doc("meal_suggestions/s-reader").get());
    await assertSucceeds(
      db("editor")
        .collection("meal_suggestions")
        .where("group_owner_id", "==", EDITOR)
        .where("day", ">=", "2026-10-13")
        .orderBy("day")
        .get(),
    );
  });

  it("un autre membre ne la lit pas", async () => {
    await assertFails(db("admin").doc("meal_suggestions/s-reader").get());
    await assertFails(
      db("admin").collection("meal_suggestions").where("group_id", "==", "gp").get(),
    );
  });

  it("un invité ou un étranger ne la lit pas", async () => {
    await assertFails(db("otherReader").doc("meal_suggestions/s-reader").get());
    await assertFails(db("stranger").doc("meal_suggestions/s-reader").get());
  });

  it("une requête sans filtre sur l'auteur ou le propriétaire est refusée", async () => {
    await assertFails(db("reader").collection("meal_suggestions").get());
    await assertFails(
      db("editor").collection("meal_suggestions").where("group_id", "==", "gp").get(),
    );
  });
});

describe("meal_suggestions — modification et suppression", () => {
  it("aucune mise à jour, pas même par l'auteur", async () => {
    await assertFails(
      db("reader").doc("meal_suggestions/s-reader").update({ free_title: "Gaufres" }),
    );
    await assertFails(db("editor").doc("meal_suggestions/s-reader").update({ note: "ok" }));
  });

  it("un autre membre ne supprime pas", async () => {
    await assertFails(db("admin").doc("meal_suggestions/s-reader").delete());
    await assertFails(db("stranger").doc("meal_suggestions/s-reader").delete());
  });

  it("l'auteur supprime sa suggestion", async () => {
    await assertSucceeds(db("reader").doc("meal_suggestions/s-reader").delete());
  });

  it("le propriétaire du groupe supprime une suggestion reçue", async () => {
    await assertSucceeds(db("editor").doc("meal_suggestions/s-reader").delete());
  });
});
