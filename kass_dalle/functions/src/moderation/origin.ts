/**
 * Origine d'une image soumise à la modération : ce que le serveur retient, et
 * jamais ce que le client déclare.
 *
 * Le callable lisait `origin: "ai" | "asset"` dans la requête et approuvait
 * alors l'image sans analyse. N'importe quel compte publiait ainsi l'image de
 * son choix sur une couverture ou une illustration vue par toute la famille.
 *
 * Désormais :
 *  - `ai` n'est posé que par le code serveur qui produit l'image lui-même ; une
 *    requête client qui le déclare est traitée comme `user` ;
 *  - `asset` n'est retenu que si l'empreinte SHA-256 du fichier est celle d'une
 *    image livrée avec l'application (`kass_dalle/assets/`) ;
 *  - tout le reste est `user`, donc analysé.
 */

import { createHash } from "node:crypto";

/** Origine d'une image, telle que le serveur la retient. */
export type ImageOrigin = "user" | "ai" | "asset";

/**
 * Empreintes SHA-256 des couvertures livrées avec l'application, celles
 * qu'envoie `BookRepository._uploadAssetCover`. Le test `moderationOrigin`
 * relit les fichiers de `kass_dalle/assets/` et échoue si une image change sans
 * que son empreinte suive.
 */
export const BUNDLED_ASSET_SHA256: Readonly<Record<string, string>> = {
  "7bdbc3c44d42a814fd4a5cb79c1b4ea5580e2766683d15822e634ea6a9f754c0": "assets/mycreations.png",
  ba8306bcf5d09280fc0a80b6b51c4a6ab16693daf13dcc3ab0c119f19a28bc91: "assets/opensource.png",
  "6b6eb36ffeb1931358bc183ecda9f41efbeac892a18d1ef1557c88e45642f278": "assets/Secret.png",
};

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** L'origine que le callable transmet : `asset` à vérifier, ou `user`. */
export function clientDeclaredOrigin(declared: unknown): "user" | "asset" {
  return declared === "asset" ? "asset" : "user";
}

/**
 * L'origine retenue pour une image, une fois ses octets connus.
 *
 * `ai` passe tel quel : seul le code serveur le pose (le callable ne le
 * transmet jamais, voir [clientDeclaredOrigin]). `asset` n'est retenu que sur
 * une empreinte connue ; sinon l'image redevient `user` et `downgraded` le dit,
 * pour que la tentative se voie dans les journaux.
 */
export function resolveImageOrigin(
  declared: ImageOrigin,
  bytesSha256: string,
): { origin: ImageOrigin; downgraded: boolean } {
  if (declared === "asset") {
    return Object.prototype.hasOwnProperty.call(BUNDLED_ASSET_SHA256, bytesSha256)
      ? { origin: "asset", downgraded: false }
      : { origin: "user", downgraded: true };
  }
  return { origin: declared, downgraded: false };
}
