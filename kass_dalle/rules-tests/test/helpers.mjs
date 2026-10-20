// Outillage commun aux tests des règles Firestore et Storage.
//
// Les règles testées sont celles du dépôt, lues sur disque
// (kass_dalle/firestore.rules, kass_dalle/storage.rules) : un test ne passe
// que contre les règles qui partiront en production.
//
// Projet `demo-kassdalle` : le préfixe `demo-` interdit à l'émulateur et au
// SDK tout appel vers un vrai projet. Rien ne peut toucher kassdale-6d948.

import { readFileSync } from "node:fs";
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";

export const PROJECT_ID = "demo-kassdalle";

/// Le compte fondateur, tel que `founderEmail()` le reconnaît.
export const FOUNDER_EMAIL = "china.fred.75@gmail.com";

/// Convention des failles encore ouvertes : le test décrit le comportement
/// CORRIGÉ et porte cette option. Sous node:test, un `todo` qui échoue ne fait
/// pas échouer la suite. La correction de la faille retire l'option.
export const OPEN_FLAW = { todo: "faille ouverte, audit 2026-10-09" };

const rulesPath = (name) => new URL(`../../${name}`, import.meta.url);

/// Les comptes de test. `claims` reprend ce que `syncUserClaims` frappe dans
/// le jeton (`role`, `revoked`) plus l'adresse ; `doc` reprend `users/{uid}`,
/// que les règles Firestore relisent pour la révocation et pour le rôle (le
/// claim ne sert que si le document n'a pas de rôle, depuis v0.24.29).
export const PERSONAS = {
  // Jeton d'une connexion Google à l'adresse vérifiée : `isFounder()` exige
  // `email_verified` et `firebase.sign_in_provider == 'google.com'`.
  founder: {
    uid: "founder",
    claims: {
      role: "admin",
      revoked: false,
      email: FOUNDER_EMAIL,
      email_verified: true,
      firebase: { sign_in_provider: "google.com" },
    },
    doc: { role: "admin", is_revoked: false, email: FOUNDER_EMAIL },
  },
  admin: {
    uid: "admin",
    claims: { role: "admin", revoked: false, email: "admin@example.com" },
    doc: { role: "admin", is_revoked: false, email: "admin@example.com" },
  },
  editor: {
    uid: "editor",
    claims: { role: "editor", revoked: false, email: "editor@example.com" },
    doc: { role: "editor", is_revoked: false, email: "editor@example.com" },
  },
  reader: {
    uid: "reader",
    claims: { role: "reader", revoked: false, email: "reader@example.com" },
    doc: { role: "reader", is_revoked: false, email: "reader@example.com" },
  },
  otherReader: {
    uid: "other-reader",
    claims: { role: "reader", revoked: false, email: "other@example.com" },
    doc: { role: "reader", is_revoked: false, email: "other@example.com" },
  },
  pending: {
    uid: "pending",
    claims: { role: "pending", revoked: false, email: "pending@example.com" },
    doc: { role: "pending", is_revoked: false, email: "pending@example.com" },
  },
  // Révoqué, et le jeton le sait déjà.
  revoked: {
    uid: "revoked",
    claims: { role: "editor", revoked: true, email: "revoked@example.com" },
    doc: { role: "editor", is_revoked: true, email: "revoked@example.com" },
  },
  // Révoqué à l'instant : le jeton dit encore `revoked: false`, seul le
  // document le sait. Firestore doit couper tout de suite.
  revokedStaleToken: {
    uid: "revoked-stale",
    claims: { role: "editor", revoked: false, email: "stale@example.com" },
    doc: { role: "editor", is_revoked: true, email: "stale@example.com" },
  },
  // Compte nommé qui ne partage aucun groupe avec les autres personas.
  stranger: {
    uid: "stranger",
    claims: { role: "editor", revoked: false, email: "stranger@example.com" },
    doc: { role: "editor", is_revoked: false, email: "stranger@example.com" },
  },
  // Administrateur rétrogradé à l'instant : le jeton porte encore le claim
  // `admin`, le document dit `editor`. Firestore suit le document (#162).
  demotedAdmin: {
    uid: "demoted-admin",
    claims: { role: "admin", revoked: false, email: "demoted@example.com" },
    doc: { role: "editor", is_revoked: false, email: "demoted@example.com" },
  },
  // Compte nommé à l'instant : le jeton dit encore `pending`, le document
  // `reader`. Firestore lui ouvre la bibliothèque sans attendre le jeton.
  promotedReader: {
    uid: "promoted-reader",
    claims: { role: "pending", revoked: false, email: "promoted@example.com" },
    doc: { role: "reader", is_revoked: false, email: "promoted@example.com" },
  },
  // Compte approuvé dont le jeton ne porte pas encore le claim de rôle :
  // Firestore se replie sur le document.
  readerNoClaim: {
    uid: "reader-no-claim",
    claims: { email: "noclaim@example.com" },
    doc: { role: "reader", is_revoked: false, email: "noclaim@example.com" },
  },
};

export async function createEnv() {
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: readFileSync(rulesPath("firestore.rules"), "utf8") },
    storage: { rules: readFileSync(rulesPath("storage.rules"), "utf8") },
  });
}

/// Contexte authentifié d'un persona ; `anonymous` rend un contexte sans jeton.
export function as(env, name) {
  if (name === "anonymous") return env.unauthenticatedContext();
  const p = PERSONAS[name];
  if (!p) throw new Error(`persona inconnu : ${name}`);
  return env.authenticatedContext(p.uid, p.claims);
}

/// Écrit les documents `users/{uid}` de tous les personas, règles désactivées.
export async function seedUsers(env) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const p of Object.values(PERSONAS)) {
      await db.doc(`users/${p.uid}`).set(p.doc);
    }
  });
}

/// Écrit des documents arbitraires, règles désactivées : `{ "chemin": data }`.
export async function seedDocs(env, docs) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [path, data] of Object.entries(docs)) {
      await db.doc(path).set(data);
    }
  });
}

/// Clé du compteur mensuel de `app_config/usage`, comme `currentScansKey()`.
export function currentScansKey(now = new Date()) {
  const m = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `scans_${now.getUTCFullYear()}_${m}`;
}
