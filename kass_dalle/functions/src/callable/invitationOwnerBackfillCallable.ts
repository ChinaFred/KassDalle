/**
 * Propriétaire du groupe des invitations — pose `group_owner_id` sur les
 * invitations par e-mail antérieures au champ, sans appel de modèle.
 *
 * La règle Firestore de `invitations` ouvre la lecture d'une invitation à un
 * non-administrateur quand `group_owner_id` vaut son uid. Elle lisait avant le
 * groupe courant (`groups/{group_id}.owner_id`) : un groupe supprimé puis
 * recréé sous le même identifiant par un autre compte lui ouvrait les
 * invitations restées en base, adresses comprises (ticket #152). Une
 * invitation sans le champ n'est plus lisible que par un administrateur : son
 * propriétaire ne la voit plus dans la feuille du groupe tant que ce backfill
 * n'est pas passé.
 *
 * Le champ se recopie depuis le groupe courant, quand il existe et que
 * l'auteur de l'invitation (`invited_by`) en est le propriétaire. Un auteur
 * simple membre ne suffit pas : un groupe recréé par un autre compte peut le
 * compter parmi ses membres. Rien n'est écrit sur une invitation dont le
 * groupe n'existe plus ou n'a pas l'auteur pour propriétaire : elle est
 * listée « À revoir ». Une invitation non reprise compte comme sans groupe à
 * l'acceptation (`invitationGroupOf`) : le rôle s'applique, pas le groupe.
 *
 * Ponctuel : `manageInvitationFn` pose le champ à la création et au renvoi.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_INVITATIONS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière invitation examinée. */
export const INVITATION_OWNER_CHECKPOINT_DOC_ID = "invitation_group_owner_backfill_checkpoint";

const FEATURE = "invitation_group_owner_backfill";

