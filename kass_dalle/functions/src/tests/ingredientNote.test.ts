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
import { attachSourceLines } from "../gemini/tagging";

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

describe("la ligne du livre ne se demande PLUS au modèle", () => {
  const lignes = [
    "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
    "115 g de sel",
    "2 cuil. à soupe de moutarde à l'ancienne mélangée à 2 cuil. à café de miel",
  ];

  function ing(nom: string, qte: string, unite: string, brut = "") {
    return { brut, section: "", nom, qte, unite, note: "" };
  }

  test("le modèle ne renvoie aucune ligne — la note apparaît quand même", () => {
    // Le défaut qui a coûté trois versions : `brut` était DEMANDÉ au modèle.
    // Quand il ne le recopiait pas, la ligne était perdue, la note ne pouvait
    // plus s'en déduire, et l'écran n'avait rien à montrer. Or cette ligne,
    // nous l'avons déjà : c'est la transcription.
    const out = attachSourceLines(lignes, [
      ing("filet de saumon", "1.8", "kg"),
      ing("sel", "115", "g"),
      ing("moutarde à l'ancienne", "2", "cuil. à soupe"),
    ]);
    assert.equal(out[0].note, "avec la peau mais écaillée");
    assert.equal(out[1].note, "");
    assert.equal(out[2].note, "mélangée à 2 cuil. à café de miel");
    // Et la ligne suit, pour que l'écran ait toujours quelque chose à dire.
    assert.ok(out.every((i) => i.brut.length > 0));
  });

  test("la note du modèle l'emporte quand il en propose une", () => {
    // Il sait reformuler un lien là où la soustraction rend une bribe.
    const out = attachSourceLines(lignes, [
      { ...ing("filet de saumon", "1.8", "kg"), note: "peau conservée, écaillée" },
      ing("sel", "115", "g"),
      ing("moutarde à l'ancienne", "2", "cuil. à soupe"),
    ]);
    assert.equal(out[0].note, "peau conservée, écaillée");
  });

  test("comptes inégaux : le rattachement se fait par le nom", () => {
    // Une ligne peut nommer deux aliments — les rangs ne s'alignent plus.
    const out = attachSourceLines(lignes, [
      ing("filet de saumon", "1.8", "kg"),
      ing("moutarde à l'ancienne", "2", "cuil. à soupe"),
      ing("miel", "2", "cuil. à café"),
    ]);
    assert.match(out[0].brut, /filet de saumon/);
    assert.match(out[1].brut, /moutarde/);
    assert.equal(out[1].note, "mélangée à 2 cuil. à café de miel");
  });

  test("un nom que deux lignes réclament ne s'attache à aucune", () => {
    // « aneth » pour le saumon ET « aneth » pour la sauce ne se départagent
    // pas par le nom seul. Une note attachée au mauvais ingrédient serait pire
    // qu'aucune note, parce qu'on la croirait.
    const ambigu = ["1 bouquet d'aneth frais", "2 cuil. à café d'aneth ciselé"];
    const out = attachSourceLines(ambigu, [
      ing("aneth", "1", "bouquet"),
      ing("aneth", "2", "cuil. à café"),
      ing("sel", "115", "g"),
    ]);
    assert.equal(out[0].brut, "");
    assert.equal(out[0].note, "");
  });

  test("une ligne déjà fournie par le modèle n'est pas écrasée", () => {
    const out = attachSourceLines(lignes, [
      ing("filet de saumon", "1.8", "kg", "1 filet de saumon de 1,8 kg avec la peau"),
      ing("sel", "115", "g"),
      ing("moutarde à l'ancienne", "2", "cuil. à soupe"),
    ]);
    assert.equal(out[0].brut, "1 filet de saumon de 1,8 kg avec la peau");
  });

  test("aucun ingrédient, aucune invention", () => {
    assert.deepEqual(attachSourceLines(lignes, []), []);
  });
});
