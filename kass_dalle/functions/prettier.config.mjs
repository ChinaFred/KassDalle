// Formateur des Cloud Functions Kass'Dalle.
//
// Le côté Dart a `dart format`, vérifié en CI. Le TypeScript n'avait rien :
// ESLint ne porte ici que des règles de correction (catch silencieux, variables
// inutilisées), aucune règle de style. Rien ne se battra donc avec Prettier, et
// `eslint-config-prettier` est inutile — il n'y a aucune règle à désactiver.

export default {
  // Mesuré, pas décrété : formater tout le dépôt à 80 touche 58 fichiers, à
  // 120 en touche 52, à 100 seulement 42. C'est la largeur à laquelle ce code
  // a été écrit ; l'adopter minimise le bruit au lieu de l'imposer.
  printWidth: 100,

  // Les virgules finales rendent les diffs plus courts : ajouter un paramètre
  // ne modifie plus la ligne précédente.
  trailingComma: "all",
};
