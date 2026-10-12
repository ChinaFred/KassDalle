/**
 * Profil public d'un compte : ce que `user_profiles/{uid}` recopie de
 * `users/{uid}`, et quand il ne faut rien écrire. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  MAX_COVER_URL_LENGTH,
  MAX_NAME_LENGTH,
  publicCoverUrl,
  publicProfileFrom,
  sameProfile,
  truncateName,
} from "../triggers/userPublicProfile";

/** Adresse produite par la modération (`getDownloadURL` sur `users/{uid}/…`). */
const COVER =
  "https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/" +
  "users%2Fu1%2Ffree_recipe_cover_1760000000000.jpg?alt=media&token=abc-123";

describe("publicProfileFrom", () => {
  test("ne recopie que les champs publics", () => {
    const profile = publicProfileFrom(
      {
        uid: "u1",
        email: "marie@example.com",
        role: "editor",
        is_revoked: false,
        display_name: "Marie Kassbi",
        preferred_name: "Marie",
        photo_url: "https://example.com/p.jpg",
        free_recipe_cover_url: COVER,
        created_at: 1,
        last_seen_at: 2,
      },
      "u1",
    );
    assert.deepEqual(profile, {
      display_name: "Marie Kassbi",
      preferred_name: "Marie",
      free_recipe_cover_url: COVER,
    });
    assert.equal(JSON.stringify(profile).includes("@"), false);
  });

  test("un compte en attente, sans rôle ou supprimé n'a pas de profil", () => {
    assert.equal(publicProfileFrom({ role: "pending", display_name: "X" }, "u1"), null);
    assert.equal(publicProfileFrom({ display_name: "X" }, "u1"), null);
    assert.equal(publicProfileFrom({ role: "superadmin", display_name: "X" }, "u1"), null);
    assert.equal(publicProfileFrom(undefined, "u1"), null);
  });

  test("un compte révoqué garde son profil", () => {
    assert.deepEqual(
      publicProfileFrom({ role: "reader", is_revoked: true, display_name: "Lu" }, "u1"),
      {
        display_name: "Lu",
        preferred_name: null,
        free_recipe_cover_url: null,
      },
    );
  });

  test("champs mal formés : chaîne vide ou null, jamais d'exception", () => {
    assert.deepEqual(
      publicProfileFrom(
        {
          role: "reader",
          display_name: 42,
          preferred_name: "   ",
          free_recipe_cover_url: false,
        },
        "u1",
      ),
      { display_name: "", preferred_name: null, free_recipe_cover_url: null },
    );
  });

  test("un nom de plus de 60 caractères est tronqué", () => {
    const long = "a".repeat(80);
    const profile = publicProfileFrom(
      { role: "reader", display_name: long, preferred_name: long },
      "u1",
    );
    assert.equal(profile?.display_name, "a".repeat(MAX_NAME_LENGTH));
    assert.equal(profile?.preferred_name, "a".repeat(MAX_NAME_LENGTH));
  });
});

describe("truncateName", () => {
  test("60 caractères passent tels quels", () => {
    const name = "é".repeat(60);
    assert.equal(truncateName(name), name);
  });

  test("ne coupe pas un caractère hors du plan de base en deux", () => {
    // Un emoji vaut 2 unités UTF-16, comme dans les règles : 30 emoji au plus.
    assert.equal(truncateName("😀".repeat(61)), "😀".repeat(30));
    // Une coupe qui tomberait au milieu d'une paire recule d'une unité.
    assert.equal(truncateName("a" + "😀".repeat(40)), "a" + "😀".repeat(29));
  });
});

describe("sameProfile", () => {
  const expected = { display_name: "Marie", preferred_name: null, free_recipe_cover_url: null };

  test("un profil absent diffère", () => {
    assert.equal(sameProfile(undefined, expected), false);
  });

  test("updated_at ne compte pas, un champ absent vaut null", () => {
    assert.equal(sameProfile({ display_name: "Marie", updated_at: 123 }, expected), true);
  });

  test("un nom préféré changé diffère", () => {
    assert.equal(sameProfile({ display_name: "Marie", preferred_name: "Mimi" }, expected), false);
  });
});

// Audit sécurité : le titulaire écrivait librement une adresse externe,
// recopiée dans le profil lu par toute la famille, sans modération.
describe("publicCoverUrl", () => {
  test("une adresse de couverture modérée passe", () => {
    assert.equal(publicCoverUrl(COVER, "u1"), COVER);
    const appspot = COVER.replace(
      "kassdale-6d948.firebasestorage.app",
      "kassdale-6d948.appspot.com",
    );
    assert.equal(publicCoverUrl(appspot, "u1"), appspot);
  });

  test("une adresse externe, un autre bucket ou un autre dossier sont écartés", () => {
    assert.equal(publicCoverUrl("https://exemple.org/x.png", "u1"), null);
    assert.equal(publicCoverUrl(COVER.replace("kassdale-6d948", "autre-projet"), "u1"), null);
    assert.equal(publicCoverUrl(COVER.replace("users%2F", "quarantine%2F"), "u1"), null);
    assert.equal(publicCoverUrl(COVER.replace("https://", "http://"), "u1"), null);
  });

  test("un chemin qui sort de users/{uid}/ est écarté : .., %2E, %25, autre compte", () => {
    const base =
      "https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/";
    for (const path of [
      "users%2F..%2Fquarantine%2Fu1%2Fx.jpg",
      "users%2F%2E%2E%2Fquarantine%2Fu1%2Fx.jpg",
      "users%2Fu1%2F..%2F..%2Fquarantine%2Fu1%2Ffree_recipe_cover_1.jpg",
      "users%2Fu1%2Ffree_recipe_cover_1.jpg%2F..%2Fx",
      "users%2Fu1%2Ffree_recipe_cover_1%252Ejpg",
      "users%2Fautre%2Ffree_recipe_cover_1.jpg",
      "users%2Fu1%2Fautre_1.jpg",
    ]) {
      assert.equal(publicCoverUrl(base + path + "?alt=media&token=t", "u1"), null, path);
    }
    assert.equal(publicCoverUrl(COVER, "u.1"), null);
  });

  test("au-delà de 500 caractères, ou d'un autre type : null", () => {
    assert.equal(publicCoverUrl(COVER + "x".repeat(MAX_COVER_URL_LENGTH), "u1"), null);
    assert.equal(publicCoverUrl(42, "u1"), null);
    assert.equal(publicCoverUrl(null, "u1"), null);
  });
});
