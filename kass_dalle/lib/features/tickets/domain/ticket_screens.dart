/// L'écran concerné par un ticket : un modèle de route, jamais une adresse.
///
/// Le titre et la description d'un ticket partent sur un dépôt GitHub public.
/// L'écran y part aussi, sous la forme du modèle de route go_router
/// (`/recipes/:recipeId`) : une adresse réelle (`/recipes/Xy7…?bookId=…`)
/// publierait l'identifiant d'une recette ou d'un livre de la famille.
///
/// [ticketScreenValue] ne rend donc qu'une valeur d'un ensemble fermé : une
/// clé de [kTicketScreenNames], [kTicketScreenOther] ou [kTicketScreenUnknown].
/// Une valeur hors de la table — une adresse réelle, un paramètre de requête,
/// une route ajoutée sans entrée ici — devient « Je ne sais pas ».
library;

/// Valeur de « Autre écran ».
const kTicketScreenOther = 'autre';

/// Valeur de « Je ne sais pas ».
const kTicketScreenUnknown = 'inconnu';

const _admin = 'Administration — ';

/// Modèle de route → nom affiché, dans l'ordre de la liste déroulante.
///
/// `test/ticket_screens_test.dart` vérifie que chaque route du routeur y
/// figure : une route ajoutée sans son nom fait échouer la suite.
const Map<String, String> kTicketScreenNames = {
  '/': 'Bibliothèque',
  '/books/new': 'Nouveau livre',
  '/books/:bookId/edit': 'Modifier le livre',
  '/books/validation': 'Livres à valider',
  '/recipes': 'Liste des recettes',
  '/recipes/:recipeId': 'Fiche recette',
  '/recipes/new': 'Nouvelle recette',
  '/recipes/:recipeId/edit': 'Modifier la recette',
  '/book-pages/:pageId': 'Page de livre',
  '/scan': 'Scan',
  '/drafts': 'Brouillons',
  '/drafts/:recipeId': 'Relecture d\'un brouillon',
  '/processing': 'Traitements',
  '/search': 'Explorer',
  '/planning': 'Planning',
  '/planning/batch': 'Nouveau planning',
  '/planning/config': 'Configuration du planning',
  '/planning/staples': 'Mes garnitures',
  '/planning/suggest': 'Suggérer un plat',
  '/account': 'Profil et compte',
  '/preferences': 'Préférences',
  '/changelog': 'Nouveautés',
  '/groups': 'Groupes familiaux',
  '/groups/:groupId': 'Membres d\'un groupe',
  '/tickets': 'Mes tickets',
  '/tickets/new': 'Signaler ou proposer',
  '/tickets/:ticketId': 'Suivi d\'un ticket',
  '/admin': 'Administration',
  '/admin/users': '${_admin}Gestion des utilisateurs',
  '/admin/users/invite': '${_admin}Inviter par e-mail',
  '/admin/costs': '${_admin}Coûts de l\'application',
  '/admin/backfills': '${_admin}Backfills',
  '/admin/referentials': '${_admin}Référentiels',
  '/admin/nutrition-ingredients': '${_admin}Ingrédients nutrition',
  '/admin/nutrition-units': '${_admin}Unités de mesure',
  '/admin/nutrition-policy': '${_admin}Politique nutrition',
  '/admin/data-quality': '${_admin}Qualité des données',
  '/admin/meal-staples': '${_admin}Garnitures simples',
  '/admin/ai-spend': '${_admin}Dépense par utilisateur',
  '/admin/app-check': '${_admin}Attestation de l\'application',
  '/admin/ai-routing': '${_admin}Moteur d\'IA',
  '/admin/ai-pricing': '${_admin}Grille tarifaire',
  '/admin/moderation': '${_admin}Modération des images',
  '/admin/tickets': '${_admin}Tickets des membres',
  '/admin/tickets/:ticketId': '${_admin}Suivi d\'un ticket',
  '/admin/sandbox': '${_admin}Bac à sable',
  '/admin/sandbox/:experimentId': '${_admin}Expérience du bac à sable',
  '/error-reports': '${_admin}Rapports d\'erreurs',
  '/dead-letters': '${_admin}Dead Letter Queue',
  '/logs': '${_admin}Cloud Logging',
};

/// Routes qui affichent le même écran qu'une autre : `/books` montre la
/// Bibliothèque, comme `/`. Une seule entrée dans la liste déroulante.
const Map<String, String> _kTicketScreenAliases = {'/books': '/'};

/// La valeur « écran » d'un ticket pour le modèle de route [routePattern].
///
/// Toujours une clé de [kTicketScreenNames], [kTicketScreenOther] ou
/// [kTicketScreenUnknown] : rien d'autre ne peut sortir de cette fonction.
String ticketScreenValue(String? routePattern) {
  if (routePattern == null) return kTicketScreenUnknown;
  if (routePattern == kTicketScreenOther) return kTicketScreenOther;
  final pattern = _kTicketScreenAliases[routePattern] ?? routePattern;
  if (kTicketScreenNames.containsKey(pattern)) return pattern;
  return kTicketScreenUnknown;
}

/// Les choix de la liste déroulante « Écran concerné », dans l'ordre.
List<({String value, String label})> ticketScreenOptions() => [
  for (final e in kTicketScreenNames.entries) (value: e.key, label: e.value),
  (value: kTicketScreenOther, label: 'Autre écran'),
  (value: kTicketScreenUnknown, label: 'Je ne sais pas'),
];

/// Nom affiché d'une valeur « écran » stockée. Une valeur que cette version
/// ne connaît pas est un modèle de route : elle s'affiche telle quelle.
String ticketScreenLabel(String value) {
  if (value == kTicketScreenOther) return 'Autre écran';
  if (value == kTicketScreenUnknown || value.isEmpty) return 'Je ne sais pas';
  return kTicketScreenNames[value] ?? value;
}
