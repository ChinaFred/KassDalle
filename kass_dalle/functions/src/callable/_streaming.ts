/**
 * Messages de progression d'une callable écoutée en flux.
 *
 * Une callable de firebase-functions 7 reçoit un second argument, `response`,
 * dont `sendChunk` écrit un message vers le client pendant que le traitement
 * continue. Le client ne les reçoit que s'il a appelé la fonction en flux
 * (`request.acceptsStreaming`) ; un appel classique ne reçoit que le résultat.
 *
 * Un message de progression est un confort d'affichage : un envoi qui lève
 * ne fait jamais échouer le traitement. Il est journalisé par [onFailure],
 * puis le traitement continue.
 *
 * Le canal dit aussi si le client est parti : `response.signal` interrompu,
 * ou dernier `sendChunk` qui a rendu `false` (firebase-functions 7.2.5 rend
 * `false` quand la connexion est fermée). L'appelant s'arrête alors avant
 * l'appel de modèle suivant : le client relance un appel classique, et
 * continuer facturerait le même travail deux fois.
 *
 * Sans SDK de fournisseur : testé seul (`tests/textExtractionSteps.test.ts`).
 */

import type { CallableResponse } from "firebase-functions/v2/https";

/** Canal des messages de progression d'un appel. */
export interface ProgressChannel<T> {
  /** Envoie un message ; ne lève jamais. */
  send: (chunk: T) => Promise<void>;
  /**
   * Vrai quand un client en flux est parti. Toujours faux pour un appel
   * classique : rien ne dit alors que le client écoute, et il attend le
   * résultat.
   */
  clientGone: () => boolean;
}

/**
 * Construit le canal des messages de progression d'un appel.
 *
 * Sans `response` ou sans flux accepté par le client, l'envoi ne fait rien et
 * le client n'est jamais considéré comme parti : l'ancien client, qui appelle
 * la fonction de façon classique, continue de recevoir le seul résultat.
 */
export function progressSender<T>(
  response: Pick<CallableResponse<T>, "sendChunk" | "signal"> | undefined,
  acceptsStreaming: boolean,
  onFailure: (error: unknown, chunk: T) => Promise<void>,
): ProgressChannel<T> {
  if (!response || !acceptsStreaming) {
    return { send: async () => undefined, clientGone: () => false };
  }
  let lastWriteRefused = false;
  return {
    send: async (chunk: T) => {
      try {
        lastWriteRefused = !(await response.sendChunk(chunk));
      } catch (error) {
        await onFailure(error, chunk);
      }
    },
    clientGone: () => response.signal.aborted || lastWriteRefused,
  };
}
