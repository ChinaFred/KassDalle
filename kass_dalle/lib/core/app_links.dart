/// Adresses publiques de l'application.
///
/// Une adresse collée hors de l'application — description d'un événement
/// Google Calendar, courriel — ne peut ouvrir que le client web : l'APK
/// Android ne réclame aucun lien, et le desktop n'en reçoit pas. Le client
/// web lit sa route derrière un `#`, stratégie d'adresse par défaut de
/// Flutter web puisque `usePathUrlStrategy` n'est appelé nulle part :
/// `/#/recipes/{id}`, paramètres compris.
library;

/// Origine du client web hébergé sur Firebase Hosting.
const kAppWebOrigin = 'https://kassdale-6d948.web.app';

/// Adresse publique d'une route interne, telle qu'un navigateur l'ouvre.
///
/// [location] est la route telle que le routeur la reçoit : `/recipes/abc`
/// ou `/recipes/abc?portions=8`. Elle passe entière derrière le `#`, et le
/// routeur la relit avec ses paramètres.
Uri appWebLink(String location) =>
    Uri.parse(kAppWebOrigin).replace(path: '/', fragment: location);
