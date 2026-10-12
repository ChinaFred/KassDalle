/**
 * Recherche d'un membre à inviter dans un groupe, par son adresse exacte.
 *
 * `findMemberByEmailFn({ groupId, email })` rend `{ found: false }` ou
 * `{ found: true, uid, displayName, preferredName }`. Les deux noms sont ceux
 * de `user_profiles/{uid}`, déjà lisibles par tout compte approuvé ; l'adresse
 * ne repart jamais.
 *
 * Ce que le serveur vérifie :
 *  - un compte connecté, approuvé, non révoqué, attestation App Check
 *    (`requireAuth`) ;
 *  - l'appelant est **propriétaire** du groupe (`searcherDenial`) ;
 *  - l'adresse a une forme valide (`cleanEmail`), sinon `invalid-argument` ;
 *  - dix recherches par compte et par jour UTC (`member_email_search_daily`),
 *    sinon `resource-exhausted`. Le plafond borne l'essai d'adresses en série.
 *
 * Écart assumé : par devinette bornée (dix essais par jour), un propriétaire
 * qui connaît le nom d'un compte peut confirmer son adresse. Cinq réponses
 * « aucun compte » dans la journée font partir un avertissement
 * (`logWarn`), visible dans Admin › Logs.
 *
 * Les journaux ne portent jamais l'adresse cherchée. L'identifiant de groupe
 * n'apparaît dans un message qu'une fois le groupe confirmé ; avant, il n'est
 * porté que tronqué, en `firestoreDocId`.
 *
 * Aucun appel de modèle : pas de poste d'IA.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_GROUPS,
  COLL_MEMBER_EMAIL_SEARCH_DAILY,
  COLL_USERS,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireAuth } from "./_auth";
import { spendDay } from "../ai/budget";
import { logError, logInfo, logWarn } from "../logging";
import { cleanEmail } from "../invitations/rules";
import {
  MEMBER_EMAIL_SEARCH_DAILY_LIMIT,
  MEMBER_EMAIL_SEARCH_LIMIT_MESSAGE,
  MEMBER_EMAIL_SEARCH_MISS_ALERT,
  findAccountByEmail,
  readGroupId,
  searchCounterExpiry,
  searcherDenial,
  shouldWarnMisses,
  unverifiedGroupRef,
  type MemberEmailSearchResult,
} from "../invitations/memberSearch";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  timeoutSeconds: 30,
};

function readCounter(data: FirebaseFirestore.DocumentData | undefined, field: string): number {
  const n = data?.[field];
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

export const findMemberByEmailFn = onCall(opts, async (req): Promise<MemberEmailSearchResult> => {
  const ctx = await requireAuth(req, "recherche_membre_adresse");
  const data = (req.data ?? {}) as Record<string, unknown>;

  const groupId = readGroupId(data.groupId);
  if (groupId === null) {
    throw new HttpsError("invalid-argument", "groupId manquant.");
  }
  const email = cleanEmail(data.email);
  if (email === null) {
    throw new HttpsError("invalid-argument", "Adresse e-mail invalide.");
  }

  // Le groupe n'est nommé dans les journaux qu'une fois confirmé.
  let groupConfirmed = false;

  try {
    const db = getFirestore();
    const groupSnap = await db.collection(COLL_GROUPS).doc(groupId).get();
    const denial = searcherDenial(groupSnap.exists ? groupSnap.data() : null, ctx.userId);
    if (denial) throw new HttpsError(denial.code, denial.message);
    groupConfirmed = true;

    // Le compteur avance avant la recherche, trouvée ou non : c'est le
    // nombre d'essais qui se borne, pas le nombre de réponses positives.
    const now = new Date();
    const day = spendDay(now);
    const counter = db.collection(COLL_MEMBER_EMAIL_SEARCH_DAILY).doc(`${ctx.userId}_${day}`);
    const allowed = await db.runTransaction(async (tx) => {
      const used = readCounter((await tx.get(counter)).data(), "count");
      if (used >= MEMBER_EMAIL_SEARCH_DAILY_LIMIT) return false;
      tx.set(
        counter,
        {
          uid: ctx.userId,
          day,
          count: FieldValue.increment(1),
          updated_at: Timestamp.fromDate(now),
          expires_at: Timestamp.fromDate(searchCounterExpiry(now)),
        },
        { merge: true },
      );
      return true;
    });
    if (!allowed) {
      await logWarn({
        message: `findMemberByEmailFn: plafond de ${MEMBER_EMAIL_SEARCH_DAILY_LIMIT} recherches atteint (groupe ${groupId})`,
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: groupId,
      });
      throw new HttpsError("resource-exhausted", MEMBER_EMAIL_SEARCH_LIMIT_MESSAGE);
    }

    // La collection se lit entière, cinq champs par document, comme
    // `existingAccountFor` des invitations : une famille compte quelques
    // dizaines de comptes, et une requête d'égalité manquerait une adresse
    // stockée avec des majuscules.
    const snap = await db
      .collection(COLL_USERS)
      .select("email", "role", "is_revoked", "display_name", "preferred_name")
      .get();
    const result = findAccountByEmail(
      email,
      snap.docs.map((d) => ({ id: d.id, data: d.data() })),
    );

    if (!result.found) {
      // Même document que le plafond : les réponses vides du jour. Best-effort :
      // un échec ici ne prive pas l'appelant de sa réponse, il est journalisé.
      try {
        const misses = await db.runTransaction(async (tx) => {
          const after = readCounter((await tx.get(counter)).data(), "misses") + 1;
          tx.set(counter, { misses: after }, { merge: true });
          return after;
        });
        if (shouldWarnMisses(misses)) {
          await logWarn({
            message: `findMemberByEmailFn: ${MEMBER_EMAIL_SEARCH_MISS_ALERT} recherches par adresse sans résultat aujourd'hui (groupe ${groupId})`,
            userId: ctx.userId,
            correlationId: ctx.correlationId,
            firestoreDocId: groupId,
          });
        }
      } catch (missErr) {
        await logError({
          message: `findMemberByEmailFn: réponse vide non comptée (groupe ${groupId})`,
          errorDescription: missErr instanceof Error ? missErr.message : String(missErr),
          userId: ctx.userId,
          correlationId: ctx.correlationId,
          firestoreDocId: groupId,
        });
      }
    }

    await logInfo({
      message: `findMemberByEmailFn: recherche par adresse (groupe ${groupId}) : ${
        result.found ? "compte trouvé" : "aucun compte"
      }`,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: groupId,
    });
    return result;
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    await logError({
      message: groupConfirmed
        ? `findMemberByEmailFn: recherche impossible (groupe ${groupId})`
        : "findMemberByEmailFn: recherche impossible (groupe non vérifié)",
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: groupConfirmed ? groupId : unverifiedGroupRef(groupId),
    });
    throw new HttpsError("internal", "Recherche impossible. Réessayez.");
  }
});
