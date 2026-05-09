/// Catégorise un ingrédient par analyse des mots-clés de son nom.
///
/// Utilisé pour trier la liste de courses par rayon de supermarché.
class IngredientCategorizer {
  static const List<String> categoryOrder = [
    'Viandes & charcuterie',
    'Poissons & crustacés',
    'Légumes',
    'Fruits',
    'Produits laitiers & œufs',
    'Féculents & céréales',
    'Épicerie & condiments',
    'Épices & herbes',
    'Autres',
  ];

  static const Map<String, List<String>> _keywords = {
    'Viandes & charcuterie': [
      'boeuf', 'bœuf', 'veau', 'poulet', 'porc', 'agneau', 'dinde', 'canard',
      'lapin', 'mouton', 'jambon', 'lardons', 'lardon', 'bacon', 'saucisse',
      'merguez', 'steak', 'viande', 'pintade', 'foie', 'rognon', 'andouille',
      'chorizo', 'magret', 'escalope', 'cuisse', 'aile', 'travers', 'côte',
      'filet de porc', 'filet de bœuf', 'filet de veau', 'blanc de poulet',
      'haché', 'grillades', 'entrecôte', 'rosbif', 'gigot', 'chevreuil',
      'sanglier', 'caille', 'pigeon', 'faisan', 'manchon', 'gésier',
    ],
    'Poissons & crustacés': [
      'saumon', 'thon', 'cabillaud', 'truite', 'crevette', 'moule', 'huître',
      'homard', 'langoustine', 'calmar', 'seiche', 'poisson', 'merlan',
      'dorade', 'lotte', 'sardine', 'anchois', 'maquereau', 'crabe', 'poulpe',
      'saint-jacques', 'gambas', 'lieu', 'sole', 'turbot', 'bar', 'rouget',
      'bulot', 'palourde', 'clam', 'anguille', 'hareng', 'sprat',
    ],
    'Légumes': [
      'tomate', 'carotte', 'courgette', 'aubergine', 'poivron', 'oignon',
      'ail', 'échalote', 'poireau', 'céleri', 'brocoli', 'épinard', 'salade',
      'laitue', 'radis', 'navet', 'betterave', 'chou', 'artichaut', 'asperge',
      'champignon', 'concombre', 'fenouil', 'maïs', 'pomme de terre', 'potiron',
      'potimarron', 'butternut', 'endive', 'cresson', 'roquette', 'panais',
      'haricot vert', 'petits pois', 'pois gourmand', 'fève', 'edamame',
      'courge', 'topinambour', 'salsifis', 'blette', 'pak choï', 'bok choy',
      'oignon nouveau', 'ciboule', 'légume', 'rutabaga', 'piment doux',
    ],
    'Fruits': [
      'pomme', 'poire', 'banane', 'orange', 'citron', 'fraise', 'framboise',
      'cerise', 'abricot', 'pêche', 'mangue', 'ananas', 'avocat', 'kiwi',
      'raisin', 'melon', 'pastèque', 'figue', 'prune', 'myrtille', 'groseille',
      'lime', 'pamplemousse', 'papaye', 'litchi', 'noix de coco', 'grenade',
      'nectarine', 'brugnon', 'mirabelle', 'quetsche', 'datte', 'fruit',
    ],
    'Produits laitiers & œufs': [
      'lait', 'beurre', 'crème', 'fromage', 'gruyère', 'parmesan', 'mozzarella',
      'camembert', 'brie', 'comté', 'emmental', 'yaourt', 'mascarpone', 'ricotta',
      'chèvre', 'feta', 'roquefort', 'fromage blanc', 'oeuf', 'oeufs', 'œuf', 'œufs',
      'crème fraîche', 'crème fleurette', 'crème liquide', 'reblochon', 'munster',
      'raclette', 'beaufort', 'tomme', 'gouda', 'cheddar', 'coulommiers',
    ],
    'Féculents & céréales': [
      'farine', 'riz', 'pâtes', 'spaghetti', 'macaroni', 'tagliatelle', 'pain',
      'baguette', 'chapelure', 'semoule', 'polenta', 'quinoa', 'couscous',
      'avoine', 'boulgour', 'lentille', 'pois chiche', 'haricot blanc', 'flageolet',
      'fécule', 'maïzena', 'blé', 'épeautre', 'sarrasin', 'gnocchi', 'lasagne',
      'tortellini', 'ravioli', 'noodle', 'nouille', 'penne', 'farfalle',
      'linguine', 'fettuccine', 'millet', 'orge', 'tapioca',
    ],
    'Épicerie & condiments': [
      'huile', 'vinaigre', 'moutarde', 'mayonnaise', 'ketchup', 'sauce soja',
      'tamari', 'nuoc-mam', 'nuoc mam', 'bouillon', 'concentré de tomate',
      'coulis', 'sucre', 'miel', 'sirop', 'chocolat', 'levure', 'bicarbonate',
      'gélatine', 'agar', 'amandes', 'noisettes', 'noix', 'pistache', 'pignons',
      'cacahuète', 'tahini', 'fond de veau', 'fond de volaille', 'fumet',
      'extrait de vanille', 'poudre d\'amandes', 'lécithine',
    ],
    'Épices & herbes': [
      'sel', 'poivre', 'cumin', 'curcuma', 'paprika', 'cannelle', 'muscade',
      'clou de girofle', 'anis', 'basilic', 'thym', 'romarin', 'laurier',
      'persil', 'menthe', 'estragon', 'safran', 'cardamome', 'piment de cayenne',
      'chili', 'origan', 'sauge', 'cerfeuil', 'herbes de provence', 'fines herbes',
      'sésame', 'curry', 'gingembre', 'ras el hanout', 'harissa', 'za\'atar',
      'sumac', 'garam masala', 'coriandre', 'fenouil graines', 'épice',
      'mélange d\'épices', 'baies roses', 'carvi', 'fenugrec', 'pavot',
    ],
  };

  /// Retourne la catégorie de l'ingrédient selon son nom.
  /// Retourne 'Autres' si aucun mot-clé ne correspond.
  static String categorize(String name) {
    final lower = name.toLowerCase();
    for (final entry in _keywords.entries) {
      for (final kw in entry.value) {
        if (lower.contains(kw)) return entry.key;
      }
    }
    return 'Autres';
  }
}
