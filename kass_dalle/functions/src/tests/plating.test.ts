/**
 * Détection d'un conseil de dressage passe-partout.
 *
 * C'est le seul garde-fou du poste : un conseil générique ne lève aucune
 * erreur, s'affiche parfaitement et ressemble à du travail. Sans ce test, la
 * règle qui le refuse pourrait se casser sans que rien ne le signale.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { looksGeneric, type PlatingAdvice, type PlatingInput } from "../gemini/plating";

const COOKLANG = [
  ">> titre: Dos de cabillaud, confit d'oignon",
  "",
  "Poser le @dos de cabillaud{2%pièce} sur la @peau{}.",
  "Étaler le @confit d'oignon{100%g} et poser la @tuile de parmesan{2%pièce}.",
].join("\n");

const INPUT: PlatingInput = {
  titre: "Dos de cabillaud, confit d'oignon",
  cooklang: COOKLANG,
};

function advice(etapes: Array<{ titre: string; geste: string }>): PlatingAdvice {
  return {
    complexite: "complexe",
    resume: "",
    contenant: "",
    etapes: etapes.map((e) => ({ ...e, elements: [], imagePrompt: null })),
    pieges: [],
    derniereMinute: [],
  };
}

describe("looksGeneric", () => {
  test("des gestes qui nomment les éléments de la recette sont acceptés", () => {
    const value = advice([
      { titre: "Le confit", geste: "Étaler le confit d'oignon en disque au centre." },
      { titre: "Le poisson", geste: "Poser le dos de cabillaud, peau vers le haut." },
    ]);
    assert.equal(looksGeneric(value, INPUT), false);
  });

  test("des gestes valables pour n'importe quel plat sont refusés", () => {
    const value = advice([
      { titre: "Le point focal", geste: "Poser l'élément principal légèrement décentré." },
      { titre: "La sauce", geste: "Tracer une virgule de sauce sur le côté." },
      { titre: "Finition", geste: "Essuyer les bords avant d'envoyer." },
    ]);
    assert.equal(looksGeneric(value, INPUT), true);
  });

  test("une minorité de gestes ancrés suffit à accepter", () => {
    // On chasse la réponse entièrement passe-partout, pas la formulation
    // imparfaite : deux étapes sur quatre citent la recette.
    const value = advice([
      { titre: "Le confit", geste: "Étaler le confit d'oignon." },
      { titre: "Le poisson", geste: "Poser le cabillaud dessus." },
      { titre: "Volume", geste: "Créer de la hauteur." },
      { titre: "Finition", geste: "Laisser respirer l'assiette." },
    ]);
    assert.equal(looksGeneric(value, INPUT), false);
  });

  test("une réponse sans étape est refusée", () => {
    assert.equal(looksGeneric(advice([]), INPUT), true);
  });

  test("une page sans ingrédient balisé n'est pas jugée", () => {
    // Note, technique, texte libre : rien à quoi comparer les gestes. Refuser
    // y serait un faux positif garanti, et le second appel coûterait autant
    // que le premier pour le même résultat.
    const value = advice([{ titre: "Service", geste: "Servir bien chaud." }]);
    assert.equal(
      looksGeneric(value, { titre: "Note de service", cooklang: "Texte libre." }),
      false,
    );
  });
});
