/// Libellés du droit de déclencher un conseil ou un calcul écrit sur une
/// recette.
///
/// Le conseil de dressage, son visuel d'étape, le conseil de conservation et
/// le calcul de nutrition s'écrivent sur la recette partagée. Seuls son
/// créateur et un administrateur les déclenchent (`assertCanModifyRecipe`
/// dans les Functions, `AppUser.canModifyRecipe` ici). Les autres lisent ce
/// qui est déjà enregistré ; quand rien ne l'est, l'écran le dit avec ces
/// phrases plutôt que d'offrir un bouton que le serveur refuserait.
library;

/// Aucun conseil de dressage enregistré, et l'utilisateur ne peut pas en
/// demander.
const kPlatingAdviceReservedMessage =
    'Aucun conseil de dressage pour cette recette. Seuls son créateur, s\'il '
    'est éditeur, et un administrateur peuvent en demander un.';

/// Aucun conseil de conservation enregistré, et l'utilisateur ne peut pas en
/// demander.
const kStorageAdviceReservedMessage =
    'Pas encore de conseil de réchauffage pour ce plat : son créateur peut le '
    'demander.';

/// La recette n'existe plus : rien à conseiller.
const kRecipeNotFoundMessage = 'Recette introuvable.';

/// Aucune nutrition calculée, et l'utilisateur ne peut pas lancer le calcul.
const kNutritionReservedMessage =
    'Aucune donnée nutritionnelle calculée. Le calcul se fait à '
    'l\'enregistrement de la recette ; seuls son créateur, s\'il est '
    'éditeur, et un administrateur peuvent le relancer.';
