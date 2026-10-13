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

/// Un jour `AAAA-MM-JJ` à [offset] jours d'aujourd'hui (UTC) : les règles
/// bornent le jour entre la veille et soixante jours après l'heure du serveur.
const dayIn = (offset) => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offset);
  return d.toISOString().slice(0, 10);
};
const DAY = dayIn(4);

/// L'identifiant imposé : `{group_id}_{auteur}_{day}_{n}`, n de 0 à 4.
const sid = (author, n = 0, { group = "gp", day = DAY } = {}) =>
  `meal_suggestions/${group}_${author}_${day}_${n}`;

/// Une suggestion de recette de [author] au groupe `gp` (propriétaire : l'éditeur).
const recipeSuggestion = (author, extra = {}) => ({
  group_id: "gp",
  group_owner_id: EDITOR,
  author_uid: author,
  day: DAY,
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
  day: DAY,
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
      day: DAY,
      free_title: "Crêpes",
      created_at: new Date("2026-10-13T10:00:00Z"),
    },
  });
});

describe("meal_suggestions — création", () => {
  it("un membre lecteur suggère une recette ou un nom libre", async () => {
    await assertSucceeds(db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER)));
    await assertSucceeds(db("reader").doc(sid(READER, 1)).set(freeSuggestion(READER)));
  });

  it("un membre administrateur non propriétaire suggère aussi", async () => {
    await assertSucceeds(db("admin").doc(sid(ADMIN, 0)).set(recipeSuggestion(ADMIN)));
  });

  it("sans mot : accepté", async () => {
    const data = recipeSuggestion(READER);
    delete data.note;
    await assertSucceeds(db("reader").doc(sid(READER, 0)).set(data));
  });

  it("le propriétaire ne se suggère rien", async () => {
    await assertFails(db("editor").doc(sid(EDITOR, 0)).set(recipeSuggestion(EDITOR)));
  });

  it("un invité ne suggère rien", async () => {
    await assertFails(db("otherReader").doc(sid(OTHER, 0)).set(recipeSuggestion(OTHER)));
  });

  it("un compte hors du groupe ne suggère rien", async () => {
    await assertFails(db("stranger").doc(sid(STRANGER, 0)).set(recipeSuggestion(STRANGER)));
  });

  it("groupe en pause : refusé", async () => {
    await assertFails(
      db("reader")
        .doc(sid(READER, 0, { group: "gpause" }))
        .set(recipeSuggestion(READER, { group_id: "gpause", group_owner_id: OTHER })),
    );
  });

  it("membre sorti du groupe, portée pas encore recalculée : refusé", async () => {
    await seedDocs(env, {
      "groups/gp": { name: "Famille Dupont", owner_id: EDITOR, member_ids: [EDITOR, ADMIN] },
    });
    await assertFails(db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER)));
  });

  it("group_owner_id faux : refusé", async () => {
    await assertFails(
      db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER, { group_owner_id: ADMIN })),
    );
  });

  it("au nom d'un autre membre : refusé", async () => {
    await assertFails(db("reader").doc(sid(ADMIN, 0)).set(recipeSuggestion(ADMIN)));
    await assertFails(db("reader").doc(sid(READER, 0)).set(recipeSuggestion(ADMIN)));
  });

  it("compte en attente ou révoqué : refusé", async () => {
    const pending = PERSONAS.pending.uid;
    const stale = PERSONAS.revokedStaleToken.uid;
    await assertFails(db("pending").doc(sid(pending, 0)).set(recipeSuggestion(pending)));
    await assertFails(
      db("revokedStaleToken").doc(sid(stale, 0)).set(recipeSuggestion(stale)),
    );
  });

  it("groupe inexistant : refusé", async () => {
    await assertFails(
      db("reader")
        .doc(sid(READER, 0, { group: "absent" }))
        .set(recipeSuggestion(READER, { group_id: "absent" })),
    );
  });
});

