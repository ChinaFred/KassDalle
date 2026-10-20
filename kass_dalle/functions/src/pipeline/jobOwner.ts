/**
 * Le propriétaire d'un job d'import doit encore être éditeur à chaque tentative.
 *
 * Les callables relisent le rôle et la révocation sur le document utilisateur
 * à chaque appel (`callable/_auth.ts`). Le pipeline, lui, n'est pas une
 * requête : les nouveaux essais de Cloud Tasks, les tranches d'un livre
 * (`bookImport.ts`) et la relance d'un dead letter partaient sans aucun
 * contrôle de rôle. Un éditeur révoqué en plein import continuait à dépenser
 * son plafond. `processJob` relit donc `users/{created_by}` avant le premier
 * appel de modèle, avec la même décision que `requireEditor`.
 */

import { accessDenial, accountDocument, type AccountState } from "../callable/_auth";

/** Code écrit dans `error_code` du job refusé ; la tuile du client le lit. */
export const OWNER_NOT_EDITOR_CODE = "owner_not_editor";

/** Message écrit dans `error_message` du job refusé, lu par le membre. */
export const OWNER_NOT_EDITOR_MESSAGE =
  "Import arrêté : le compte qui l'a lancé n'a plus le rôle éditeur ou a été révoqué. " +
  "Aucun appel d'IA n'a été fait pour cette tentative.";

/** Refus du propriétaire : le job part en dead letter sans nouvel essai. */
export class JobOwnerNotEditor extends Error {
  constructor(
    readonly ownerUid: string,
    detail: string,
  ) {
    super(detail);
    this.name = "JobOwnerNotEditor";
  }
}

/**
 * Raison du refus, ou `null` si le propriétaire peut encore importer. Pure et
 * exportée pour être testée.
 *
 * `account` nul : le document utilisateur n'existe plus, aucun rôle, refusé —
 * même lecture que `mergeAccount` pour un compte supprimé. Le fondateur est
 * administrateur sur son document (`triggers/founderRole.ts` le restaure) : il
 * passe comme tout administrateur.
 */
export function jobOwnerDenial(account: AccountState | null): string | null {
  const denial = accessDenial(account ?? { role: null, revoked: false }, "editor");
  return denial ? denial.message : null;
}

/** Lève [JobOwnerNotEditor] si le propriétaire du job n'est plus éditeur. */
export async function assertJobOwnerEditor(ownerUid: string): Promise<void> {
  const denial = jobOwnerDenial(await accountDocument(ownerUid));
  if (denial) throw new JobOwnerNotEditor(ownerUid, denial);
}
