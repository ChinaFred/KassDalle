/**
 * Gardes des callables — le sas d'entrée, la révocation et le rôle.
 *
 * Ces vingt-sept entrées HTTPS dépensent de l'argent : chacune part chez Gemini
 * ou Anthropic. Elles n'étaient gardées que par la présence d'un compte Google,
 * si bien qu'un compte en attente d'approbation, ou un compte révoqué, les
 * atteignait aussi bien qu'un membre de la famille.
 *
 * La décision est portée par `accessDenial`, pure et donc testable sans
 * émulateur : c'est elle que ce fichier verrouille, avec la lecture des claims
 * et la règle du compte fondateur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { accessDenial, accountFromToken, mergeAccount, type AccountState } from "../callable/_auth";
import { claimsFrom, shouldRevokeSessions } from "../triggers/userClaimsSync";
import { founderRepair, isFounderAccount, isFounderEmail } from "../triggers/founderRole";
import {
  APP_CHECK_MODES,
  DEFAULT_APP_CHECK_POLICY,
  appCheckVerdict,
  isAppCheckExempt,
  isAppCheckMode,
} from "../security/appCheckPolicy";

function account(role: string | null, revoked = false): AccountState {
  return { role, revoked };
}

describe("accessDenial — sas d'entrée", () => {
  test("un compte en attente est refusé partout", () => {
    for (const need of ["approved", "editor", "admin"] as const) {
      assert.notEqual(accessDenial(account("pending"), need), null, `need=${need}`);
    }
  });

  test("un compte sans rôle du tout est refusé — le repli ferme", () => {
    assert.notEqual(accessDenial(account(null), "approved"), null);
  });

  test("un rôle inconnu ne vaut pas lecteur", () => {
    assert.notEqual(accessDenial(account("superadmin"), "approved"), null);
  });

  test("un lecteur passe le sas mais n'écrit pas", () => {
    assert.equal(accessDenial(account("reader"), "approved"), null);
    assert.notEqual(accessDenial(account("reader"), "editor"), null);
    assert.notEqual(accessDenial(account("reader"), "admin"), null);
  });

  test("un éditeur écrit sans être administrateur", () => {
    assert.equal(accessDenial(account("editor"), "approved"), null);
    assert.equal(accessDenial(account("editor"), "editor"), null);
    assert.notEqual(accessDenial(account("editor"), "admin"), null);
  });

  test("un administrateur passe les trois portes", () => {
    for (const need of ["approved", "editor", "admin"] as const) {
      assert.equal(accessDenial(account("admin"), need), null, `need=${need}`);
    }
  });
});

describe("accessDenial — révocation", () => {
  test("la révocation mord sur tous les rôles, administrateur compris", () => {
    for (const role of ["reader", "editor", "admin"]) {
      for (const need of ["approved", "editor", "admin"] as const) {
        assert.notEqual(accessDenial(account(role, true), need), null, `role=${role} need=${need}`);
      }
    }
  });

  test("le message de révocation ne se confond pas avec celui de l'attente", () => {
    const revoked = accessDenial(account("admin", true), "approved");
    const pending = accessDenial(account("pending"), "approved");
    assert.notEqual(revoked, null);
    assert.notEqual(pending, null);
    assert.notEqual(revoked?.message, pending?.message);
  });
});

describe("accountFromToken", () => {
  test("un jeton sans claim de rôle rend null, pas une chaîne vide", () => {
    assert.deepEqual(accountFromToken({ auth: { uid: "u1", token: {} } } as never), {
      role: null,
      revoked: false,
    });
  });

  test("un claim vide ou blanc vaut absent", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { role: "  " } } } as never).role,
      null,
    );
  });

  test("le claim de révocation n'est vrai que s'il vaut exactement true", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { revoked: "true" } } } as never).revoked,
      false,
    );
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { revoked: true } } } as never).revoked,
      true,
    );
  });

  test("un rôle porté par le jeton est lu tel quel, espaces retirés", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { role: " editor " } } } as never).role,
      "editor",
    );
  });
});

describe("App Check — attestation de l'application", () => {
  test("un appel attesté passe dans les trois modes", () => {
    for (const mode of APP_CHECK_MODES) {
      assert.deepEqual(appCheckVerdict(mode, true), { action: "allow" }, `mode=${mode}`);
    }
  });

  test("mode off : un appel non attesté passe sans laisser de trace", () => {
    assert.deepEqual(appCheckVerdict("off", false), { action: "allow" });
  });

  test("mode monitor : un appel non attesté passe, mais est observé", () => {
    assert.deepEqual(appCheckVerdict("monitor", false), { action: "observe" });
  });

  test("mode enforce : un appel non attesté est refusé, avec un motif", () => {
    const verdict = appCheckVerdict("enforce", false);
    assert.equal(verdict.action, "deny");
    assert.match(verdict.action === "deny" ? verdict.message : "", /attest/i);
  });

  test("le mode par défaut observe et ne refuse rien", () => {
    // Un déploiement qui se mettrait à refuser sans que personne l'ait demandé
    // serait une panne, pas une sécurisation.
    assert.equal(DEFAULT_APP_CHECK_POLICY.mode, "monitor");
    assert.deepEqual(appCheckVerdict(DEFAULT_APP_CHECK_POLICY.mode, false), {
      action: "observe",
    });
  });

  test("en mode enforce, le pilotage de la politique reste joignable", () => {
    // Un interrupteur d'arrêt ne doit pas dépendre de ce qu'il coupe : sans
    // cette exemption, un refus à tort rendrait `enforce` définitif — plus
    // aucun client ne pourrait rouvrir.
    assert.deepEqual(appCheckVerdict("enforce", false, "app_check_policy"), {
      action: "observe",
    });
    assert.equal(isAppCheckExempt("app_check_policy"), true);
  });

  test("l'exemption ne déborde sur aucun autre poste", () => {
    for (const feature of ["generate", "plating_image", "app_check", "", "app_check_policy_x"]) {
      assert.equal(isAppCheckExempt(feature), false, feature);
      assert.equal(appCheckVerdict("enforce", false, feature).action, "deny", feature);
    }
  });

  test("un mode inconnu n'est pas accepté", () => {
    assert.equal(isAppCheckMode("enforced"), false);
    assert.equal(isAppCheckMode(""), false);
    assert.equal(isAppCheckMode(true), false);
    assert.equal(isAppCheckMode("enforce"), true);
  });
});

describe("postes qui produisent une image", () => {
  // Les trois postes qui *fabriquent* une image coûtent 0,0336 $ l'appel. Ils
  // doivent exiger au moins le rôle éditeur : la génération d'illustration s'en
  // contentait d'un compte connecté, alors que le visuel de dressage l'exigeait
  // déjà et que l'amélioration de photo est réservée aux administrateurs.
  test("un lecteur ne peut déclencher aucun poste image", () => {
    assert.notEqual(accessDenial(account("reader"), "editor"), null);
    assert.notEqual(accessDenial(account("reader"), "admin"), null);
  });

  test("un éditeur les déclenche, sauf celui réservé aux administrateurs", () => {
    assert.equal(accessDenial(account("editor"), "editor"), null);
    assert.notEqual(accessDenial(account("editor"), "admin"), null);
  });
});

describe("compte fondateur", () => {
  test("l'adresse se reconnaît quelle que soit la casse", () => {
    assert.equal(isFounderEmail("china.fred.75@gmail.com"), true);
    assert.equal(isFounderEmail("CHINA.FRED.75@Gmail.com"), true);
    assert.equal(isFounderEmail("  china.fred.75@gmail.com  "), true);
  });

  test("une adresse voisine n'est pas le fondateur", () => {
    assert.equal(isFounderEmail("china.fred.75@gmail.com.attaquant.fr"), false);
    assert.equal(isFounderEmail("chinafred75@gmail.com"), false);
    assert.equal(isFounderEmail(null), false);
    assert.equal(isFounderEmail(undefined), false);
  });

  test("compte fondateur : adresse vérifiée et connexion Google, les trois ensemble", () => {
    const google = [{ providerId: "google.com" }];
    const email = "china.fred.75@gmail.com";
    assert.equal(isFounderAccount({ email, emailVerified: true, providerData: google }), true);
    // Adresse du fondateur, non vérifiée : refusé.
    assert.equal(isFounderAccount({ email, emailVerified: false, providerData: google }), false);
    assert.equal(isFounderAccount({ email, providerData: google }), false);
    // Adresse vérifiée, mais pas de connexion Google : refusé.
    assert.equal(
      isFounderAccount({ email, emailVerified: true, providerData: [{ providerId: "password" }] }),
      false,
    );
    assert.equal(isFounderAccount({ email, emailVerified: true }), false);
    // Autre adresse : refusé.
    assert.equal(
      isFounderAccount({ email: "autre@gmail.com", emailVerified: true, providerData: google }),
      false,
    );
    assert.equal(isFounderAccount(null), false);
  });

  test("un fondateur déjà administrateur et actif n'est pas réécrit", () => {
    assert.equal(founderRepair({ role: "admin", is_revoked: false }), null);
    assert.equal(founderRepair({ role: "admin" }), null);
  });

  test("un fondateur rabaissé ou révoqué est rétabli", () => {
    assert.deepEqual(founderRepair({ role: "pending", is_revoked: false }), {
      role: "admin",
      is_revoked: false,
    });
    assert.deepEqual(founderRepair({ role: "admin", is_revoked: true }), {
      role: "admin",
      is_revoked: false,
    });
  });
});

describe("mergeAccount — le document relu à chaque appel fait foi", () => {
  test("un jeton d'avant la révocation ne passe plus", () => {
    const merged = mergeAccount(account("reader"), account("reader", true));
    assert.equal(merged.revoked, true);
    assert.notEqual(accessDenial(merged, "approved"), null);
  });

  test("le jeton confirme une révocation, le document ne l'infirme pas", () => {
    assert.equal(mergeAccount(account("reader", true), account("reader")).revoked, true);
  });

  test("le rôle du document prime, celui du jeton sert de repli", () => {
    assert.equal(mergeAccount(account("editor"), account("reader")).role, "reader");
    assert.equal(mergeAccount(account("reader"), account(null)).role, "reader");
  });

  test("un compte remis en attente est refusé malgré son jeton", () => {
    const merged = mergeAccount(account("editor"), account("pending"));
    assert.notEqual(accessDenial(merged, "approved"), null);
  });

  test("un compte sans document est refusé malgré son jeton", () => {
    const merged = mergeAccount(account("admin"), null);
    assert.equal(merged.role, null);
    assert.notEqual(accessDenial(merged, "approved"), null);
  });
});

describe("syncUserClaims — sessions coupées quand le compte perd l'accès", () => {
  const reader = claimsFrom({ role: "reader", is_revoked: false });
  const revoked = claimsFrom({ role: "reader", is_revoked: true });
  const pending = claimsFrom({ role: "pending", is_revoked: false });
  const editor = claimsFrom({ role: "editor", is_revoked: false });

  test("passage à révoqué", () => {
    assert.equal(shouldRevokeSessions(reader, revoked, true), true);
    assert.equal(shouldRevokeSessions(revoked, revoked, true), false);
    assert.equal(shouldRevokeSessions(revoked, reader, true), false);
  });

  test("rôle qui sort de reader/editor/admin", () => {
    assert.equal(shouldRevokeSessions(reader, pending, true), true);
    assert.equal(shouldRevokeSessions(editor, claimsFrom({ is_revoked: false }), true), true);
  });

  test("changement de rôle entre rôles nommés, ou nomination : sessions gardées", () => {
    assert.equal(shouldRevokeSessions(editor, reader, true), false);
    assert.equal(shouldRevokeSessions(pending, reader, true), false);
  });

  test("document supprimé d'un compte nommé ou révoqué", () => {
    assert.equal(shouldRevokeSessions(reader, claimsFrom(undefined), false), true);
    assert.equal(shouldRevokeSessions(revoked, claimsFrom(undefined), false), true);
    assert.equal(shouldRevokeSessions(pending, claimsFrom(undefined), false), false);
  });

  test("un document neuf déjà révoqué", () => {
    assert.equal(shouldRevokeSessions(claimsFrom(undefined), revoked, true), true);
  });
});