/** Invitations examinées par appel de la fonction, par défaut. */
const DEFAULT_MAX_INVITATIONS = 2000;
const PAGE_SIZE = 400;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois invitations difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillInvitationOwnerRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillInvitationOwnerResponse {
  examinees: number;
  /** `group_owner_id` écrit. */
  posees: number;
  /** Champ déjà présent, rien d'écrit. */
  dejaAJour: number;
  /** Groupe supprimé, sans propriétaire lisible ou sans l'auteur : rien d'écrit, listée à revoir. */
  sansGroupe: number;
  echouees: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
  /** Invitations non reprises, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

/** Ce qu'un passage a le droit de faire. */
export interface InvitationOwnerPassOptions {
  deadlineMs: number;
  maxDocs: number;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/** Ce que le passage décide pour une invitation, sans rien lire ni écrire. */
export type InvitationOwnerDecision =
  { kind: "up_to_date" } | { kind: "write"; ownerId: string } | { kind: "review"; reason: string };

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

/**
 * La décision pour une invitation, d'après son document et celui de son groupe
 * (`null` quand le groupe n'existe plus). Pur, testé par
 * `tests/invitationOwnerBackfill.test.ts`.
 */
export function invitationOwnerDecision(
  invitation: Record<string, unknown>,
  group: Record<string, unknown> | null,
): InvitationOwnerDecision {
  if (nonEmptyString(invitation.group_owner_id)) return { kind: "up_to_date" };
  const groupId = nonEmptyString(invitation.group_id);
  if (!groupId || groupId.includes("/")) {
    return { kind: "review", reason: "Invitation sans groupe lisible : rien d'écrit" };
  }
  if (group == null) {
    return {
      kind: "review",
      reason: "Groupe supprimé : rien d'écrit, invitation lisible par l'administrateur seul",
    };
  }
  const ownerId = nonEmptyString(group.owner_id);
  if (!ownerId) {
    return { kind: "review", reason: "Groupe sans propriétaire lisible : rien d'écrit" };
  }
  // Seul un auteur propriétaire prouve que le groupe relu est le sien : un
  // groupe recréé par un autre compte peut compter l'auteur parmi ses
  // membres, s'il a accepté d'y entrer.
  const inviter = nonEmptyString(invitation.invited_by);
  if (!inviter || inviter !== ownerId) {
    return {
      kind: "review",
      reason:
        "L'auteur de l'invitation n'est pas le propriétaire du groupe actuel " +
        "(simple membre, groupe recréé ou quitté) : rien d'écrit",
    };
  }
  return { kind: "write", ownerId };
}

function invitationReviewLabel(id: string, data: Record<string, unknown>): string {
  const email = nonEmptyString(data.email) ?? id;
  const groupName = nonEmptyString(data.group_name);
  return groupName ? `${email} (groupe « ${groupName} »)` : email;
}

export const backfillInvitationGroupOwnerFn = onCall<BackfillInvitationOwnerRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_INVITATIONS);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(10000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_INVITATIONS;
    const options: InvitationOwnerPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxDocs,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "invitation_group_owner",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runInvitationOwnerPass(ctx, options),
      summarize: summarizeInvitationOwner,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeInvitationOwner(r: BackfillInvitationOwnerResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    // Une invitation sans groupe reste à revoir : le backfill n'est pas
    // marqué terminé tout seul tant qu'il en reste une.
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Une écriture en échec se retente au passage suivant.
    unresolved: 0,
  };
}

/** Un passage. Aucun appel de modèle. */
export async function runInvitationOwnerPass(
  ctx: AuthContext,
  options: InvitationOwnerPassOptions,
): Promise<BackfillInvitationOwnerResponse> {
  const db = getFirestore();
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();
  const response: BackfillInvitationOwnerResponse = {
    examinees: 0,
    posees: 0,
    dejaAJour: 0,
    sansGroupe: 0,
    echouees: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };

  let cursor = await getBackfillCursor({
    db,
    docId: INVITATION_OWNER_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint: options.resumeFromCheckpoint,
    resetCheckpoint: options.resetCheckpoint,
  });
  let consecutiveFailures = 0;
  /** Groupes déjà lus dans ce passage : `null` pour un groupe absent. */
  const groups = new Map<string, Record<string, unknown> | null>();

  pages: for (;;) {
    let query = db.collection(COLL_INVITATIONS).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.completed = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (response.examinees >= options.maxDocs) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      try {
        let group: Record<string, unknown> | null = null;
        const groupId = nonEmptyString(data.group_id);
        if (!nonEmptyString(data.group_owner_id) && groupId && !groupId.includes("/")) {
          if (!groups.has(groupId)) {
            const snap = await db.collection(COLL_GROUPS).doc(groupId).get();
            groups.set(groupId, snap.exists ? (snap.data() ?? {}) : null);
          }
          group = groups.get(groupId) ?? null;
        }
        const decision = invitationOwnerDecision(data, group);
        if (decision.kind === "up_to_date") {
          response.dejaAJour += 1;
        } else if (decision.kind === "review") {
          response.sansGroupe += 1;
          review.add({
            kind: "invitation",
            id: doc.id,
            label: invitationReviewLabel(doc.id, data),
            reason: decision.reason,
          });
        } else {
          await doc.ref.update({ group_owner_id: decision.ownerId });
          response.posees += 1;
        }
        consecutiveFailures = 0;
      } catch (e) {
        response.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "invitation",
          id: doc.id,
          label: invitationReviewLabel(doc.id, data),
          reason: `Échec : ${shortErrorMessage(e)}`,
        });
        // Ni adresse ni nom dans le journal : l'identifiant suffit à retrouver
        // l'invitation.
        await logError("Propriétaire des invitations — échec sur une invitation", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { invitationId: doc.id, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    if (page.size < PAGE_SIZE) {
      response.completed = true;
      break;
    }
  }

  response.aRevoir = review.toJSON();
  // Le curseur revient au début quand la collection est parcourue, même avec
  // des échecs : le passage suivant repart du début et reprend les invitations
  // en échec (les autres sont comptées « déjà à jour », sans écriture).
  const reachedEnd = response.completed;
  if (response.echouees > 0) response.completed = false;
  await setBackfillCursor({
    db,
    docId: INVITATION_OWNER_CHECKPOINT_DOC_ID,
    lastDocId: reachedEnd ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Propriétaire du groupe des invitations — reprise",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
