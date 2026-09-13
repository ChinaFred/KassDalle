/// Le format d'un repas : ce qu'on sert autour du plat.
///
/// Tout le monde n'entend pas « repas » de la même façon, ni tous les jours :
/// entrée, plat, dessert le dimanche ; un plat seul en semaine ; un repas
/// léger un soir de sport. Le format se règle par jour de semaine dans les
/// préférences, et se change sur un créneau au moment de composer un cycle.
/// Le défaut est le plat seul : rien ne change pour un planning qui n'en dit
/// rien.
///
/// C'est le format qui décide si le planning demande une entrée ou un
/// dessert — et non plus un mot-clé lu dans une contrainte en langage
/// naturel. Un dessert n'apparaît que sur un jour dont le format en veut un.
library;

enum MealFormat {
  plat,
  platDessert,
  entreePlat,
  entreePlatDessert,
  leger;

  /// Clé stockée dans Firestore et envoyée au serveur.
  String get key => switch (this) {
    MealFormat.plat => 'plat',
    MealFormat.platDessert => 'plat_dessert',
    MealFormat.entreePlat => 'entree_plat',
    MealFormat.entreePlatDessert => 'entree_plat_dessert',
    MealFormat.leger => 'leger',
  };

  String get label => switch (this) {
    MealFormat.plat => 'Plat seul',
    MealFormat.platDessert => 'Plat et dessert',
    MealFormat.entreePlat => 'Entrée et plat',
    MealFormat.entreePlatDessert => 'Entrée, plat et dessert',
    MealFormat.leger => 'Léger',
  };

  String get description => switch (this) {
    MealFormat.plat => 'Un plat, avec son accompagnement s\'il en faut un.',
    MealFormat.platDessert => 'Un plat, puis un dessert.',
    MealFormat.entreePlat => 'Une entrée, puis un plat.',
    MealFormat.entreePlatDessert => 'Le repas complet.',
    MealFormat.leger =>
      'Un seul plat léger : soupe, salade, entrée servie en plat, en-cas.',
  };

  bool get wantsStarter =>
      this == MealFormat.entreePlat || this == MealFormat.entreePlatDessert;

  bool get wantsDessert =>
      this == MealFormat.platDessert || this == MealFormat.entreePlatDessert;

  bool get isLight => this == MealFormat.leger;

  /// Le format par défaut, celui d'un jour qui n'en dit rien.
  static const MealFormat defaultFormat = MealFormat.plat;

  /// Depuis une clé stockée ; `null` si absente ou inconnue — un format
  /// inconnu vaut « pas réglé », jamais un format deviné.
  static MealFormat? fromKey(String? key) {
    if (key == null) return null;
    for (final f in MealFormat.values) {
      if (f.key == key) return f;
    }
    return null;
  }
}