describe("meal_suggestions — identifiant imposé et plafond", () => {
  it("_0 à _4 acceptés, une sixième refusée", async () => {
    for (let n = 0; n < 5; n++) {
      await assertSucceeds(
        db("reader").doc(sid(READER, n)).set(freeSuggestion(READER, { free_title: `Plat ${n}` })),
      );
    }
    await assertFails(db("reader").doc(sid(READER, 5)).set(freeSuggestion(READER)));
    // Réécrire un identifiant pris est une mise à jour : refusée.
    await assertFails(db("reader").doc(sid(READER, 0)).set(freeSuggestion(READER)));
  });

  it("identifiant libre, ou d'un autre jour, groupe ou auteur : refusé", async () => {
    await assertFails(db("reader").doc("meal_suggestions/libre").set(freeSuggestion(READER)));
    await assertFails(
      db("reader").doc(sid(READER, 0, { day: dayIn(5) })).set(freeSuggestion(READER)),
    );
    await assertFails(
      db("reader").doc(sid(READER, 0, { group: "gpause" })).set(freeSuggestion(READER)),
    );
    await assertFails(db("reader").doc(sid(ADMIN, 0)).set(freeSuggestion(READER)));
  });

  it("retirer libère l'identifiant : la suggestion se remet", async () => {
    await assertSucceeds(db("reader").doc(sid(READER, 0)).set(freeSuggestion(READER)));
    await assertSucceeds(db("reader").doc(sid(READER, 0)).delete());
    await assertSucceeds(db("reader").doc(sid(READER, 0)).set(freeSuggestion(READER)));
  });
});

describe("meal_suggestions — bornes", () => {
  it("un mot de 200 caractères passe, 201 non", async () => {
    await assertSucceeds(
      db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER, { note: "a".repeat(200) })),
    );
    await assertFails(
      db("reader").doc(sid(READER, 1)).set(recipeSuggestion(READER, { note: "a".repeat(201) })),
    );
  });

  it("un nom libre de 60 caractères passe, 61 non, vide non", async () => {
    await assertSucceeds(
      db("reader").doc(sid(READER, 0)).set(freeSuggestion(READER, { free_title: "a".repeat(60) })),
    );
    await assertFails(
      db("reader").doc(sid(READER, 1)).set(freeSuggestion(READER, { free_title: "a".repeat(61) })),
    );
    await assertFails(db("reader").doc(sid(READER, 2)).set(freeSuggestion(READER, { free_title: "" })));
  });

  it("un titre de recette de 201 caractères est refusé", async () => {
    await assertFails(
      db("reader")
        .doc(sid(READER, 0))
        .set(recipeSuggestion(READER, { recipe_titre: "a".repeat(201) })),
    );
  });

  it("recette ET nom libre, ou ni l'un ni l'autre : refusé", async () => {
    await assertFails(
      db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER, { free_title: "Raclette" })),
    );
    const neither = freeSuggestion(READER);
    delete neither.free_title;
    await assertFails(db("reader").doc(sid(READER, 1)).set(neither));
    await assertFails(
      db("reader").doc(sid(READER, 2)).set(freeSuggestion(READER, { recipe_titre: "Raclette" })),
    );
  });

  it("recette sans titre copié : refusé", async () => {
    const data = recipeSuggestion(READER);
    delete data.recipe_titre;
    await assertFails(db("reader").doc(sid(READER, 0)).set(data));
  });

  it("jour mal formé, impossible ou hors bornes : refusé", async () => {
    const at = (day) => db("reader").doc(sid(READER, 0, { day })).set(freeSuggestion(READER, { day }));
    await assertFails(at("17/10/2026"));
    await assertFails(at("9999-12-31"));
    await assertFails(at("2026-13-45"));
    await assertFails(at(`${dayIn(30).slice(0, 4)}-02-30`));
    await assertFails(at(dayIn(-3)));
    await assertFails(at(dayIn(62)));
    await assertFails(
      db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER, { day: 20261017 })),
    );
  });

  it("jour : la veille, aujourd'hui et J+59 acceptés", async () => {
    const at = (day) => db("reader").doc(sid(READER, 0, { day })).set(freeSuggestion(READER, { day }));
    await assertSucceeds(at(dayIn(-1)));
    await assertSucceeds(at(dayIn(0)));
    await assertSucceeds(at(dayIn(59)));
  });

  it("champ inconnu, ou date de création fournie par le client : refusé", async () => {
    await assertFails(
      db("reader").doc(sid(READER, 0)).set(recipeSuggestion(READER, { status: "open" })),
    );
    await assertFails(
      db("reader")
        .doc(sid(READER, 1))
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
        .where("day", ">=", dayIn(-90))
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
        .where("day", ">=", dayIn(0))
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
