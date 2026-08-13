/**
 * Clés d'agrégat de consommation.
 *
 * Une clé de map Firestore refusée fait échouer l'écriture entière : ce n'est
 * pas une ligne qui manque au reporting, c'est le mois. Et la période décide de
 * quel document reçoit l'appel — un décalage de fuseau ferait basculer les
 * appels de fin de mois dans le mauvais bilan.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { sanitizeMapKey, usagePeriod } from "../ai/usage";

describe("usagePeriod", () => {
  test("rend le mois en UTC, sur deux chiffres", () => {
    assert.equal(usagePeriod(new Date("2026-08-13T16:05:00Z")), "2026-08");
    assert.equal(usagePeriod(new Date("2026-01-01T00:00:00Z")), "2026-01");
  });

  test("le dernier instant du mois appartient encore à ce mois", () => {
    assert.equal(usagePeriod(new Date("2026-08-31T23:59:59Z")), "2026-08");
  });

  test("le premier instant du mois suivant a basculé", () => {
    assert.equal(usagePeriod(new Date("2026-09-01T00:00:00Z")), "2026-09");
  });

  test("une heure locale tardive ne change pas la période UTC", () => {
    // 31 août 23 h à Paris, c'est le 31 août 21 h UTC : même mois. Le piège
    // serait l'inverse — un fuseau qui ferait compter un appel dans le mois
    // suivant, et donc un total mensuel qui ne se recoupe jamais.
    assert.equal(usagePeriod(new Date("2026-08-31T21:00:00Z")), "2026-08");
  });
});

describe("sanitizeMapKey", () => {
  test("les identifiants de modèle courants passent inchangés", () => {
    assert.equal(sanitizeMapKey("gemini-2.5-flash"), "gemini-2_5-flash");
    assert.equal(sanitizeMapKey("claude-sonnet-5"), "claude-sonnet-5");
    assert.equal(sanitizeMapKey("plating_coach"), "plating_coach");
  });

  test("les caractères interdits par Firestore sont remplacés", () => {
    // `.` `/` `[` `]` `~` `*` `#` sont refusés dans un chemin de champ.
    assert.equal(sanitizeMapKey("a.b/c[d]e~f*g#h"), "a_b_c_d_e_f_g_h");
  });

  test("une clé vide reçoit un nom plutôt que de faire échouer l'écriture", () => {
    assert.equal(sanitizeMapKey(""), "inconnu");
    assert.equal(sanitizeMapKey("   "), "inconnu");
  });
});
