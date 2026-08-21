/**
 * La note d'un ingrédient, déduite de sa ligne du livre.
 *
 * Ce que ces tests verrouillent : une précision écrite dans le livre finit
 * dans la recette, que le modèle ait pensé à la remplir ou non. Elle se
 * CALCULE — c'est ce que la ligne dit après avoir nommé l'aliment et sa
 * quantité — et un calcul ne se demande pas à un modèle.
 *
 * Et la contrainte inverse, tout aussi importante : chaque mot rendu vient de
 * la ligne. Une note inventée serait pire que pas de note, parce qu'on la
 * croirait.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { noteFromRawLine } from "../nutrition/ingredientNote";

describe("ce que la ligne dit en plus", () => {
  test("l'état de l'ingrédient est conservé", () => {
    assert.equal(
      noteFromRawLine({
        brut: "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
        nom: "filet de saumon",
        qte: "1.8",
        unite: "kg",
      }),
      "avec la peau mais écaillée",
    );
  });

  test("le lien avec un autre ingrédient aussi", () => {
    assert.equal(
      noteFromRawLine({
        brut: "2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel",
        nom: "moutarde à l'ancienne",
        qte: "2",
        unite: "cuil. à café",
      }),
      // L'abréviation garde son point : une note se lit comme le livre l'écrit.
      "mélangée à 2 cuil. à café de miel",
    );
  });

  test("l'ingrédient nommé en fin de ligne n'hérite de rien", () => {
    // Conséquence assumée : « … mélangée à 2 c. à café de miel » donne sa note
    // à la moutarde, pas au miel. C'est le bon endroit — c'est la moutarde
    // qu'on mélange.
    assert.equal(
      noteFromRawLine({
        brut: "2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel",
        nom: "miel",
        qte: "2",
        unite: "cuil. à café",
      }),
      "",
    );
  });

  test("une virgule d'attente n'est pas une note", () => {
    assert.equal(
      noteFromRawLine({
        brut: "20 cl de crème liquide entière, bien froide",
        nom: "crème liquide entière",
        qte: "20",
        unite: "cl",
      }),
      "bien froide",
    );
  });

  test("la quantité écrite à la française est reconnue", () => {
    // Le livre écrit « 1,8 », la normalisation rend « 1.8 » : sans les deux
    // essais, la note commencerait au mauvais endroit.
    assert.match(
      noteFromRawLine({
        brut: "1,8 kg de saumon fumé à froid",
        nom: "saumon",
        qte: "1.8",
        unite: "kg",
      }),
      /fumé à froid/,
    );
  });
});

describe("ce qui ne doit PAS produire de note", () => {
  test("une ligne simple n'en réclame aucune", () => {
    // Le cas fréquent, et il faut surtout ne rien inventer.
    assert.equal(
      noteFromRawLine({ brut: "250 g de porc haché", nom: "porc haché", qte: "250", unite: "g" }),
      "",
    );
  });

  test("un seul mot restant est écarté", () => {
    // Presque toujours un article ou une variante d'orthographe. Alerter là
    // ferait du bruit, et le bruit fait ignorer le reste.
    assert.equal(
      noteFromRawLine({ brut: "2 gousses d'ail dégermées", nom: "ail", qte: "2", unite: "gousse" }),
      "",
    );
  });

  test("une ligne vide ou un nom absent ne fabriquent rien", () => {
    assert.equal(noteFromRawLine({ brut: "", nom: "sel", qte: "1", unite: "pincée" }), "");
    assert.equal(
      noteFromRawLine({ brut: "1 pincée de sel", nom: "", qte: "1", unite: "pincée" }),
      "",
    );
  });

  test("un nom introuvable dans la ligne ne fait pas prendre la ligne entière", () => {
    // Si rien ne s'aligne, on préfère le silence à une note qui reprendrait
    // tout, quantité comprise.
    assert.equal(
      noteFromRawLine({ brut: "250 g de porc haché", nom: "boeuf", qte: "", unite: "" }),
      "",
    );
  });
});

describe("chaque mot vient de la ligne", () => {
  test("aucun mot rendu n'est absent de l'original", () => {
    const brut = "1 filet de saumon de 1,8 kg avec la peau mais écaillée";
    const note = noteFromRawLine({ brut, nom: "filet de saumon", qte: "1.8", unite: "kg" });
    for (const mot of note.split(" ")) {
      assert.ok(brut.includes(mot), `« ${mot} » ne figure pas dans la ligne`);
    }
  });
});
