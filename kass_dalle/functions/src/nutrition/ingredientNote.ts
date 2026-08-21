/**
 * La note d'un ingrédient, déduite de sa ligne du livre.
 *
 * Elle ne dépend plus de la bonne volonté du modèle. « 1 filet de saumon de
 * 1,8 kg avec la peau mais écaillée » se décompose en une quantité, une unité,
 * un aliment — et ce qu'il reste EST la note. C'est une soustraction, pas un
 * jugement, et une soustraction ne se demande pas à un modèle.
 *
 * La passe de balisage continue de la proposer, parce qu'elle sait reformuler
 * un lien (« mélangée au miel ») là où la soustraction rendrait une bribe. Mais
 * quand elle la laisse vide, on ne se contente plus de constater l'écart : on
 * la reconstitue. Une précision qui existe dans le livre doit exister dans la
 * recette.
 *
 * Ce que cette fonction ne fait PAS : inventer. Chaque mot rendu vient de la
 * ligne, dans son ordre. Elle ne corrige rien, ne complète rien, ne traduit
 * rien.
 */

/** Mots de liaison qui n'ont aucun sens en tête ou en fin de note. */
const LIAISONS = new Set([
  "de",
  "d",
  "du",
  "des",
  "la",
  "le",
  "les",
  "l",
  "a",
  "au",
  "aux",
  "et",
  "en",
  "ou",
  "un",
  "une",
]);

function sansAccent(texte: string): string {
  return texte
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

/**
 * Position de fin de la première occurrence de `fragment`, ou -1.
 *
 * La comparaison ignore les accents et la casse — le nom normalisé s'écrit
 * « ecaillee » quand la ligne dit « écaillée » — mais la position rendue porte
 * sur le texte D'ORIGINE, pour que ce qui suit garde ses accents.
 */
function finDe(ligne: string, fragment: string): number {
  const cible = fragment.trim();
  if (cible.length < 2) return -1;
  const index = sansAccent(ligne).indexOf(sansAccent(cible));
  return index < 0 ? -1 : index + cible.length;
}

/** Enlève ponctuation et mots de liaison aux deux bouts, sans toucher au reste. */
function nettoyerBords(texte: string): string {
  // La ponctuation n'est retirée qu'AUX BORDS. La retirer partout amputait
  // « cuil. à café » de son point : une note doit se lire comme le livre
  // l'écrit, abréviations comprises.
  let mots = texte
    .replace(/\s+/g, " ")
    .replace(/^[\s(),;:.]+/, "")
    .replace(/[\s(),;:]+$/, "")
    .trim()
    .split(" ")
    .filter((m) => m.length > 0);

  const estLiaison = (m: string) => LIAISONS.has(sansAccent(m).replace(/[.,;:']+$/, ""));
  while (mots.length > 0 && estLiaison(mots[0])) mots = mots.slice(1);
  while (mots.length > 0 && estLiaison(mots[mots.length - 1])) mots = mots.slice(0, -1);
  return mots.join(" ").trim();
}

/** Nombre de mots porteurs de sens — au moins trois lettres. */
function motsPorteurs(texte: string): number {
  return texte.split(/[^A-Za-zÀ-ÿ]+/).filter((m) => m.length >= 3).length;
}

/**
 * Ce que la ligne dit APRÈS avoir nommé l'ingrédient et sa quantité.
 *
 * On prend la SUITE, pas le reste. Découper la ligne en morceaux et recoller
 * ce qui n'a pas été consommé rendait « 1 de avec la peau mais écaillée » — les
 * trous laissés au milieu se refermaient sur des articles orphelins. Ce que
 * l'on cherche est une phrase, et une phrase se lit d'un bout : tout ce qui
 * suit le dernier élément identifié.
 *
 * Conséquence assumée : quand l'aliment est en fin de ligne, il ne reste rien.
 * « … mélangée à 2 cuil. à café de miel » ne donne une note qu'à la moutarde,
 * et c'est le bon endroit — c'est elle qu'on mélange.
 *
 * Rend une chaîne vide quand il ne reste rien d'exploitable : le cas normal et
 * fréquent, « 250 g de porc haché » ne dit rien de plus.
 */
/**
 * Ce qui SUIT l'ingrédient dans sa ligne, sans filtre.
 *
 * Séparé de `noteFromRawLine` parce que deux appelants en ont besoin : la note,
 * qui n'en retient que ce qui compte au moins deux mots, et le contrôle de
 * fidélité, qui doit savoir ce que la ligne disait de plus.
 *
 * Ce contrôle comparait auparavant TOUS les mots de la ligne. Pour le miel,
 * nommé en fin de « 2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil.
 * à café de miel », il réclamait « cuil » et « mélangée » — des mots qui
 * appartiennent à la moutarde. Un reproche à tort sur ce qui était à sa place.
 */
export function tailAfterIngredient(args: {
  brut: string;
  nom: string;
  qte: string;
  unite: string;
}): string {
  const brut = args.brut.trim();
  if (!brut || !args.nom.trim()) return "";

  const positions = [
    finDe(brut, args.nom),
    finDe(brut, args.unite),
    finDe(brut, args.qte),
    finDe(brut, args.qte.replace(".", ",")),
  ].filter((p) => p >= 0);

  if (positions.length === 0) return "";
  return nettoyerBords(brut.slice(Math.max(...positions)));
}

export function noteFromRawLine(args: {
  brut: string;
  nom: string;
  qte: string;
  unite: string;
}): string {
  const note = tailAfterIngredient(args);

  // Un seul mot restant est presque toujours un article ou une variante
  // d'orthographe. Deux, c'est une information.
  return motsPorteurs(note) >= 2 ? note : "";
}
