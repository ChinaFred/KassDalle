# Spécifications Fonctionnelles — Kass'dalle
## Livre de Cuisine Digital (Flutter + Firebase)

> Version : 2.3 — 19 août 2026

## Spécification — Modération des images

> **Implémentée.** Moteur : **Google Cloud Vision** (SafeSearch + labels). Cette
> section remplace `Future devs/moderation_images_prompt.md`, dont elle révise
> deux décisions.
>
> **Prérequis d'exploitation** : l'API Cloud Vision doit être activée sur le
> projet Google Cloud. Tant qu'elle ne l'est pas, aucune image n'obtient de
> verdict : elles attendent, ce qui est le comportement voulu — mais elles ne se
> publient pas.

### Pourquoi

Une image publiée est vue par toute la famille, enfants compris, et rien ne l'examine
aujourd'hui. Le risque n'est pas l'intrus — Storage n'accepte que des comptes nommés et
approuvés — c'est l'erreur ordinaire : la mauvaise photo dans la galerie, un appareil
prêté, une session restée ouverte. Et une image ne se retire pas comme un mot : quand on
la supprime, elle a déjà été vue.

### Ce qui existe, et ce qui manque

- **La quarantaine existe déjà**, mais pour le seul import de scans : le fichier atterrit
  dans une zone privée, le serveur le regarde, puis le promeut. Ce qu'il regarde est le
  **format** — extension, type MIME, signature binaire. Jamais le contenu.
- **Quatre portes publient une image sans passer par là** : la couverture d'un livre,
  l'illustration d'une recette, les illustrations extraites d'un scan, la couverture d'une
  recette libre. Ce sont elles, et non l'import, qui mettent une image sous les yeux de la
  famille.
- **Tant qu'elles restent ouvertes, modérer l'import ne protège de rien.** Les faire
  passer par la quarantaine est le vrai chantier ; l'analyse du contenu vient après.

### Trois états, et le doute ne publie pas

| État | Ce qui se passe |
|---|---|
| **Approuvée** | Publiée, en quelques secondes. C'est le cas de presque toutes les images. |
| **Refusée** | Jamais publiée. L'envoyeur l'apprend, avec le motif — et l'image est **conservée**, lisible des seuls administrateurs. |
| **À revoir** | Reste en attente jusqu'à la décision d'un administrateur. |

### Le contexte culinaire l'emporte sur la violence

Une découpe de poulet, une volaille entière, un couteau sur une planche : c'est de la
cuisine. **Violence détectée + contexte culinaire fort = approuvée**, directement, sans
file d'attente.

C'est un arbitrage assumé, et il se défend des deux côtés : une file qui se remplit de
photos de viande n'est pas relue, elle est expédiée d'un clic — et la relecture ne vaut
alors plus rien pour les cas qui la méritaient. À l'inverse, faire attendre un
administrateur pour publier une photo de rôti, c'est une panne pour celui qui l'a
envoyée. Reste en revue ce qui est violent **sans** contexte culinaire : là, on ne sait
pas, et ne pas savoir n'autorise pas à publier.

**Le contenu sexuel explicite ne bénéficie d'aucun contexte** : refus direct, sans file
d'attente. Aucune recette n'en a besoin.

**Une scène de violence certaine, sans contexte culinaire, est refusée elle aussi** — et
pour ce motif-là, pas un autre. L'envoyer en revue obligerait un administrateur à la
regarder pour conclure ce que les signaux disaient déjà.

**Le suggestif ne refuse jamais seul.** « Explicite » et « suggestif » sont deux choses :
une épaule nue, un maillot de bain, un débardeur déclenchent le second en permanence. Les
confondre revient à refuser une famille au barbecue — et, sur une photo de violence où
quelqu'un porte un débardeur, à annoncer un motif sexuel pour une scène qui n'en est pas
une. Le suggestif marqué fait au plus passer l'image en revue.

### Ce que voit celui qui envoie

- **Approuvée** — rien ne change pour lui, hormis quelques secondes d'attente. C'est le
  cas courant, et il doit rester invisible.
- **À revoir** — l'image apparaît en attente, à sa place, avec la mention de ce qui est
  attendu. Ni échec, ni disparition : une image qui s'évanouit sans un mot est pire qu'un
  refus.
- **Refusée** — dit franchement, avec le motif.
- **Moteur en panne** — l'image reste en attente et l'écran le dit. **Pas de repli** :
  publier par défaut, c'est modérer pour rien ; refuser par défaut, c'est accuser à tort.
  C'est la règle qui vaut déjà pour la grille tarifaire.

### La revue — Administration › Modération

**Les administrateurs seuls** décident. Un editor publie des images ; il ne peut pas être
son propre arbitre.

**L'écran montre toutes les images, pas seulement les refusées.** Une page qui ne
montrerait que les rejets ne dirait rien du plus important : ce que la modération laisse
passer. On y voit les approuvées, les refusées, celles en attente de décision et celles
qu'aucun verdict n'a pu atteindre — filtrables par état et par date. C'est un **journal**,
pas une corbeille.

**Sous chaque image, la lecture est écrite en français.** Ce que le moteur a vu ne
s'affiche jamais brut : chaque critère porte son libellé (contenu adulte, suggestif,
violence, médical, montage) et son palier (très peu probable → très probable), et la
décision porte sa phrase — *« refusée : contenu sexuel explicite »*, *« approuvée :
contexte culinaire reconnu malgré une alerte de violence »*, *« à revoir : violence sans
contexte culinaire »*, *« sans verdict : moteur injoignable »*. Un administrateur doit
pouvoir dire pourquoi une image a été refusée sans ouvrir le code.

**Une image se voit, sinon elle ne se juge pas.** Une image **à revoir** s'affiche
d'office : on ne demande à personne de trancher sur une photo qu'il n'a pas vue. Le
dossier de quarantaine, où elle attend, est lisible par l'administrateur en plus de son
envoyeur — sans quoi le seul écran qui compte se décidait sur des scores.

**Une image refusée se voit aussi, à la demande.** Elle est conservée sous
`rejected/`, que seul un administrateur peut lire, et l'écran la montre **à la
demande** — un clic, pas d'office : parcourir un journal ne doit pas exposer sans
prévenir ce qui a été jugé impubliable.

La supprimer était le premier réflexe, et c'était une erreur. Sans l'image, on ne
peut pas dire si le refus était fondé, et une modération qu'on ne peut pas évaluer
ne se corrige jamais. Ce sont surtout les **faux refus** qu'on a besoin de voir :
une photo de rôti prise pour une scène violente ne se découvre pas dans des
scores, elle se découvre en regardant la photo.

Aucun lien n'est stocké : l'écran lit le fichier avec les droits de celui qui le
consulte. Retirer le rôle administrateur retire l'accès dans la seconde, ce qu'un
lien de téléchargement déjà émis ne permettrait pas.

**Approuver** publie ; **Refuser** demande un motif — c'est ce que lira l'envoyeur. Le
**journal des décisions est conservé** : qui, quand, quoi, pourquoi. Une décision de
modération sans trace n'est pas une décision, c'est une humeur.

### Le badge

**L'entrée Administration porte le nombre d'images en attente de décision**, comme
l'entrée Brouillons porte celui des brouillons. Il disparaît à zéro, et ne compte que les
images qui attendent réellement quelqu'un — pas le journal entier.

Ce n'est pas un ornement : personne n'ouvre une file d'attente pour vérifier qu'elle est
vide. Sans badge, une image en attente y reste des semaines, et la modération devient une
suppression lente.

### La modération se voit dans les comptes

Elle n'est pas un service à part : elle entre dans la comptabilité existante, aux trois
endroits où l'on regarde déjà la dépense.

- **Coûts de l'application** — la modération apparaît comme un poste de dépense à part
  entière, mois par mois, à côté de l'extraction ou de la nutrition. Son moteur est nommé,
  comme Gemini et Claude le sont.
- **Dépense par utilisateur** — on voit combien d'images chaque compte a fait analyser, et
  ce que cela a coûté. C'est la seule façon de repérer un envoi massif.
- **Mais elle ne consomme pas le plafond quotidien.** Un plafond atteint doit empêcher de
  *dépenser*, jamais de *publier une image légitime* : sinon le contrôle punit celui qu'il
  protège. Elle est comptée et affichée, hors plafond, et l'écran le dit.
- **Le quota offert est une ligne, pas un silence.** Le fournisseur offre mille unités par
  mois ; à notre volume, la facture réelle sera nulle la plupart du temps. Le coût brut
  reste affiché, et le quota apparaît en déduction. Un mois à zéro euro doit se lire comme
  *« mille unités offertes ont couvert la dépense »*, pas comme *« rien n'a été analysé »*.

### Le moteur figure au choix des moteurs d'IA

Le poste apparaît dans *Admin › Moteur d'IA* comme les trente et un autres, avec un seul
choix possible aujourd'hui — **Google Cloud Vision** — et la raison affichée. Ce n'est pas
décoratif : le jour où un second moteur devient acceptable, il se sélectionne depuis cet
écran, sans déploiement. Un poste absent de cette table est un poste qu'il faudra
redéployer pour faire bouger.

### Ce qui n'est pas modéré

- **Les images produites par l'IA** — dressage, couvertures générées. Elles sortent d'un
  moteur qui applique déjà ses propres garde-fous ; les repasser au contrôle double le
  coût pour rien. **Décision prise : elles ne passent pas.**
- **Le texte** — titres, étapes, annotations. Autre sujet, autres outils.
- **Les images déjà en ligne.** La modération ne vaut que pour ce qui arrive après elle.
  Reprendre l'existant est un backfill, à décider séparément — l'écran Backfills existe.

### Le coût, en un mot

Le volume est familial : quelques dizaines d'images par mois, quand le fournisseur en
offre mille. Le coût réel sera **nul la plupart des mois**. Ce qui se paie ici n'est pas
l'analyse, c'est la latence à l'envoi et le travail de relecture — deux raisons de plus
pour que la file reste courte.

### Mise à jour release (19/08/2026 — v0.21.18)

#### Toute recette a un livre — et les livres système ne se suppriment pas

- **Les recettes conçues par l'IA pour le planning atterrissaient sans livre**, donc en recette libre. Elles rejoignent « Mes créations Kass'Dalle », comme celles de la recherche : la bibliothèque distingue de nouveau ce que la maison a inventé de ce qu'on y a soi-même écrit, et le livre prévu pour ça cesse d'être vide à côté de ses propres recettes.
- **Une recette sans livre n'existe plus.** Le choix « Aucun livre » disparaît des formulaires : sans choix, la recette rejoint « Mes recettes libres ». La règle est posée à l'entonnoir de création, dans le repository — un défaut appliqué à un seul écran n'est pas une règle, c'est une habitude. Elle vaut donc aussi pour une copie de recette d'un proche et pour un import de scan.
- **Pour l'import, le livre est résolu côté client** et voyage avec le job. Le serveur reçoit un livre et n'a pas à savoir qu'il existe des livres système : c'est ce qui évite d'écrire une seconde fois, en TypeScript, la logique qui trouve ou crée ce livre.
- **Les livres système se renomment, jamais ne se suppriment.** Le menu masquait déjà « Supprimer », mais une règle qui ne vit que dans un menu est à un appel de distance d'être enfreinte : le refus est maintenant dans le repository **et** dans les Security Rules, la seule barrière qu'un client ne peut pas contourner. Renommer reste possible — c'est le tag interne qui identifie le livre, pas son titre.
- **L'import d'un livre entier garde son « Aucun livre »** : il en crée un, le laisser vide y a un sens.

### Mise à jour release (19/08/2026 — v0.21.17)

#### Sept conceptions aveugles les unes aux autres — et quatre autres manques du planning

- **« Je veux de la variété » donnait six poulets et deux tajines.** Quand l'IA *conçoit* les plats d'un cycle, elle est appelée **une fois par créneau** — et chaque appel ne voyait que son jour. Sept fois la même question, sept fois le même réflexe : une contrainte de variété que chaque appel respectait pourtant, isolément. Chaque conception reçoit désormais la liste de ce qui est déjà prévu, et doit s'en distinguer par la protéine, le féculent **et** le style de cuisine. Le garde-fou serveur ne voyait rien non plus : il dédoublonnait par identifiant de recette, or sept recettes inventées sont sept identifiants différents.
- **Le « pourquoi ce plat, ce jour-là » survit maintenant à la validation.** Il était écrit à chaque suggestion, affiché pendant la planification, puis jeté au moment d'enregistrer — l'écran qu'on relit ensuite n'en gardait rien. Il appartient au **repas** et non à la recette : il parle de cette date, de la contrainte de ce jour et de la variété du cycle ; écrit sur la recette, il aurait menti au prochain qui la planifie.
- **Un plat cuisiné à l'avance arrive avec sa consigne de conservation.** Le conseil — comment le garder, comment le réchauffer — ne se produisait qu'à la demande, d'un bouton que rien n'invitait à presser. Il est désormais produit à la validation, pour les seuls repas qui ont un jour de préparation, et une seule fois par recette.
- **L'historique du planning se consulte enfin.** Rien n'effaçait les repas passés : c'est leur *lecture* qui s'arrêtait à quatre-vingt-dix jours, la borne du flux temps réel — sans elle, l'écran relit à chaque ouverture la totalité des repas jamais planifiés. Le calendrier remonte maintenant jusqu'à deux ans, en lisant un mois à la demande, une seule fois par mois visité.
- **Une icône pour ce que la machine a produit, une autre pour l'action de le demander.** Le petit robot marque un contenu écrit par l'IA — une raison de recherche, une valeur nutritionnelle estimée, une recette conçue, le pourquoi d'un repas. Les étoiles et la baguette restent des **verbes** : générer, suggérer, affiner. Les deux se confondaient, et l'on ne savait plus si une étoile annonçait un bouton ou un constat.

### Mise à jour release (19/08/2026 — v0.21.16)

#### Une heure de repas par jour, et un libellé qui cesse d’être coupé

- **Chaque jour peut avoir son heure.** Le samedi à midi, le vendredi à 20 h : le planning ne connaissait qu'une heure unique, appliquée aux sept jours. L'heure du jour s'ouvre dans la contrainte quotidienne, à côté du temps de préparation et des parts.
- **Changer l'heure globale ramène tous les jours à elle**, et l'écran le dit avant de le faire — « remet les 2 jour(s) personnalisé(s) à cette heure ». Sans cette remise à zéro, régler l'heure par défaut n'aurait plus d'effet visible dès qu'un seul jour aurait été personnalisé, et il faudrait deviner lesquels des sept résistent.
- **Un jour qui suit le défaut ne stocke rien.** Recopier l'heure globale sur les sept jours aurait figé sept valeurs que plus rien ne ramènerait ensemble. Le résumé du jour n'affiche l'heure que si elle lui est propre, et une flèche de retour n'apparaît que là où il y a quelque chose à annuler.
- **Le planning obéit à ces heures** : un créneau prend l'heure de son jour de semaine, y compris un jour ajouté après coup ou comblé au milieu du cycle.
- **Le libellé « Temps de préparation max (min) » n'est plus coupé en deux.** Le champ bordé fait flotter son libellé au-dessus de sa bordure ; le bloc n'avait aucune marge haute, et l'en-tête du jour le tranchait net.

### Mise à jour release (19/08/2026 — v0.21.15)

#### Planifier une semaine pose enfin la même question que planifier un jour

- **Le bouton global ignorait les sources.** Générer un créneau isolé demandait où chercher — mes recettes validées, mes brouillons, celles de la famille, et faut-il inventer si rien ne convient. Générer le cycle entier ne demandait rien et cherchait toujours dans les seules recettes validées. Deux comportements pour une même action, dont un que rien à l'écran n'annonçait.
- **La même feuille est désormais posée dans les deux cas**, par le même widget : c'est le même choix, il n'avait aucune raison d'avoir deux versions.
- **La question vient avant tout effacement.** *Tout regénérer* vidait l'écran d'abord ; annuler la feuille laissait donc un écran vide, sans le moindre moyen de revenir en arrière.
- **« Conception IA (si aucun résultat) » est honorée pour le cycle**, et pas seulement pour un jour : chaque créneau que rien n'a pu remplir reçoit une recette inventée, enregistrée en brouillon pour exister ailleurs que dans l'écran. Une case cochée qui ne fait rien est pire qu'une case absente.
- **Un cycle sans la moindre suggestion le dit** au lieu d'annoncer un succès devant un écran resté vide.

### Mise à jour release (19/08/2026 — v0.21.14)

#### L'action principale du planning cesse de se cacher dans une baguette

- **Sur grand écran, une icône dans un coin de la barre de titre n'apprend rien.** C'était pourtant l'action principale de l'écran *Nouveau planning* : sans elle, les créneaux restent vides et il n'y a rien à valider. Elle devient un bouton nommé — *Planifier avec l'IA* — posé là où se prennent les décisions de cet écran, juste au-dessus de *Valider le planning*.
- **Le bouton annonce ce qui reste à faire** : « 3 créneaux vides ». Quand tout est rempli, il ne compte plus rien — un zéro affiché n'aiderait personne.
- **Sur mobile, la baguette reste** : la barre basse y porte déjà le bouton de validation, et un second bouton pleine largeur mangerait la liste des créneaux, qui est ce qu'on vient lire.
- **Les deux façons de générer restent distinctes**, quel que soit l'écran : compléter les créneaux vides, ou tout regénérer. La seconde efface le travail déjà fait à l'écran — ce choix ne doit pas se faire par mégarde, et il ne se fait donc pas d'un simple appui.
- **Pendant la génération, le bouton le dit** au lieu de disparaître.

### Mise à jour release (19/08/2026 — v0.21.13)

#### Deux recettes sur une page ne se partagent plus une seule photo

- **Elles pointaient le même fichier.** Une page de livre qui porte deux recettes leur donnait les mêmes illustrations — non pas deux images identiques, mais **un seul objet** désigné deux fois. Rien ne casse aujourd'hui, parce que supprimer une illustration se contente d'oublier son adresse ; mais la première ligne de code qui supprimera vraiment le fichier viderait l'image de l'autre recette, sans erreur, sans coupable, et c'est l'ordre des suppressions qui déciderait laquelle perd sa photo.
- **Chaque recette au-delà de la première reçoit désormais sa copie**, faite côté serveur — aucun octet ne transite, et les métadonnées de la décision de modération suivent l'objet.
- **Un seul verdict pour toutes les copies** : c'est la même image, jugée une fois. La repasser au moteur doublerait la facture pour la même réponse.
- **Si la copie échoue, la recette garde l'adresse partagée** plutôt que de perdre sa photo, et l'échec est journalisé. Un partage est un risque futur ; une illustration manquante est une perte immédiate.

### Mise à jour release (19/08/2026 — v0.21.12)

#### Les photos découpées dans un scan passent enfin devant la modération

- **Le pipeline d'import publiait sans verdict.** Il découpait les photographies d'une page de livre et les écrivait en direct dans le dossier publié, avec les droits de l'Admin SDK : ni règles Storage, ni quarantaine, ni Cloud Vision. Nous venions de fermer les quatre portes clientes ; celle-ci restait ouverte, et c'est pourtant la même chose qui y passe — une photo choisie par une personne.
- **Un seul chemin, désormais, pour les deux appelants.** Le cœur de la modération a quitté le callable pour un module que le client et le pipeline empruntent tous les deux. Un second chemin de publication serait, tôt ou tard, un chemin sans verdict.
- **Une découpe refusée n'apparaît pas dans la recette**, et une découpe laissée en attente non plus — moteur injoignable, on ne publie pas. Le journal dit combien et pourquoi.
- **Trois filtres locaux écartent ce qui n'est pas une photographie**, avant même la modération : moins de 120 pixels de côté ou moins de 1,5 % de la page, rapport de forme au-delà de 4:1, ou presque blanc **et** sans couleur — du papier, ou du texte sur du papier. Les boîtes viennent d'un modèle, pas d'un détecteur géométrique : une boîte fantaisiste produisait jusqu'ici une bande de texte, téléversée comme photo du plat et conservée pour toujours.
- **Les deux conditions du dernier filtre sont exigées ensemble**, et c'est délibéré : une photographie en noir et blanc a bien une couleur nulle, mais jamais une luminance moyenne de papier. Un filtre qui l'aurait jetée aurait coûté plus qu'il ne rapporte.
- **Toutes les pages sont examinées.** Le texte d'un scan multi-pages était lu en entier ; ses photographies, elles, ne l'étaient que sur la première page — une recette étalée sur trois pages perdait les photos des deux suivantes, sans un mot. Chaque page coûte une détection : c'est le prix de ne pas les perdre.

### Mise à jour release (19/08/2026 — v0.21.11)

#### Le calendrier tenait l'écran entier, il tient maintenant dans une bande

- **Les cases faisaient deux cents pixels de côté.** La grille s'étirait sur toute la largeur disponible : sur un écran de bureau, une seule semaine occupait la moitié de la page et le détail du jour se trouvait hors champ. Une grille qu'on doit faire défiler pour voir le mois n'est plus un calendrier, c'est une liste très aérée.
- **Une bande, trois mois** : le mois courant au centre, le précédent et le suivant à ses côtés en plus petit. Un mois de contexte de chaque côté, c'est ce qu'on regarde en préparant une fin de mois ou un début de vacances.
- **La bande occupe le tiers haut de l'écran, l'agenda du jour occupe le reste.** Le calendrier est un repère, le détail est ce qu'on lit.
- **La taille d'une case se déduit des deux contraintes** — la hauteur reçue et la largeur qui reste une fois les flèches posées — jamais d'une seule. Ne regarder que la largeur donnait les cases géantes ; ne regarder que la hauteur faisait déborder le téléphone de seize pixels.
- **Sous une certaine largeur, seul le mois central reste.** Les flèches mènent toujours aux autres.
- **Choisir un jour dans un mois latéral ne fait plus sauter la bande** : le regard vient d'y aller, la recentrer le perdrait.

### Mise à jour release (19/08/2026 — v0.21.10)

#### Le planning se lit aussi au mois

- **Un second onglet, *Calendrier*, à côté de la liste** — qui, elle, ne bouge pas. Une liste chronologique répond à « qu'est-ce qu'on mange bientôt » ; elle ne répond pas à « à quoi ressemble le mois », question qu'on se pose en préparant des courses ou un week-end. Deux questions, deux lectures, les mêmes repas.
- **Les jours porteurs de repas sont surlignés**, avec une pastille par repas. Trois au plus par case : au-delà, un « +2 » dit qu'il y a plus sans prétendre le montrer — une ligne de sept points dans une case de quarante pixels ne se compte pas.
- **Un appui ouvre l'agenda du jour, sous la grille**, avec les mêmes actions que dans la liste : changer la recette, vider le créneau, l'heure, l'export calendrier, le conseil de conservation. Aucune feuille modale : on choisit un jour et on lit, sans quitter l'écran.
- **Les jours de préparation comptent aussi.** Un plat cuisiné le mardi pour le jeudi marque le mardi d'une pastille creuse et se retrouve dans l'agenda de ce jour-là, sous « À préparer ce jour-là ». Une grille qui ne montrerait que les jours de service mentirait sur la charge réelle de la semaine.
- **Les pastilles ne rejouent aucune règle.** Elles se lisent entièrement dans des champs stockés — la recette est là ou non, la date de préparation est là ou non. Colorier midi et soir aurait demandé de ramener côté client les règles de créneau, que le serveur porte seul depuis qu'elles ont quitté le client.
- **Aucun document créé, aucune requête nouvelle** : la vue range par jour les repas déjà chargés. Un mois est une position de lecture, pas une donnée du planning.
- **La flèche vers le passé s'arrête où s'arrête l'historique** — quatre-vingt-dix jours, la borne du stream. Sans ce refus, un mois vide faute de chargement se lirait comme un mois sans repas.

### Mise à jour release (19/08/2026 — v0.21.9)

#### Les outils d'amorçage quittent la maison

- **Trois entrées n'existaient que pour un travail déjà fait** : l'amorçage des rôles dans les jetons, l'audit des identifiants du référentiel d'ingrédients, et le versement de la table des poids à la pièce. Chacune a tourné, a rendu son compte, et n'avait plus d'appelant. Elles restaient déployées, gardées `admin`, à portée d'un clic — et un outil qui fusionne des documents du référentiel ne demande qu'à être relancé par distraction.
- **Une fonction déployée est une surface, pas un souvenir.** Ce qu'elles ont réparé est dans les données, pas dans le code : le garder revenait à conserver l'échafaudage après la façade.
- **L'écran *Admin › Backfills* ne propose plus que ce qui sert encore** — les KPIs du référentiel et l'enrichissement des unités et ingrédients, qui, eux, ont un usage régulier.
- La documentation qui les nommait a suivi dans le même commit : une doc qui décrit une fonction disparue envoie chercher une porte qui n'existe plus.

### Mise à jour release (19/08/2026 — v0.21.8)

#### Un filtre textuel sur le poste

- **Un champ de recherche au-dessus du tableau** ne garde que les postes dont le libellé contient ce qu'on tape. Insensible à la casse **et aux accents** : « generation » trouve « Génération de recette ». Personne ne tape les accents dans un filtre, et l'exiger transformerait l'aide en obstacle.
- **Le total sous le tableau n'additionne que ce qui est affiché**, et le dit : « Total filtré », avec le nombre de lignes retenues. Laisser le total de la période sous une liste filtrée afficherait une somme que les lignes au-dessus ne font pas — un chiffre faux qu'on ne remarque jamais, parce qu'il reste plausible.
- **Le chiffre en tête d'écran, lui, ne bouge pas.** C'est le coût de la période, sa référence ; un filtre de lecture ne réécrit pas ce qu'on a dépensé.
- **Sans correspondance, le champ reste affiché** avec un message qui nomme la recherche. C'est lui qu'il faut corriger : le masquer enfermerait dans le vide qu'on cherche à quitter.
- Une croix efface le filtre d'un geste.

### Mise à jour release (19/08/2026 — v0.21.7)

#### Le tableau des coûts d'IA se trie par ses en-têtes

- **Chaque colonne est cliquable** : poste, appels, coût unitaire, total, pour Claude, pour Gemini et pour l'ensemble. Un second clic inverse le sens. Par défaut, le plus cher en tête — c'est la question qu'on se pose en ouvrant cet écran.
- **Une colonne vide reste en bas, dans les deux sens.** Un poste qui n'a jamais appelé Claude affiche « — », et « — » ne veut pas dire zéro : il n'a pas de coût unitaire, il n'en a aucun. Le trier comme un zéro l'aurait placé en tête d'un tri croissant, c'est-à-dire présenté comme le moins cher — exactement le contraire de la vérité.
- **Les égalités se départagent par le libellé.** Deux postes au même montant gardaient sinon un ordre arbitraire, qui changeait à chaque rafraîchissement de l'écran.
- **La ligne de total reste en bas**, quel que soit le tri : c'est une somme, pas une ligne comme les autres.
- Le tri survit au passage de « Par poste » à « Par processus » : on change d'axe de lecture, pas de question.

### Mise à jour release (18/08/2026 — v0.20.28)

#### L'écran ne s'éteint plus pendant qu'on cuisine

- **Une recette ouverte garde l'écran allumé.** On cuisine les mains occupées, farineuses ou mouillées : la fiche restait affichée sans qu'on la touche, l'écran s'éteignait au milieu d'une étape, et c'est le seul moment où on ne peut pas le rallumer.
- **Le maintien vaut pour toute la fiche**, pas seulement pour le mode cuisine : on lit aussi les ingrédients, la nutrition et les commentaires sans toucher l'appareil.
- **Il s'arrête en quittant la recette** — et pas avant. Deux recettes ouvertes l'une sur l'autre le demandent chacune ; refermer celle du dessus n'éteint pas l'écran de celle qui reste.
- **Revenir d'un appel ou d'un autre onglet le rétablit** : navigateurs et Android relâchent ce verrou dès que l'application passe en fond, sans jamais le rendre d'eux-mêmes.
- Android, iOS, web et Windows. Si la plateforme refuse — un navigateur peut le faire — la recette s'affiche normalement, l'écran s'éteint comme avant, et le refus est remonté une fois.

### Mise à jour release (18/08/2026 — v0.20.27)

#### L'envoi vers Tasks ouvre les tâches

- **Un onglet s'ouvre sur vos tâches** dès que la liste est partie — c'est là qu'on va ensuite. Sur mobile, l'application Google Tasks capte le lien si elle est installée.
- **Le bandeau garde un bouton « Ouvrir »**, parce qu'un navigateur peut refuser une ouverture qui ne suit pas immédiatement un geste : après une trentaine d'appels réseau, le lien n'est plus considéré comme déclenché par vous. Ce bouton-là, lui, l'est.
- Il n'existe pas d'adresse stable vers une liste précise — l'identifiant rendu par l'API n'est pas celui de l'interface. On ouvre donc les tâches, où la liste du jour figure en tête du sélecteur.

### Mise à jour release (18/08/2026 — v0.20.26)

#### La liste de courses part dans Google Tasks, cochable et rangée

- **Keep n'a pas d'API d'écriture.** L'envoi passait donc par le presse-papier : à vous de créer la note, de la convertir en cases à cocher, et de refaire les rayons — que Keep aplatit en une ligne par article, en-têtes compris. Ce n'était pas un défaut de l'application, c'était la seule chose que Keep permet.
- **Google Tasks, lui, reçoit exactement ce qu'on veut lui donner** : un **rayon par tâche**, un **article par sous-tâche**, tout cochable. Une liste prête, sans une manipulation.
- **L'ordre des rayons est conservé** — celui de la liste, donc celui du magasin. Sans précaution, l'API place chaque insertion en tête et rend la liste à l'envers.
- **Seuls les articles non cochés partent** : ce qui est déjà dans le panier n'a rien à faire sur une liste de courses.
- **Le bouton Keep reste**, en second, pour qui vit dans Keep — et il dit maintenant franchement ce qu'il faudra faire à la main.
- L'autorisation suit la même mécanique que l'export vers Google Agenda : un consentement au premier envoi, puis un jeton gardé le temps de la session.

#### La correction orthographique par IA est retirée

- **Elle ne tenait pas ses promesses**, et une fonction qui échoue à chaque essai vaut moins que pas de fonction. Retirée entièrement : module, prompt, entrée HTTPS, bouton, et la fonction déployée elle-même — aucun code mort, ni dans le dépôt, ni dans le projet Firebase.
- **Le poste reste au catalogue des coûts**, marqué « retiré ». C'est la règle du projet : des appels ont été comptabilisés sous cette clé, et un mois déjà chiffré ne doit pas perdre le nom de ce qu'il a payé.
- Le défaut de lecture qui l'avait motivée — « les carotte » sur une fiche imprimée — est réglé autrement, par les badges du PDF.

### Mise à jour release (18/08/2026 — v0.20.25)

#### Le PDF porte les mêmes badges que l'écran

- **Le PDF imprimait le CookLang débarrassé de sa syntaxe.** « Émincer finement le poivron, les carotte » : rien ne disait au lecteur que « carotte » n'était pas un mot de la phrase, mais une **référence structurée** reprise de la liste d'ingrédients. Deux gênes d'un coup — une faute d'accord apparente, et une syntaxe devenue invisible.
- **Les jetons sont désormais des badges**, comme les puces de l'application : ingrédients sur fond d'accent clair, matériel et minuteurs sur fond gris. « les ⟦2 carottes⟧ » se lit sans heurt, parce qu'un badge s'annonce comme une donnée et non comme un mot accordé.
- **Le badge porte la même chose que la puce** : la quantité accordée pour un ingrédient, le nom pour un ustensile, la durée en clair pour un minuteur — « 12 minutes », plus « 0:12:00 ».
- **Les notes aussi**, dans leur ton propre.

#### Et la correction de prose lit enfin la réponse du moteur

- **« Réponse pas exploitable » à chaque essai.** La passe appelait `JSON.parse` sur la réponse brute : un simple bloc de code Markdown suffisait à tout faire échouer. Elle passe désormais par `askJson`, le seul endroit du projet qui sait lire une réponse de modèle — enrobage, phrase d'introduction, virgule finale.
- **Les fragments sont numérotés dans la réponse**, et non plus attendus dans l'ordre : un modèle qui fusionnait deux fragments minuscules faisait abandonner toute la passe. Un fragment manquant ne coûte plus que lui-même.
- **Un abandon laisse une trace** dans les journaux, avec sa cause. Sans elle, « pas exploitable » restait un message d'écran sans explication.

C'est la réponse la moins coûteuse au problème d'accord : là où l'écran ne posait de question à personne, le papier en posait une — parce qu'il avait perdu la distinction entre le texte et les données. Le badge la lui rend.

### Mise à jour release (18/08/2026 — v0.20.24)

#### Une correction orthographique qui ne peut pas casser une recette

Le rendu ne corrigera jamais une faute écrite **dans** le texte — « Chauffer l'poêle » est dans la recette, pas dans son affichage. D'où cette passe, et d'où sa forme.

- **Un nouveau bouton dans l'éditeur** (icône correcteur, à côté du bouton IA) : *Corriger l'orthographe du texte des étapes*.
- **Le modèle ne voit jamais la recette.** Il reçoit une liste numérotée de **fragments de texte** extraits d'entre les balises, et rend la même liste corrigée. Le réassemblage est mécanique : chaque `@ingrédient{}`, `#matériel{}`, `~minuteur{}`, chaque métadonnée `>>`, chaque en-tête de section et chaque image ressort **identique, octet pour octet**. La sûreté ne vient pas d'une consigne de prudence donnée au modèle, mais du fait qu'on ne lui met aucun balisage entre les mains.
- **Trois garde-fous, tous vérifiables.** Une liste d'une autre longueur est rejetée en bloc. Un fragment qui revient avec `@`, `#`, `~`, `{` ou `}` alors qu'il n'en avait pas est ignoré — le modèle a inventé une balise. Un fragment qui double ou disparaît est ignoré : une correction orthographique ne réécrit pas une phrase. Un fragment refusé garde sa version d'origine.
- **Rien n'est appliqué sans que vous l'ayez vu.** Une fenêtre montre les lignes concernées, avant et après, et vous appliquez ou non. Une correction automatique qu'on découvre à l'impression n'est plus une correction, c'est une surprise.
- **Une passe qui ne change rien le dit**, et une passe abandonnée aussi — plutôt qu'un succès silencieux qui laisserait croire la recette relue.

**Pourquoi ne pas avoir réutilisé la relecture existante** : `polishCooklang` réécrit le document entier, noms d'ingrédients compris. C'est utile sur un brouillon brut, et destructeur ensuite — le nom d'un ingrédient est son identité, celle dont dépendent la nutrition, la liste de courses, la recherche et les catégories. Et la correction ne tiendrait pas : la normalisation référentielle réécrit chaque balise depuis le référentiel au prochain enregistrement.

Le poste **Orthographe de la prose** apparaît dans les coûts et bascule entre Gemini et Claude depuis *Admin › Moteur d'IA*, comme tous les autres.

### Mise à jour release (18/08/2026 — v0.20.23)

#### C'est l'article qui donne le nombre, et les minuteurs se lisent

- **« les carotte » survivait à la correction précédente.** Celle-ci accordait le nom d'après la quantité du jeton — or dans la prose, un ingrédient s'écrit le plus souvent **sans quantité** : `les @carotte{}`, la quantité vivant dans la liste. Sans quantité, pas d'accord. C'est désormais **l'article qui précède** qui commande : « les » met au pluriel, « le », « la », « l' » gardent le singulier, et un numéral compte comme un pluriel. C'est le signal que lit un humain — il tient dans les deux mots d'avant, et il est toujours là.
- **L'article l'emporte sur la quantité.** Une recette peut annoncer deux poivrons dans sa liste et n'en mettre qu'un dans une étape : c'est la phrase qui a raison.
- **Les minuteurs se lisent enfin dans le PDF** : « Cuire 12 minutes » au lieu de « Cuire 0:12:00 ». La valeur brute du jeton y était imprimée telle quelle, alors que l'application la met en forme depuis toujours. Le formatage a quitté la couche présentation pour que les deux s'en servent.

**Ce que le rendu ne corrigera jamais** : une faute d'écriture dans la prose libre. « Chauffer l'poêle » est dans le texte de la recette, pas dans son affichage — et choisir entre « le » et « la » demande un genre que l'application ne connaît pas. Cela se corrige à la main dans l'éditeur, ou par une passe d'IA limitée aux segments de texte **entre** les jetons.

### Mise à jour release (18/08/2026 — v0.20.22)

#### Les ingrédients s'accordent enfin

Une fiche imprimée disait « 3 Cuillère à soupe sauce soja », « 1 pièces poivron », « 2 gousse ail », et dans une étape « Émincer finement le poivron, les carotte ». Aucune de ces lignes n'était une faute de l'IA : c'étaient des **identifiants affichés comme du texte**.

- **`Cuillère à soupe` est un libellé de référentiel**, écrit pour un tableau d'administration — majuscule et singulier. Dans une phrase, il se lit désormais « 3 cuillères à soupe **de** sauce soja ».
- **`carotte` est le nom canonique de l'ingrédient**, celui qui sert à l'appariement nutritionnel, à la liste de courses et à la recherche. Il s'accorde maintenant à l'affichage — « les carottes » — sans que rien ne change en base.
- **L'unité qui compte disparaît** : on écrit « 2 carottes », jamais « 2 pièces carotte ». C'est le nom qui porte le nombre.
- **La liaison est faite** : « 2 gousses **d'**ail », « 500 g **d'**émincé de bœuf », mais « 200 g **de** haricots verts » — le h aspiré ne s'élide pas.
- **Un symbole reste un symbole** : « 500 g », jamais « 500 gs ».
- **Le singulier tient jusqu'à deux**, comme en français : « 1,5 litre ». Une quantité illisible — « quelques » — laisse le singulier plutôt que de deviner.

**Rien n'est réécrit dans la recette.** Corriger le CookLang aurait cassé l'identité dont dépendent quatre chaînes — nutrition, courses, index de recherche, catégories — et aurait de toute façon été effacé au prochain enregistrement, puisque la normalisation référentielle réécrit chaque `@nom{}` à partir du référentiel. C'est **le rendu** qui a été corrigé : la fiche, les étapes, la liste de courses et l'export PDF partagent la même règle, et **toutes les recettes déjà en base sont corrigées d'un coup**, réimpression comprise.

Règles d'affichage, donc **client uniquement** : le serveur n'affiche rien, et en écrire un jumeau TypeScript n'ajouterait qu'une divergence possible.

### Mise à jour release (18/08/2026 — v0.20.21)

#### La dépense par utilisateur a son écran, et le plafond passe en euros

- **Un écran à part**, *Admin › Dépense par utilisateur*, au lieu d'une carte posée en haut des coûts mensuels. Les deux questions ne se posent pas au même moment : les coûts mensuels disent **combien l'application coûte**, celui-ci dit **qui dépense, à quoi, et jusqu'où il peut aller**. La seconde a besoin de place — une ligne par compte, un détail par poste.
- **Le détail par service, compte par compte.** Chaque personne se déplie sur la liste de ses postes — scan, nutrition, dressage, planning — du plus cher au moins cher. Cette ventilation n'existait nulle part : l'agrégat mensuel savait dire le total d'un compte et le total d'un poste, jamais lequel des deux enfants fait tourner le générateur d'images.
- **Le même sélecteur de période que les deux autres onglets** — ce mois, 3, 6, 12 mois, depuis le début — et le même réglage : une période choisie ici se retrouve là-bas.
- **Les mois antérieurs n'ont pas ce détail** et l'écran le dit, plutôt que d'afficher un vide qui se lirait « rien dépensé ». Une reconstruction des agrégats les rattrape.
- **Le plafond se règle désormais en euros**, la monnaie du foyer, et non plus en dollars. Les fournisseurs facturant en dollars, la comparaison passe par le taux relevé sur la facture. **Sans taux, le plafond en euros ne s'applique pas** : le projet refuse d'inventer un taux, et c'est le plafond en nombre d'appels qui protège seul — l'écran l'annonce en clair, et le journal aussi.
- **Le compte fondateur dispose de cinq fois le plafond.** Règle écrite dans le code et non en base : elle dit que le propriétaire du projet est aussi celui qui l'éprouve — c'est lui qui importe des livres entiers et régénère des séries de visuels. La poser en base en ferait un privilège transmissible par n'importe quel administrateur. Le multiplicateur porte sur **les deux** plafonds, sans quoi le compteur d'appels bloquerait précisément celui qui a le droit d'en faire cinq fois plus. Et il reste un plafond : cinq fois plus haut, pas illimité.
- **L'identité du fondateur est lue dans Auth**, jamais dans le champ `email` du document utilisateur — qu'un administrateur peut écrire. Un privilège ne se fonde pas sur une donnée qu'un tiers peut poser.
- **L'alerte mensuelle est en euros** elle aussi, et se tait en le disant quand aucun taux ne permet de la calculer : un silence se lirait « rien à signaler ».

### Mise à jour release (17/08/2026 — v0.20.20)

#### La dépense d'IA a enfin un plafond

- **Le projet mesurait au centime sans jamais limiter.** Le contrôle d'accès dit *qui* appelle, l'attestation dit *quel programme* appelle ; aucun des deux ne dit **combien de fois**. Restaient entiers : un jeton égaré sur l'appareil d'un membre de la famille, un membre qui s'amuse, et surtout une boucle dans notre propre code — celle-là, aucune attestation ne l'arrêtera jamais.
- **Deux plafonds par compte et par jour**, et non un seul. Le plafond en dollars est le naturel ; mais quand la grille tarifaire est illisible, le projet refuse de chiffrer et les appels sont enregistrés **sans montant**. Un plafond uniquement monétaire s'ouvrirait donc en grand exactement pendant la panne où plus rien n'est chiffré. Le second plafond compte les **appels**, et ne dépend d'aucun prix. Le premier des deux atteint ferme la porte.
- **Le refus arrive avant la dépense**, aux deux seuls endroits d'où l'argent part : le routeur de texte — donc aussi tout ce que déclenche le pipeline d'import, que les gardes HTTPS ne voient pas — et la production d'image. Le message dit ce qui est atteint et quand cela se rouvre, sans jargon.
- **Un plafond atteint ne touche que ce compte.** Les autres continuent de cuisiner.
- **Un import coupé par le plafond ne se réessaie pas** : il part directement en dead letter, avec le motif, d'où un administrateur le relance demain — ou après avoir relevé la limite. Réessayer trois fois refait tout le travail qui précède l'appel d'IA pour se heurter au même mur.
- **Les réglages vivent dans Firestore**, pas dans le code : *Admin › Coûts* affiche ce que chaque compte a consommé aujourd'hui, la part de plafond déjà mangée, et permet de relever la limite en une minute — le jour où un import massif se fait couper au milieu, il ne faut pas attendre un déploiement. Un interrupteur coupe les deux plafonds sans les effacer.
- **Les défauts protègent avant tout réglage** : deux dollars et quatre cents appels par compte et par jour. Une soixantaine de visuels de dressage, des milliers d'appels de texte — personne ne les atteindra en cuisinant, une boucle les atteint en quelques secondes. C'est un défaut assumé : un plafond est une *décision*, pas une mesure, et l'absence de document ne doit pas vouloir dire « aucune limite ».
- **Une alerte mensuelle**, vérifiée chaque matin plutôt que le mois suivant : une alerte qui arrive après la facture n'est pas une alerte. Elle se déclenche une fois par mois au franchissement du seuil, et signale au passage combien d'appels sont restés sans montant — un mois traversé par une panne de grille paraîtrait sinon simplement économe.

### Mise à jour release (17/08/2026 — v0.20.19)

#### L'interrupteur d'arrêt ne dépend plus de ce qu'il coupe

- **L'écran d'attestation passait lui-même par le contrôle d'attestation.** En mode *Exigé*, un client non attesté — le téléphone, le desktop — ne pouvait donc plus ni lire le mode ni le changer : il affichait « Politique illisible ». Tant qu'un autre client atteste, il reste une issue ; le jour où l'attestation refuse à tort — reCAPTCHA en panne, clé expirée —, *Exigé* devenait définitif pour tout le monde. La clé était enfermée dans la pièce.
- **Les deux postes qui lisent et écrivent le mode sont désormais exemptés**, en toutes circonstances. Ils exigent toujours le rôle administrateur, ne coûtent rien, et n'exposent qu'un mot parmi trois. L'appel reste journalisé : savoir qu'un client non attesté vient changer le mode a de la valeur.
- **Passer en *Exigé* reste impossible depuis un client non attesté.** L'exemption ouvre la marche arrière, pas la marche avant.

### Mise à jour release (17/08/2026 — v0.20.18)

#### Trois portes de dépense refermées

- **Générer une illustration redevient un geste d'éditeur.** Le poste coûte 0,0336 $ l'image et se contentait d'un compte connecté, alors que le visuel de dressage exigeait déjà le rôle éditeur et que l'amélioration de photo est réservée aux administrateurs. Un lecteur pouvait donc dépenser en boucle ce que la même famille de postes lui refusait à côté. Le bouton disparaît aussi de l'onglet Illustrations pour qui n'est pas éditeur : proposer une action que le serveur refusera ne donne qu'un message d'erreur sans explication.
- **Chaque entrée HTTPS est plafonnée à dix instances simultanées.** Sans plafond, une boucle — la nôtre autant qu'une malveillante — ouvrait autant d'instances que le projet l'autorise, cent par défaut, chacune servant quatre-vingts requêtes qui partent toutes chez Gemini ou Anthropic. Dix tiennent largement une famille. Ce plafond borne le *parallélisme*, pas le total dépensé : le plafond par compte reste à écrire.
- **La quarantaine n'accepte plus que ce qu'un import produit** — photo, PDF, document Word, texte collé. Elle prenait n'importe quel fichier jusqu'à cinquante mégaoctets : le bucket servait d'hébergement gratuit à qui possédait un compte, et rien dans le suivi de stockage n'aurait distingué ces octets-là des recettes de la famille. Le fichier reste inspecté par le serveur avant d'être promu ; ce contrôle-ci évite seulement que le dépôt serve à autre chose.

### Mise à jour release (17/08/2026 — v0.20.17)

#### La clé était dans le code, pas dans le déploiement

- **Le bundle web publié en v0.20.16 ne contenait pas la clé reCAPTCHA.** Le compilateur web incrémental n'avait pas repris la modification : `flutter build web` a rendu un `main.dart.js` antérieur à l'édition, sans le signaler, et le déploiement l'a publié. Le client ne pouvait donc produire aucun jeton — le serveur voyait `app: MISSING`, et l'écran d'attestation restait rouge sans raison apparente.
- **Le symptôme s'était pourtant laissé lire dans le binaire** : la constante de clé était absente du bundle, ainsi que toute trace du fournisseur reCAPTCHA. Une constante qui disparaît d'un build alors que le code qui l'entoure y figure signale que personne ne la lit — ici, que l'attestation n'était pas compilée du tout.
- **Le déploiement était sain, le build ne l'était pas.** `flutter clean` échouait lui-même sur un dossier verrouillé (`windows/flutter/ephemeral`) et laissait le cache de build intact : la reconstruction « réussissait » en 1,7 seconde sans rien recompiler. Il a fallu supprimer `build/web` et `.dart_tool/flutter_build` à la main.
- **Vérification retenue** : après un build, la présence de la clé dans `build/web/main.dart.js` se contrôle en une commande. Un bundle qui compile n'est pas un bundle à jour.

### Mise à jour release (17/08/2026 — v0.20.16)

#### Le client web atteste pour de bon

- **La clé reCAPTCHA est posée.** Le mécanisme d'attestation était complet depuis la version précédente, mais inerte sur le web faute de clé de site : tous les appels partaient non attestés. Le client web produit désormais un jeton d'attestation à chaque appel.
- **La clé vit dans le code, et c'est correct.** Une clé de *site* s'affiche dans la page, comme celle de n'importe quel formulaire protégé par reCAPTCHA — la mettre en secret n'aurait rien caché, et aurait ajouté un `--dart-define` au déploiement pour une donnée que le navigateur reçoit de toute façon. La clé *secrète*, elle, n'existe pas dans ce mode : reCAPTCHA Enterprise n'en délivre pas.
- **Rien n'est encore exigé.** Le mode reste *Observation* : les journaux vont maintenant dire lesquels des clients attestent — web, Android, desktop — avant toute décision de refuser.

### Mise à jour release (17/08/2026 — v0.20.15)

#### L'application s'atteste — App Check

- **Le contrôle d'accès savait qui appelle, pas quoi appelle.** Une Cloud Function callable est une URL HTTPS publique et devinable ; la seule chose qu'elle exigeait était un jeton d'identité, lequel s'obtient avec la clé web — publique par conception — ou se recopie depuis le navigateur d'un membre de la famille. L'application et une boucle dans un terminal étaient indiscernables côté serveur, et chaque appel part chez Gemini ou Anthropic. La liste d'origines CORS ne protège de rien ici : c'est une règle que les navigateurs s'imposent, et un script n'en a pas.
- **Le client atteste désormais son authenticité** : reCAPTCHA Enterprise sur le web, Play Integrity sur Android, DeviceCheck sur iOS. Le jeton d'attestation accompagne chaque appel, et les trois gardes des Cloud Functions le vérifient — donc les vingt-sept entrées d'un coup, administration comprise.
- **Trois modes, pilotés depuis *Admin › Attestation de l'application*, pas par un déploiement.** *Désactivé* ne vérifie rien ; *Observation* — le défaut — ne refuse rien mais journalise chaque appel non attesté, avec le poste et l'agent utilisateur ; *Exigé* refuse. Le silence des traces d'observation est la condition pour exiger : ce sont elles qui disent ce qu'on couperait. Une bascule prend effet en moins d'une minute, dans les deux sens — le jour où l'attestation refuse à tort, il faut rouvrir tout de suite, et un interrupteur qui demande un déploiement n'est pas un interrupteur.
- **L'écran refuse de vous verrouiller dehors.** Il affiche si l'appel qui l'a chargé était lui-même attesté, et le serveur rejette le passage en *Exigé* demandé depuis un client non attesté. C'est la leçon de la clé Anthropic : une bascule sans effet reste une énigme pour celui qui l'a demandée.
- **Le client Windows desktop n'atteste pas**, et le dit franchement : sa seule voie serait un jeton de débogage, c'est-à-dire un secret partagé dans un binaire distribué. Passer en *Exigé* le prive donc de l'IA. Cette limite ne se contourne pas par une exemption de plateforme — la plateforme est déclarée par le client, donc par un attaquant aussi.
- **Rien n'est encore exigé.** Le mode par défaut observe : un déploiement qui se mettrait à refuser des appels sans que personne l'ait demandé serait une panne, pas une sécurisation. L'attestation web attend par ailleurs sa clé reCAPTCHA, à créer dans la console Firebase.
- **Ce qu'App Check ne fait pas** : il vérifie *quel programme* appelle, jamais *combien de fois*. Un plafond de dépense par compte reste à faire, et c'est lui qui protégerait aussi de nos propres bugs.

### Mise à jour release (17/08/2026 — v0.20.14)

#### Le rôle ne se choisit plus soi-même, et la bibliothèque a une porte

- **N'importe qui pouvait devenir administrateur.** Le rôle d'un compte neuf était décidé par l'application — elle comptait la collection `users` et s'attribuait `admin` si elle la trouvait vide — et les règles Firestore ne contrôlaient aucun champ à la création. Il suffisait donc de se connecter avec un compte Google et d'écrire soi-même son propre document avec `role: "admin"`, hors application, pour obtenir tous les droits : le déclencheur qui recopie le rôle dans le jeton faisait confiance au document. Les règles imposent désormais `pending` à la création, ainsi que l'adresse du jeton, et **seul un administrateur nomme**.
- **Le compte fondateur est le seul administrateur d'origine.** Un déclencheur serveur lui rend le rôle `admin` en vérifiant l'adresse du compte *Auth* — jamais celle inscrite dans le document, qu'un client a pu écrire. Il le rétablit aussi s'il est rabaissé ou révoqué, et les règles interdisent à quiconque d'autre de toucher à son rôle : un administrateur adoubé ne peut pas destituer celui qui l'a nommé.
- **Être connecté ne donne plus accès à rien.** Tout compte Google qui se connectait lisait aussitôt l'intégralité des livres et des recettes de la famille. Un compte neuf attend maintenant d'être nommé : il voit une salle d'attente qui affiche son adresse, et rien d'autre. L'écran se referme de lui-même dès l'approbation. L'écran d'administration met ces demandes en tête de liste, sous un bandeau qui les compte.
- **Révoquer un éditeur ou un administrateur ne faisait rien.** Le contrôle de révocation n'était appliqué qu'aux lecteurs : un éditeur révoqué continuait d'écrire livres, recettes et référentiels, et un administrateur révoqué gardait l'administration. La révocation vaut désormais pour tous les rôles, côté règles comme côté Cloud Functions.
- **Les vingt-sept entrées d'IA ne sont plus gardées par la seule présence d'un compte.** Elles dépensent de l'argent à chaque appel : un compte en attente ou révoqué les atteignait aussi bien qu'un membre de la famille. Chaque appel vérifie maintenant le rôle porté par le jeton, et relit le document quand le jeton n'en porte pas encore — une lecture Firestore vaut moins qu'un appel d'IA laissé passer.
- **Les lignes de coût d'IA ne peuvent plus être fabriquées par un client.** Seules les Cloud Functions les écrivent, mais la règle de création leur était ouverte : n'importe quel compte pouvait inscrire des dépenses imaginaires que la réconciliation mensuelle aurait présentées comme réelles. Un montant faux ne se voit pas.
- **Les dépôts de fichiers suivent la même règle.** Les règles Storage laissaient écrire tout jeton sans claim de rôle — précaution du temps de la migration, aujourd'hui périmée, et qui aurait suffi à un compte en attente pour déposer des images dans les dossiers partagés. Les envois exigent désormais un rôle explicite. Les *lectures*, elles, restent ouvertes à tout compte actif : les fermer ferait clignoter les images de qui n'a pas encore renouvelé son jeton, pour un gain nul.

### Mise à jour release (17/08/2026 — v0.20.13)

#### Toutes les sections de la fiche se replient

- **Nutrition, Dressage et Communauté** portent désormais le même en-tête que Catégorisation, Ingrédients et Préparation : icône, titre, chevron, et un appui qui les replie. Elles étaient les seules à s'imposer en entier — sur un téléphone, quatre sections dépliées font un écran qu'on parcourt au pouce sans jamais retrouver la préparation.
- **Chacune s'ouvre dépliée**, comme les autres : replier reste un geste, jamais un état imposé à l'ouverture.
- **« Voir tout » de la section Communauté reste dans l'en-tête**, donc joignable même repliée.

### Mise à jour release (17/08/2026 — v0.20.12)

#### L'affichage compact cesse d'être une version amoindrie

- **La recette d'abord, puis nutrition, dressage et communauté.** En affichage compact, la fiche s'ouvrait sur le détail nutritionnel — avant même les ingrédients — et le **dressage n'existait tout simplement pas** hors mode cuisine, où il prenait la place de la communauté. Les quatre sections sont désormais empilées dans l'ordre de lecture : la recette, puis Nutrition, Dressage et Communauté, chacune sous son titre, et **aucune ne dépend plus du mode cuisine**. C'est le même contenu que les quatre onglets du grand écran.
- **Le document original est de nouveau joignable.** Le bouton « Voir / télécharger l'original » vivait dans la barre du grand format ; sous 700 px de large, le scan d'où venait la recette n'apparaissait nulle part. Il est maintenant dans la barre compacte, comme sur la page de livre et sur le brouillon, qui l'avaient toujours gardé.
- **La couverture d'une recette libre se change depuis le menu.** Le geste n'existait que sur la vignette de la barre large, absente en compact : son propriétaire ne pouvait plus la remplacer. Une entrée de menu le permet, et annonce l'envoi en cours.
- **Les puces de note, de remarques, d'astuces et de corrections reviennent à côté du titre.** Elles disaient d'un coup d'œil ce que la recette avait accumulé ; en compact, il fallait ouvrir la feuille communauté pour le découvrir. Un appui sur une puce y mène toujours.

### Mise à jour release (17/08/2026 — v0.20.11)

#### Le conseil de conservation ne s'écrit plus en double

- **La section en fin de recette disparaît.** Le conseil y était recopié sous « Conservation et réchauffage ». Depuis que le bandeau le montre là où la question se pose, cette copie n'apportait rien — et elle s'affichait mal : le rendu numérotait son titre et son résumé comme les étapes **6** et **7** de la préparation, à la suite de la vraie recette.
- **Il ne vit plus qu'à un seul endroit**, sur la recette, et se lit dans le bandeau et dans la feuille du planning. Deux copies d'un même conseil, c'était deux versions à tenir d'accord qu'une régénération pouvait faire diverger.
- **Les recettes qui portent encore la section s'en débarrassent seules**, à leur première ouverture par quelqu'un qui a le droit de les modifier. Une section « Conservation » que vous auriez écrite à la main n'est jamais touchée : seul le titre exact posé par l'application est reconnu.
- **Générer la conservation depuis la planification** ne modifie plus le texte de la recette : le conseil est produit, stocké, affiché, et c'est tout.

### Mise à jour release (17/08/2026 — v0.20.10)

#### La recette d'un plat cuisiné à l'avance le dit dès son ouverture

- **Le contexte du repas suivait la recette à moitié.** Le planning marquait bien « Préparé le dimanche 23 · réfrigérateur », mais ouvrir la recette depuis ce créneau donnait la fiche ordinaire : ni refroidissement, ni durée de garde, ni réchauffage, ni ce qu'il faut garder pour le dernier moment. Toute la question de la conservation restait sur l'écran précédent, celui qu'on a justement quitté pour aller cuisiner.
- **Un bandeau ouvre désormais la fiche** quand elle vient d'un repas préparé un autre jour : le jour de préparation, le jour du repas, le mode imposé par le délai réel — réfrigérateur jusqu'à trois jours, congélateur au-delà — et la consigne complète. Cette partie est **calculée**, comme dans le planning : elle s'affiche même si l'IA ne répond pas.
- **Le conseil propre au plat se produit tout seul**, à la première ouverture depuis un tel créneau, et se déplie sous le bandeau : contenant, ce qui se dégrade en premier, congélation possible ou non, méthode et température de réchauffage, ce qu'il vaut mieux ajouter au dernier moment, signes qu'il ne faut plus le manger. Il n'était jusqu'ici accessible que par le menu d'un repas au planning.
- **Il ne se repaie jamais.** Le conseil décrit le plat et non le créneau : produit une fois, il sert à toutes les planifications de cette recette et à toutes ses lectures.
- **Rien n'est écrit sur la recette partagée.** Les deux dates voyagent dans l'adresse, exactement comme les portions du repas : la même recette ouverte depuis un livre, ou depuis le repas d'un autre membre de la famille prévu un autre jour, reste ce qu'elle est.
- **En panne d'IA, le bandeau le dit** et propose de réessayer, sans jamais remplacer le conseil manquant par un texte générique — la consigne calculée, elle, reste affichée.

### Mise à jour release (15/08/2026 — v0.20.7)

#### Trois duplications de moins, et le dernier chiffre figé dans le code

- **Le taux de change n'a plus de valeur de secours.** Un `0.92` dormait dans le code, prêt à convertir des dollars en euros dès que le taux réel manquerait — le même défaut que les prix, appliqué à la devise. Il est supprimé. Sans taux relevé, les montants restent affichés **en dollars**, ce qui est vrai. C'était le dernier chiffre de facturation figé dans le code.
- **Le planning ne rejoue plus les règles du serveur.** Quand l'IA laissait un créneau vide, l'application le comblait elle-même en rejouant les règles de variété, de dessert et de jour de préparation. Ce filet coûtait la duplication entière de ces règles pour un service douteux : il **masquait** qu'aucune suggestion n'avait été rendue, et la recette qu'il choisissait s'affichait comme une décision de l'IA. Un créneau reste désormais vide — et le menu ✨ sait le compléter à la demande.
- **Le calcul du mois de facturation n'existe plus qu'une fois côté serveur.** Il vivait en quatre exemplaires : consommation, coûts Anthropic, agrégats mensuels, périodes de facturation. Quatre copies de trois lignes dont personne n'aurait remarqué la divergence — un mois décalé ne casse rien, il compare simplement deux périodes différentes et présente l'écart comme un fait.

### Mise à jour release (15/08/2026 — v0.20.6)

#### Un prix faux ne vaut pas mieux qu'un prix absent

- **Plus aucun tarif de secours.** La version précédente affichait les prix livrés avec le code quand la grille était illisible. C'était un mauvais réflexe : un tarif périmé présenté comme le tarif réel produit un montant crédible et faux, exactement ce que le suivi des coûts existe pour empêcher. Désormais, une grille illisible affiche **« Tarifs en panne »**, avec un bouton pour réessayer, et aucun prix.
- **Les appels passés pendant une panne sont enregistrés sans montant.** Leurs jetons sont connus, leur coût ne l'est pas : ils sont comptés séparément plutôt qu'ajoutés à zéro. Un mois traversé par une panne affichait sinon un total plus bas — et parfaitement crédible.
- **La confirmation avant dépense le dit aussi.** Avant une série de visuels de dressage, si la grille est indisponible, l'écran annonce qu'il ne peut pas chiffrer plutôt que d'avancer un montant inventé.
- **La reconstruction des agrégats refuse de tourner** sans grille : elle réécrirait des montants déjà publiés à partir de rien.
- **Les prix ne sont plus écrits qu'à un seul endroit.** L'application ne porte plus aucune table de tarifs : elle lit celle du serveur. La table du code ne sert qu'une fois, à créer le document la première fois. C'était la dernière duplication de prix du projet, et la plus sournoise.

### Mise à jour release (15/08/2026 — v0.20.5)

#### Les tarifs d'IA se corrigent sans redéployer

- **La grille tarifaire quitte le code.** Les prix des modèles vivaient en dur, en deux exemplaires — un côté application, un côté serveur. Corriger un tarif après un changement de fournisseur demandait un déploiement, et jusque-là le reporting chiffrait faux sans que rien ne le signale. La grille en vigueur est désormais un document Firestore, éditable depuis *Admin › Moteur d'IA*, comme le routage entre Gemini et Claude.
- **Un tarif modifié prend effet en moins d'une minute**, et ne chiffre que les appels à venir. Les montants déjà enregistrés restent figés au tarif qui avait cours au moment de l'appel : un historique de dépense ne se réécrit pas.
- **Les prix livrés avec le code deviennent le repli.** Table injoignable, document absent, modèle jamais renseigné : le calcul continue avec la valeur d'origine. Un coût tombé à zéro dans le silence serait pris pour une bonne nouvelle.
- **Une saisie invalide est refusée, jamais devinée.** Un tarif non numérique ou négatif fait rejeter l'entrée entière et écrire un avertissement dans les logs, avec le nom du modèle concerné. Retenir la moitié d'une entrée reviendrait à facturer l'autre moitié à zéro.
- **Une promotion sans date de fin lisible est ignorée** : sans borne, une remise devient un tarif permanent le jour où elle expire.
- **L'écran distingue ce qui a été modifié** de ce qui vient du code, et un bouton rend la main au tarif d'origine. On peut aussi ajouter un modèle absent de la grille — utile le jour où un fournisseur en sort un nouveau.
- **L'annonce de coût avant dépense lit la même grille** : la confirmation qui précède une série de visuels de dressage ne peut plus citer un ancien prix.

### Mise à jour release (15/08/2026 — v0.20.4)

#### Vos portions n'écrasent plus celles des autres

- **Changer le nombre de parts réécrivait la recette de tout le monde.** Le recalcul nutritionnel écrivait son résultat sur le document de la recette, estampillé du nombre de parts de celui qui avait bougé le curseur en dernier. Sur une recette de famille, vous passiez à 8 parts, quelqu'un repassait à 2, et votre fiche affichait les valeurs pour 2. Aucune erreur, aucune alerte : la valeur changeait simplement de propriétaire.
- **Il n'y avait rien à déplacer, seulement à cesser d'écrire.** Sur tout le bloc nutritionnel — totaux, poids, couverture, fiabilité, ingrédients manquants, huile absorbée — **une seule valeur** dépendait du nombre de parts : la division des totaux. Elle se fait désormais à l'affichage, pour le contexte qui la demande : votre lecture, ou votre repas de mercredi prévu pour 8.
- **La recette ne porte plus que ce qui la décrit** : ses totaux, calculés à ses propres portions, vrais pour tous ses lecteurs. Votre choix de parts reste enregistré sous votre compte, comme avant.
- **Bouger le curseur ne coûte plus rien.** Chaque changement de portions déclenchait un appel de Cloud Function et une écriture. Il n'en déclenche plus aucun : l'affichage se met à jour instantanément, et le recalcul reste disponible à la demande quand le contenu de la recette a changé.
- **Les recettes déjà en base restent justes** sans migration : les valeurs affichées sont dérivées des totaux, qui n'ont jamais dépendu de personne.

### Mise à jour release (15/08/2026 — v0.20.3)

#### Deux corrections signalées à l'usage

- **Valider un planning n'empile plus les repas.** Enregistrer un nouveau cycle ajoutait ses repas par-dessus ceux déjà planifiés sur les mêmes jours : le planning en affichait deux par créneau, sans rien dire. La validation regarde désormais ce que le cycle recouvre et propose de **remplacer** les repas existants ou de les **compléter** — le nombre de repas remplacés est annoncé.
- **« Tout regénérer » dit ce qu'il fait.** Le menu annonçait « efface les choix en cours », ce qui laissait croire qu'il effaçait le planning enregistré. Il vide les créneaux de l'écran, et le libellé le dit.
- **La conservation était introuvable.** Le bouton n'apparaissait que sur un créneau ayant un jour de préparation calculé — donc uniquement avec un jour de batch cooking configuré **et** un jour coché « Réchauffage ». Il s'affiche maintenant dès qu'une recette est posée sur un créneau : on décide souvent de garder un plat après avoir choisi la recette, pas avant.
- **Le conseil est accessible depuis le planning**, par le menu d'un repas — l'écran où l'on se trouve trois jours plus tard, au moment de réchauffer. Il s'ouvre dans une feuille qui distingue nettement la consigne **calculée** (délai réel, réfrigérateur ou congélateur) du conseil produit par l'IA.
- **Un conseil déjà produit n'est jamais repayé** : il est relu avant toute génération, des deux écrans.

### Mise à jour release (15/08/2026 — v0.20.2)

#### On cuisine la quantité prévue, et on sait ce que devient le plat en attendant

- **La recette s'ouvre à l'échelle du repas.** Depuis le planning, une recette prévue pour 8 parts s'affichait avec ses portions d'origine : le nombre saisi ne servait qu'à la liste de courses et disparaissait au moment de cuisiner. La fiche s'ouvre désormais aux parts du repas, ingrédients recalculés. **Rien n'est écrit** : ni sur la recette, ni sur vos préférences de portions. Ajuster les parts depuis cette ouverture reste volant et ne devient pas votre réglage permanent pour cette recette.
- **Un plat préparé à l'avance dit comment il se garde.** Le planning affiche, pour chaque créneau préparé un autre jour, le délai réel et ce qu'il impose : réfrigérateur jusqu'à trois jours, congélateur au-delà. Cette consigne est **calculée, pas générée** — elle s'affiche toujours, sans le moindre appel d'IA, parce qu'un plat gardé trop longtemps au froid n'a pas mauvais goût et n'alerte personne.
- **Le jour de préparation ne se perd plus.** Il était calculé pendant la planification, affiché, puis oublié à l'enregistrement. Il est maintenant conservé avec le repas, et c'est lui qui porte toute la question de la conservation.
- **Un conseil propre au plat, à la demande** : contenant et conditionnement, ce qui se dégrade en premier, durée réelle quand elle est plus courte que la règle générale (riz cuit, poisson, viande hachée), congélation possible ou déconseillée et pourquoi, méthode et température de réchauffage, ce qu'il vaut mieux ajouter au dernier moment, et les signes qu'il ne faut plus le manger. Un bouton le produit depuis le créneau concerné.
- **Il s'écrit en conclusion de la recette**, sous une section « Conservation et réchauffage », à côté du dressage. Le relire trois jours plus tard ne demande donc pas de rouvrir le planning. Une seconde génération remplace la section au lieu de l'empiler.
- **Produit une fois, valable pour tous les repas.** Le conseil décrit le plat, pas un créneau : il donne le réfrigérateur *et* le congélateur d'un coup, et le planning retient la moitié qui s'applique. Replanifier la même recette ne le repaie pas.
- **Le poste « Conservation et réchauffage » apparaît dans les coûts** et peut basculer entre Gemini et Claude depuis *Admin › Moteur d'IA*, comme tous les autres.

### Mise à jour release (15/08/2026 — v0.20.1)

#### Moteur d'IA : l'écran laissait croire que Claude retouchait les images

- **La famille « Illustrations » s'appelle désormais « Illustrations — détection ».** Ses cinq postes *lisent* une image — repérer la photo principale, délimiter les illustrations, mesurer une grille — et Claude les sert très bien. Sous l'ancien titre, les voir tous basculés sur Claude donnait à penser que la retouche d'image y était partie aussi.
- **Les trois postes qui produisent une image apparaissent enfin**, dans une section qui ne se bascule pas : illustration de recette, visuel de dressage, amélioration de photo. Ils affichent le moteur qui les sert — Nano Banana 2 Lite — sous forme de puce et non de commutateur, parce qu'il n'y a rien à choisir : aucun modèle Claude ne fabrique d'image. Leur absence pure et simple était l'incohérence, pas leur non-basculement.
- **Aucun troisième fournisseur n'a été ajouté.** Ces postes sont du Gemini, comme la colonne de gauche, sur un modèle différent de celui du texte — et leur coût se lit dans Comptabilité aux mêmes clés qu'avant.

### Mise à jour release (15/08/2026 — v0.20.0)

#### Les images changent de moteur, et le compteur suit

- **Nano Banana 2 Lite remplace l'ancien modèle d'image.** Illustrations de recette, visuels de dressage et amélioration de photo passent de `gemini-2.5-flash-image` à `gemini-3.1-flash-lite-image` : **0,0336 $ l'image au lieu de 0,04 $**, et une génération annoncée autour de quatre secondes. Claude, pour mémoire, ne produit aucune image — la génération visuelle reste chez Google par nécessité, pas par habitude.
- **L'ancien tarif reste au catalogue.** Les mois déjà consommés portent l'ancien identifiant de modèle : le retirer aurait relu leur coût au tarif par défaut, c'est-à-dire images gratuites. Un historique de dépense ne se réécrit pas quand on change de fournisseur.
- **Le modèle facturé ne peut plus diverger du modèle appelé.** L'identifiant vivait en trois exemplaires : deux modules choisissaient le modèle appelé, un troisième choisissait le modèle *facturé*. Un oubli dans ce dernier aurait imputé la dépense à l'ancien tarif sans qu'aucun écran ne bronche. Il n'existe désormais qu'une seule déclaration.
- **L'écran des coûts annonce le bon prix avant de dépenser.** La confirmation qui précède une série de visuels de dressage chiffrait encore l'ancienne grille.

### Mise à jour release (15/08/2026 — v0.19.99)

#### Planification : les contraintes que vous saisissiez n'arrivaient nulle part

- **La contrainte du jour, dans l'écran de planning, n'était jamais transmise.** Le champ « Contrainte spécifique » ne s'enregistrait qu'à la validation clavier — impossible sur un champ multiligne. « Repas léger, sport le soir » restait à l'écran et ne quittait jamais le téléphone. Les champs *Prépa max* et *Parts à préparer* se perdaient de la même façon dès qu'on cliquait ailleurs. Chaque frappe compte désormais.
- **« Parts à préparer » n'existait pas côté serveur.** Le nombre était bien enregistré et servait à mettre la liste de courses à l'échelle, mais l'IA ne le voyait pas : elle pouvait proposer une recette individuelle pour un dîner de huit. Le créneau annonce maintenant ses parts, et l'IA signale quand elle a dû redimensionner.
- **Une réponse illisible du modèle passait pour « aucune idée ».** Le serveur avalait l'erreur sans un mot ; l'application comblait alors tous les créneaux avec un « complément automatique », et l'on croyait à une IA qui choisit mal — alors qu'elle n'avait rien choisi du tout. Ces échecs sont désormais tracés, nommés, et visibles dans les logs.
- **La régénération globale n'écrase plus vos choix.** Elle envoyait au modèle vos sélections manuelles comme « à éviter », puis les remplaçait quand même. Le bouton ✨ propose maintenant **Compléter les créneaux vides** ou **Tout regénérer**, qui prévient qu'il efface.
- **Les contraintes redeviennent modifiables après une génération.** Elles se figeaient définitivement, sans moyen d'ajuster puis de relancer.
- **Un cycle de plus de sept jours ne s'écrase plus lui-même** : deux créneaux tombant le même jour de semaine gardent chacun leurs contraintes.
- **Le calendrier choisi est enfin utilisé partout.** Deux des trois chemins d'export écrivaient toujours dans l'agenda principal en ignorant le calendrier configuré, sa durée par défaut et l'heure de repas. L'événement retrouve aussi son intitulé « Préparer : … », réduit à une espace par un accident d'encodage.
- **La liste de courses ne perd plus de repas.** Elle ne connaissait que vos recettes validées : un repas planifié depuis un brouillon ou une recette de la famille en disparaissait sans un mot. Elle est aussi limitée aux repas à venir — elle listait jusqu'ici les courses de repas déjà mangés.
- **Vos préférences ne sont plus écrasées par les valeurs par défaut.** L'écran de configuration pouvait s'ouvrir sur un état vide venu du cache, puis réenregistrer ces défauts par-dessus vos vrais réglages.
- **Le cycle peut démarrer aujourd'hui.** Ouvrir l'écran un vendredi quand le cycle commence le vendredi proposait le vendredi suivant.
- **Le planning charge les 90 derniers jours** au lieu de la totalité de l'historique à chaque ouverture.

### Mise à jour release (15/08/2026 — v0.19.98)

#### La chaîne nutrition dépensait sous des noms de code

- **Quinze postes de coût s'affichaient sous leur identifiant technique**, tous rangés dans « Autres » : `detect_not_consumed`, `estimate_piece_weights`, `nutrition_ingredients_enrichment_batch`… soit toute la chaîne nutritionnelle, c'est-à-dire les appels les plus fréquents de l'application — une seule écriture de recette peut en déclencher une dizaine. Le montant était juste ; il était simplement impossible de savoir ce qu'on payait. Ils forment désormais le processus **« Valeurs nutritionnelles »**, chaque poste portant son nom et sa description.
- **Deux autres postes rentrent dans le rang** : la relecture d'un document Markdown et l'illustration de recette, oubliées elles aussi.
- **Les variantes par lot se distinguent de leur version unitaire.** Un lot coûte bien moins qu'une série d'appels isolés : les confondre revenait à s'interdire de vérifier que le groupage sert à quelque chose.
- **La règle est écrite et testée** : un poste d'IA vit à trois endroits — l'appel, le routage, le catalogue de lecture — et s'ajoute aux trois dans le même commit. Aucun de ces oublis ne lève d'erreur, ce qui est précisément le problème.
- **Diagrammes à jour** : le diagramme de classes porte `RecipeAbsorbedOil`, et le diagramme de séquence du recalcul nutritionnel montre l'appel de friture et son garde-fou gratuit.

### Mise à jour release (15/08/2026 — v0.19.97)

#### Le bain et ce qu'il laisse derrière lui se lisent ensemble

- **L'huile absorbée se range sous le bain dont elle sort**, en « ↳ dont absorbée », au lieu de fermer le tableau à dix lignes de distance. Le bain dit ce qu'on jette, la ligne en dessous dit ce qu'on garde : deux lignes, une seule idée. Reléguée en fin de liste, l'huile absorbée ressemblait à un ingrédient qu'on aurait oublié de ranger.
- **Elle ne ferme le tableau que si la recette ne nomme aucun bain** — huile absente de la liste, ou nommée autrement. Dans ce cas elle reprend son nom complet, puisqu'elle n'a plus de parent pour la présenter.

### Mise à jour release (15/08/2026 — v0.19.96)

#### On ne mange pas le bain de friture, mais on mange ce qu'on y trempe

- **Un poulet pané frit déclarait les lipides d'un poulet pané cru.** Le bain de friture est écarté du calcul — un litre d'huile pèse 8280 kcal, le compter rendrait toute recette illisible — mais ce qu'on y plonge en ressort plus gras : environ 10 % de son poids en huile. Sur 600 g de poulet pané, ce sont **55 g de lipides et 500 kcal** que la recette n'annonçait nulle part, avec une couverture affichée « complète » et un bon score de fiabilité.
- **Le taux d'absorption suit l'aliment, pas le bain.** Garder un pourcentage de l'huile déclarée aurait fait dépendre le résultat de la rédaction de la ligne : « 1 L pour la friture » n'a aucun rapport avec ce qui est mangé. Le calcul part du poids des ingrédients frits, panure comprise, et se plafonne à l'huile que la recette met réellement dans la poêle.
- **Une ligne dérivée dit d'où viennent ces lipides** : « huile de tournesol absorbée · 55 g », en italique et marquée estimée, sous les ingrédients. Au survol, son taux et le poids frit dont il découle. Le bain garde sa mention « non consommé » : les deux lignes coexistent et racontent la vérité — on jette le litre, on mange les 55 g.
- **Seules les recettes qui sentent la friture paient un appel d'IA.** Un test gratuit sur le texte et les ingrédients sert de portier ; une panure seule ne déclenche rien, le four existe. Le verdict est conservé et n'est redemandé que si la recette change.

### Mise à jour release (14/08/2026 — v0.19.93)

#### Un total nommé, et un écart qui cesse de crier au loup

- **« Invoice » n'est pas le total de l'infrastructure**, malgré son nom : c'est une ligne de facturation Google comme les autres — taxes et ajustements de facture. L'arithmétique le montre : sur juillet, 3,65 € d'« Invoice » plus les autres services font les 3,96 € de la section. Un **« Total infrastructure »** en gras est donc ajouté en fin de liste : la somme méritait d'être nommée plutôt que devinée.
- **Un écart dont la cause est connue et irréparable n'est plus signalé en rouge.** Les mois clos avant le 14 août sont antérieurs au comptage des jetons de raisonnement : Gemini les facture, l'application ne les lisait pas, et aucune reconstruction ne fera apparaître une donnée qui n'a jamais été enregistrée. L'écran le dit en une phrase, au lieu de demander indéfiniment d'enquêter sur une cause déjà établie — et de noyer le jour où un vrai écart se produira.
- **Le mois d'août est signalé comme à cheval** : ses premiers appels ne portent pas le raisonnement, les derniers oui. L'écart s'y résorbera de lui-même en septembre.

### Mise à jour release (14/08/2026 — v0.19.92)

#### L'écart affiché comparait deux instants différents

- **Un montant facturé est une photographie ; nos compteurs sont vivants.** Le relevé Anthropic est mis en cache six heures ; pendant ce temps, les appels continuent d'être comptés. L'écran soustrayait donc un total à jour d'un total périmé, et attribuait la différence à la grille tarifaire — alors qu'elle ne mesurait qu'un décalage d'horloge.
- **L'âge du relevé est désormais affiché** à côté du montant facturé : « relevé il y a 12 min ».
- **Au-delà de deux heures, l'écart n'est plus signalé en rouge** mais accompagné d'une phrase : les appels comptés depuis ne figurent pas dans le relevé, il faut relire le mois pour comparer deux chiffres du même instant.

### Mise à jour release (14/08/2026 — v0.19.91)

#### La lecture Anthropic marche, et elle a immédiatement trouvé une erreur

- **Nous surestimions Claude de 50 %.** La confrontation à la vraie facture d'août — 0,80 € facturés contre 1,20 € estimés — l'a montrée en une lecture. La cause : **Claude Sonnet 5 bénéficie d'un tarif d'introduction** (2,00 / 10,00 au lieu de 3,00 / 15,00) jusqu'au 31 août 2026, que la grille ignorait volontairement — l'idée étant qu'une surestimation valait mieux qu'une sous-estimation. C'était une erreur de raisonnement : un écart de moitié rend le rapprochement inutilisable **dans les deux sens**, et masquerait un vrai défaut de comptage le jour où il s'en produirait un. Une marge de sécurité posée sur un instrument de mesure ne le sécurise pas, elle le casse.
- **La grille est désormais datée** : un tarif promotionnel s'applique tant qu'il court, le tarif plein reprend automatiquement le jour où il expire. Et un appel est facturé au tarif **du jour où il a eu lieu**, jamais à celui du jour où l'on relit le rapport.
- **Le message d'écart se lit dans les deux sens.** Il n'expliquait que le cas « le fournisseur facture plus que nous ne comptons » et envoyait chercher des jetons manquants là où il n'en manquait aucun. Il distingue maintenant la consommation invisible d'une grille trop chère.
- **« Rechiffrer aussi les appels »**, case à cocher de la reconstruction : applique la grille corrigée aux mois déjà enregistrés. C'est la seule façon de réparer août — et parce qu'elle réécrit des montants déjà publiés, elle reste un choix explicite, jamais coché d'avance.

### Mise à jour release (14/08/2026 — v0.19.90)

#### La lecture Anthropic avance par tranches au lieu d'échouer en entier

- **Le blocage était une boucle fermée.** Douze mois faisaient douze requêtes d'un bloc ; l'échec empêchait d'écrire quoi que ce soit ; l'affichage suivant repartait donc de zéro et rallumait la limite de débit. Rien ne pouvait en sortir.
- **Ce qui est lu est désormais conservé**, même quand la lecture s'arrête en chemin. Chaque ouverture de l'écran relève **quatre mois**, **les plus récents d'abord** — le mois en cours étant le seul qu'on regarde vraiment. En trois ouvertures, l'année est complète.
- **Cinq minutes de pause après un refus.** Sans elle, chaque ouverture relançait la lecture et repoussait d'autant le retour à la normale : le remède entretenait la panne. Le bouton « Relire ce mois » passe outre.
- **Le message ne parle plus de panne** quand il n'y en a pas : « les mois sont relevés par tranches, ce qui est affiché est acquis, le reste se complètera ».

### Mise à jour release (14/08/2026 — v0.19.89)

#### Anthropic : la vraie cause du refus, et un bouton pour vérifier un mois

- **Le 429 venait d'abord de la taille de page.** Le rapport de coûts d'Anthropic rend des **journées**, et une page en vaut **7 par défaut** — pour un maximum autorisé de **31**. Une année d'historique coûtait donc près de **soixante** requêtes là où elle en coûte désormais **treize**. Pire : notre garde-fou s'arrêtait à quarante pages, ce qui aurait tronqué la lecture sans le dire.
- **Anthropic recommande une interrogation par minute** en régime établi, et conseille explicitement de mettre les résultats en cache pour un tableau de bord. C'est exactement ce que fait désormais l'écran.
- **Un bouton « Relire ce mois chez Anthropic »**, placé dans le mois plutôt qu'en tête d'écran : c'est ce montant-là qu'on veut vérifier. Il ne relit **qu'un mois** — une requête, au lieu de treize pour l'année. Sans lui, un avoir ou une correction rétroactive resterait masqué par le cache indéfiniment.

### Mise à jour release (14/08/2026 — v0.19.88)

#### La clé Anthropic fonctionnait : c'est l'écran qui demandait trop

- **Le « facturé par Anthropic : — » n'était pas un refus de clé, mais un `HTTP 429`** — limite de débit atteinte. L'API d'administration d'Anthropic rend des **journées** : afficher une année en demandait des dizaines de pages, à chaque ouverture de l'écran.
- **Les montants sont désormais mémorisés.** Un mois clos est lu une fois pour toutes — sa facture ne bougera plus. Seul le mois courant est redemandé, et au plus toutes les six heures. Ouvrir l'écran dix fois ne coûte plus dix lectures, mais zéro.
- **Un 429 n'est plus traité comme une panne** : c'est une demande d'attendre. L'appel patiente le temps indiqué par Anthropic et retente deux fois.
- **Un échec ne fait plus disparaître ce qu'on savait déjà.** Les montants du dernier relevé réussi restent affichés, signalés comme tels. Auparavant, une seconde de trop effaçait une facture de plusieurs euros.
- **Le message distingue enfin les trois cas** — clé absente (Secret Manager), clé refusée (console Anthropic), débit limité (rien à faire, sinon attendre) — parce qu'ils se règlent à trois endroits différents.

### Mise à jour release (14/08/2026 — v0.19.87)

#### Un chiffre, un seul endroit

- **La ventilation par poste disparaît de l'écran mensuel.** Elle faisait doublon avec l'onglet « Par service IA », qui la donne en mieux — nombre d'appels et coût unitaire, moteur par moteur. Deux lectures du même chiffre dans deux formats différents finissent par diverger, et c'est toujours la plus pauvre qu'on lit en premier.
- **« Par service IA » a désormais son propre filtre de période**, avec les mêmes puces que l'écran mensuel (Ce mois / 3 / 6 / 12 mois / Depuis le début). Il fallait auparavant revenir sur l'autre onglet pour changer la période de celui-ci : le geste le plus fréquent était devenu le plus long. Deux onglets réglés sur la même profondeur se partagent toujours une seule lecture serveur.
- Le filtre reste affiché quand le tableau est vide — une période trop courte étant la première cause d'un tableau vide, la masquer enfermait dans l'écran qu'on cherchait à quitter.

### Mise à jour release (14/08/2026 — v0.19.86)

#### L'écart se chiffre, se règle, et l'écran cesse de mentir par omission

- **L'écart est désormais chiffré en jetons, pas seulement en euros.** La facture Google indique 2 457 734 jetons de sortie pour août ; l'application en comptait 323 900. Les 2 133 834 manquants — du raisonnement — valent 4,67 €, pour un écart affiché de 4,62 €. **La cause explique la totalité de l'écart.** L'écran le dit maintenant lui-même, en rapprochant ses compteurs des lignes de la facture.
- **Un réglage pour le résorber** — *Admin → Moteur d'IA → Raisonnement de Gemini* : « le modèle décide » (défaut, inchangé), coupé, ou plafonné à 512 / 2 048 / 8 192 jetons. Le raisonnement représentait près de neuf dixièmes de la ligne la plus chère de la facture Gemini. Beaucoup de postes n'en ont aucun besoin — classer une page, deviner les dimensions d'une grille, proposer des tags ne demandent pas de délibération. Si l'API refuse le plafond, l'appel est rejoué sans lui : une facture plus lourde vaut mieux qu'un poste qui ne répond plus.
- **Claude dit enfin pourquoi il ne se confronte à rien.** « La clé n'est pas posée **ou** la lecture a échoué » laissait chercher du mauvais côté. L'écran distingue les deux et affiche l'erreur exacte renvoyée par Anthropic.
- **L'onglet « Contrôle Gemini » disparaît.** Il ne comparait que la part que Google facture : on y cherchait Claude et l'infrastructure sans les trouver, et un contrôle portant sur la moitié de la dépense se lit comme un contrôle sur la totalité. La confrontation à la facture vit dans « Mois par mois », où les deux moteurs ont la même forme et l'infrastructure sa section.

### Mise à jour release (14/08/2026 — v0.19.85)

#### L'écart de facturation avait une cause, et ce n'était pas le tarif

- **Le suivi comptait 2,13 € là où Google facturait 17,06 €.** La cause n'est ni un tarif ni un arrondi : **Gemini 2.5 Flash réfléchit avant de répondre**, et ces jetons de réflexion sont facturés au prix de la sortie — huit fois l'entrée — sans jamais apparaître dans la réponse. Le backend ne lisait que les jetons du texte rendu. Sur un appel d'extraction ordinaire, le raisonnement représente plusieurs fois le texte produit : le coût affiché valait donc une fraction du coût réel. Aucune erreur nulle part, juste un chiffre plausible et faux.
- **Ils sont désormais comptés**, et affichés à part : chaque moteur montre ses jetons d'entrée, de sortie **et de raisonnement**. Un poste qui coûte cher parce qu'il fait beaucoup réfléchir ne se corrige pas comme un poste qui produit beaucoup.
- **Un appel échoué est un appel facturé.** Un dépassement de délai n'arrête pas le calcul chez le fournisseur, et le repli sur l'autre moteur en ajoute un second. Ces appels étaient invisibles ; ils apparaissent maintenant, et le nombre d'appels en échec est affiché sur le mois.
- **La facture Google est décomposée ligne par ligne** sous la section Gemini — jetons d'entrée, jetons de sortie, génération d'images — avec les quantités facturées. Un écart réduit à un seul nombre rouge ne se diagnostique pas ; en regard des lignes de la facture, il désigne le poste en cause.
- **L'onglet « Réconciliation » s'appelle « Contrôle Gemini »** et dit ce qu'il couvre. On y cherchait Claude et l'infrastructure sans les trouver : il ne compare que la part que Google facture. Claude, facturé par Anthropic, et l'infrastructure se lisent dans « Mois par mois », qui les confronte eux aussi à leur facture.

> Les mois passés resteront sous-estimés même après reconstruction : les jetons de raisonnement n'ont pas été enregistrés à l'époque, il n'y a rien à relire. L'écart se referme à partir de maintenant.

### Mise à jour release (14/08/2026 — v0.19.84)

#### Coûts : des euros, deux moteurs à égalité, et le coût d'un appel

- **Tout est en euros, en notation européenne** : virgule pour les décimales, espace pour les milliers. La conversion utilise **le taux du mois concerné**, celui que Google a lui-même appliqué à sa facture — et non un cours du jour plaqué sur tout l'historique, qui donnerait pour l'an dernier un total que personne n'a payé. Les petits montants gardent quatre décimales : à deux, la plupart des appels d'IA s'afficheraient « 0,00 € ».
- **Trois blocs par mois : Claude, Gemini, infrastructure.** Gemini était jusqu'ici une ligne parmi les services Google, parce que c'est Google qui le facture. Il a désormais sa section, dans le même format que Claude — estimé par l'application, facturé par le fournisseur, écart en montant et en pourcentage. Deux moteurs présentés dans deux formats différents ne se comparent pas ; c'était pourtant la seule question qui compte au moment de basculer un poste de l'un vers l'autre.
- **Le total du mois retient le facturé quand il existe**, l'estimation seulement à défaut. Les deux ne sont jamais additionnés.
- **Un nouvel onglet « Par service IA »** : pour chaque poste — ou chaque processus, au choix — le **nombre d'appels**, le **coût unitaire** et le **total**, en trois colonnes distinctes : Claude, Gemini, et l'ensemble. Deux postes de même montant n'ont pas le même remède : l'un appelé mille fois pour trois fois rien se corrige en appelant moins, l'autre appelé trois fois pour un montant lourd en changeant de modèle. Le total seul ne les distingue pas.
- **L'estimation d'empreinte énergétique est de retour**, disparue avec l'ancien écran d'usage des tokens : nombre de jetons et énergie estimée (~0,001 Wh pour mille jetons) sur le total de la période, sur chaque mois, et sur chaque moteur. C'est un ordre de grandeur, pas une mesure — mais une consommation qu'aucun écran ne montre est une consommation qui ne baisse jamais.
- **Un écart entre estimé et facturé au-delà de 10 % est mis en évidence** au lieu de rester un chiffre parmi d'autres.

> Un mois d'août affichant « estimé 0,00 € » face à un montant facturé par Anthropic n'est pas un bug de tarification : ce sont des appels enregistrés avant la mise en place des agrégats mensuels. Le bouton **Reconstruire les agrégats** les rattrape depuis les lignes d'appel.

### Mise à jour release (13/08/2026 — v0.19.83)

#### Coûts : Anthropic entre dans le tableau, et l'historique s'ouvre

- **Où était Anthropic ? Nulle part, et pour une raison structurelle** : la facturation Google ne contient pas les appels Claude — Anthropic les facture directement. L'écran ne pouvait donc pas les montrer comme facturés, seulement estimés.
- **Le facturé Claude est désormais lu chez Anthropic** : chaque mois affiche l'estimation de l'application, le montant réellement facturé, et l'écart entre les deux. Un écart supérieur à un dollar est mis en évidence.
- **Cette lecture demande une clé d'administration Anthropic** (`sk-ant-admin…`), distincte de la clé d'inférence, à poser dans Secret Manager sous le nom `ANTHROPIC_ADMIN_KEY`. Sans elle, l'écran affiche l'estimation et dit franchement qu'elle n'est confrontée à rien — il n'invente pas un zéro.
- **Quatre profondeurs** : ce mois, 3 mois, 6 mois, 12 mois, et **depuis le début** — qui remonte au premier appel jamais enregistré.
- **Deux lectures** : par mois, ou par année repliée avec ses mois à l'intérieur.
- **Une répartition en tête d'écran** : ce que coûtent Gemini, Claude, les postes internes et l'infrastructure, sur toute la période choisie.
- **Une limite dite plutôt que masquée** : la facturation Google ne remonte que sur sa fenêtre d'export. « Depuis le début » couvre donc toute l'IA, mais l'infrastructure s'arrête là où l'export s'arrête — et l'écran le signale au lieu de laisser croire à une infrastructure gratuite.

### Mise à jour release (13/08/2026 — v0.19.82)

#### Cloud Logging : un traitement porte le nom de son poste

- **Fini les groupes tous intitulés « call »** : chaque appel HTTPS fabriquait son identifiant de corrélation avec le même préfixe générique. L'écran regroupait donc correctement… une dizaine de traitements portant tous le même nom, ce qui obligeait à ouvrir chacun pour savoir de quoi il s'agissait.
- **Le nom du poste devient la racine de l'identifiant** : « Extraction depuis un texte libre », « Conseil de dressage », « Amélioration photo » se distinguent désormais au premier regard, et le filtre par identifiant exact isole un traitement précis.

### Mise à jour release (13/08/2026 — v0.19.81)

#### Refonte du suivi des coûts : ce que coûte l'application, mois par mois

- **Un seul écran** — *Admin › Coûts de l'application* — remplace « Comptabilité » et « Usage des tokens IA ». Il montre les douze derniers mois, chacun dépliable : coût total, part IA et part infrastructure, ventilation par poste fonctionnel, par moteur, et par service Google.
- **Les totaux affichés sont enfin des totaux.** L'écran précédent lisait les mille derniers appels et présentait leur somme comme le total du mois. Au-delà de mille appels, il se trompait sans le dire. Les chiffres viennent désormais d'agrégats mensuels tenus à jour à chaque appel.
- **Un seul chiffrage.** Le coût d'un appel est fixé au moment où il a lieu, par la grille tarifaire du serveur. L'écran l'affiche, il ne le recalcule plus — deux grilles pour un même appel finissent toujours par diverger.
- **Plus aucun appel invisible.** Un appel dont le moteur ne renvoyait pas ses métadonnées n'était pas compté du tout, alors qu'il était bien facturé. Il l'est désormais, avec zéro jeton, et reste visible.
- **Le scan de sécurité n'est plus compté comme de l'IA Google.** Il apparaît sous le moteur « Interne », et sort du rapprochement avec la facturation Gemini.
- **La réconciliation dit la vérité en multi-moteur.** Elle sépare la part Gemini — la seule que Google facture et qu'on peut donc vérifier — de la part Claude, facturée par Anthropic, et le signale explicitement dans ses anomalies. Jusqu'ici, activer Claude creusait un écart artificiel présenté comme un fait.
- **Reconstruire les agrégats** : un bouton recalcule les mois affichés depuis les lignes d'appel. Il sert à rattraper l'historique antérieur au suivi mensuel, ou à réparer un mois dont les compteurs auraient dérivé. Aucun coût d'IA n'est engagé.

### Mise à jour release (13/08/2026 — v0.19.80)

#### Le dressage retourne dans la recette

- **Intégrer à la recette** remplace le bouton de copie : le conseil s'écrit en fin de recette sous une section **Dressage**, visuels compris en images flottantes alternées.
- **Intégrer deux fois ne double rien** : la section précédente est remplacée, y compris ses visuels. Trois régénérations suivies de trois intégrations ne laissent qu'une seule section — celle du dernier conseil.
- **Avec une réserve annoncée** : si vous aviez retouché la section à la main, l'intégration suivante écrase vos modifications. Le dialogue de confirmation le dit explicitement avant d'écrire, et affiche le texte exact qui sera inséré.
- **Une section « Cuisson et dressage » écrite par vous n'est jamais touchée** : seule la section produite par l'IA, au titre exact, est reconnue.
- **Retirer le dressage de la recette** reste disponible dès qu'une section existe.

### Mise à jour release (13/08/2026 — v0.19.79)

#### La bascule vers Claude s'appliquait à moitié

- **Onze postes ignoraient la configuration** : extraction depuis un scan ou un texte, relecture CookLang et Markdown, modification et génération de recette, recherche, couverture de livre, planning, courses, suggestion de tags, conseil de dressage. Choisir Claude — par poste ou par défaut — n'avait aucun effet sur eux : ils continuaient d'être servis par Gemini.
- **Pourquoi c'était invisible** : ces fonctions ne recevaient pas la clé Claude. Pour elles, la clé était donc « absente », situation dans laquelle le routeur sert l'autre moteur sans la signaler comme une panne — c'est le comportement voulu entre le déploiement du code et la création de la clé. Pendant ce temps, l'écran *Moteur d'IA* affirmait que la clé était présente, car il la reçoit, lui.
- **Ce qui change** : ces postes obéissent désormais à la configuration. Un basculement resté sans effet écrit maintenant un **avertissement** dans les logs, avec le nom du poste concerné : le silence est ce qui avait rendu cette panne indéchiffrable.
- **Le reporting de coûts reflétera la bascule** : jusqu'ici, la comptabilité était juste — elle mesurait bien du Gemini — mais elle mesurait un moteur que vous croyiez avoir quitté.

### Mise à jour release (13/08/2026 — v0.19.78)

#### Les générations d'image rejoignent leur traitement dans les logs

- **Un visuel généré n'est plus orphelin** : la ligne de consommation d'une image portait un `correlation_id` nul, si bien qu'elle apparaissait sous « Hors traitement » dans l'écran Cloud Logging, à côté de l'appel qui l'avait pourtant provoquée. Elle est désormais rattachée à son traitement.
- **Le poste nomme le groupe** : le champ `feature` était rangé dans les données annexes du log au lieu du premier niveau — l'écran ne pouvait donc ni l'afficher en titre ni filtrer dessus. Corrigé pour toutes les générations d'image (visuels de dressage et illustrations de recette).
- La comptabilisation elle-même était juste : chaque image reste facturée 0,04 $ sur son poste (« Visuel de montage », « Génération d'image »), et le conseil de dressage au tarif du modèle qui a réellement répondu.

### Mise à jour release (13/08/2026 — v0.19.76)

#### Dressage : une seule génération à la fois

- **Les autres actions sont suspendues pendant qu'un visuel se fabrique** : les boutons des autres étapes, *Regénérer* et *Réinitialiser les visuels* deviennent inertes jusqu'à la fin. Deux générations lancées de front produiraient deux assiettes concurrentes, et la série cesserait de raconter un montage.
- **Les boutons restent visibles, seulement grisés** : les faire disparaître laisserait croire que l'action n'existe pas. *Copier le texte* reste actif — c'est la seule action qui ne touche à rien.

### Mise à jour release (13/08/2026 — v0.19.75)

#### Dressage : les visuels ne peuvent plus être produits dans le désordre

- **Illustrer une étape produit celles qui manquent avant elle** : chaque image se construit sur la précédente ; demander la troisième sans les deux premières donnait une assiette née de rien, sans rapport avec celles qu'on générait ensuite. Un clic sur l'étape 3 génère donc 1, 2 puis 3, dans l'ordre.
- **Le coût est annoncé avant** : quand plus d'un visuel est nécessaire, un dialogue indique combien seront créés et pour quel montant. Le tarif vient de la grille tarifaire du projet, pas d'un chiffre écrit à la main.
- **Seul le dernier visuel peut être refait** : reprendre une étape du milieu laisserait derrière elle des images descendant d'une assiette qui n'existe plus. Les étapes antérieures n'ont plus de bouton.
- **Réinitialiser les visuels** : un bouton en bas de l'onglet efface toute la série pour repartir d'une assiette vide. C'est la seule façon — et une façon explicite — de refaire une étape ancienne. Le conseil et son texte ne sont pas touchés.
- **Une série interrompue reprend où elle s'est arrêtée** : si une génération échoue au milieu, les visuels déjà produits sont conservés et le clic suivant comble le trou.

### Mise à jour release (13/08/2026 — v0.19.74)

#### Dressage : tout se passe dans l'assiette

- **Plus rien à côté du contenant** : le modèle d'image posait spontanément la sauce dans une coupelle à côté de l'assiette, ajoutait une planche, débordait sur la table. Un guide de dressage montre ce qu'il y a *dans* l'assiette ; le reste est du décor de magazine, et il ment sur le geste à reproduire. La consigne est désormais explicite, à la génération comme à la description : un seul contenant, aucun ramequin annexe, une sauce d'accompagnement se pose en touche dans l'assiette.
- **Le visuel de résultat final est supprimé** : puisque chaque image part de la précédente et qu'on demande d'y ajouter quelque chose, un visuel « final » de plus ne pouvait qu'ajouter un objet — c'est ce qu'il faisait. La dernière étape du dressage **est** le résultat, et elle s'illustre comme les autres.

### Mise à jour release (13/08/2026 — v0.19.73)

#### Le dressage a son propre texte

- **Il n'est plus recopié dans la recette** : le dressage n'est pas une étape de cuisson, c'est ce qu'on fait une fois la recette finie. Fondu dans les étapes, il allongeait la recette de gestes qu'on ne lit pas en cuisinant, et une régénération réécrivait un contenu que l'utilisateur avait pu retoucher. Il vit dans son onglet, avec ses visuels.
- **Copier le texte** : un bouton met le dressage complet — intention, contenant, gestes numérotés, pièges, finitions — dans le presse-papier, prêt à être collé ou envoyé.
- **Nettoyage des essais précédents** : sur une recette où le dressage avait été inséré, un bouton **Retirer le dressage de la recette** supprime la section. Une section « Cuisson et dressage » écrite à la main n'est jamais touchée.

### Mise à jour release (13/08/2026 — v0.19.72)

#### Dressage : les visuels se construisent l'un sur l'autre

- **La matière est respectée** : le conseil décrit désormais la consistance de chaque élément (émulsion épaisse qui tient au ruban, purée mate, jus sirupeux), et le générateur d'image a consigne de la tenir. Une anchoïade montée à l'huile ressortait en bouillon : un modèle d'image livré à lui-même peint toutes les sauces en liquide clair.
- **Chaque visuel complète le précédent** : illustrer l'étape 2 part de l'image de l'étape 1 et n'y ajoute que le geste en cours, cadrage et lumière inchangés. Chaque étape était auparavant refabriquée de zéro, ce qui donnait quatre assiettes sans rapport au lieu d'un montage.
- **Toutes les étapes sont illustrables**, y compris les dernières — celles où le dressage se joue vraiment.
- **Le résultat dressé** : un bloc en bas de l'onglet génère le visuel du plat terminé, dans la continuité des étapes déjà illustrées. Il s'insère en pleine largeur à la fin de la section Dressage de la recette.
- **Les visuels accompagnent le texte** : l'image se place en regard du geste plutôt qu'en pleine largeur, et s'agrandit d'un clic. En pleine largeur, elle chassait la consigne hors de l'écran.

### Mise à jour release (13/08/2026 — v0.19.71)

#### Onglet Dressage : un conseil de cette recette, pas du dressage en général

- **Ce qui disparaît** : l'onglet produisait ses conseils sur place, en cherchant des mots-clés dans les noms d'ingrédients. « Persil détecté » donnait « les herbes soulignent le mouvement du dressage ». C'était vrai de tous les plats, donc utile pour aucun.
- **Un conseil demandé, pas subi** : l'onglet s'ouvre sur un bouton **Demander un dressage sur mesure**, avec un champ libre pour le contexte de service (« assiettes creuses », « buffet froid », « à emporter »). Rien n'est appelé tant que l'utilisateur ne le décide pas.
- **Ce que le moteur rend** : le contenant conseillé et pourquoi, l'ordre des gestes de montage nommant les éléments réels de la recette, les pièges propres à ce plat (ce qui détrempe, ce qui fige, ce qui ternit), et ce qui se pose au dernier moment.
- **Refus du passe-partout** : une réponse dont les gestes ne citent aucun ingrédient de la recette est refusée et redemandée. Un conseil générique ne lève aucune erreur et s'affiche parfaitement — c'est pour cela qu'il est détecté à la production, pas à la lecture.
- **Visuels de montage** : sur les dressages complexes, le moteur propose jusqu'à trois étapes à illustrer. L'image montre l'assiette **en cours de montage**, pas le plat fini. Chaque visuel se génère à la demande, étape par étape, jamais en lot (0,0336 $ l'image). Réservé aux rôles éditeur et administrateur.
- **Intégration à la recette** : un éditeur peut recopier le conseil dans la recette elle-même, sous une section **Dressage**, visuels compris en images flottantes alternées. Un aperçu du texte exact précède l'écriture ; une seconde intégration remplace la précédente au lieu de l'empiler.
- **Un appel par recette** : le conseil est conservé sur la recette et profite à tous les lecteurs. Un bouton **Regénérer** permet de le refaire, en changeant éventuellement le contexte de service.
- **Moteur nommé, jamais déguisé** : le conseil affiche en pied de page le moteur qui a répondu (Claude ou Gemini) et son modèle. Le poste est basculable depuis *Admin › Moteur d'IA*, sans redéploiement.

### Mise à jour release (12/08/2026 — v0.19.59)

#### Écran « Cloud Logging » : le bruit passe en DEBUG

- **Instrumentation séparée des événements** : « Appel IA démarré », « prompt envoyé à Gemini » et « réponse brute Gemini » sont journalisés en **DEBUG** et non plus en INFO. Un import écrivait une cinquantaine de lignes dont une quinzaine seulement portait une information : l'ouverture d'un appel n'apprend rien que sa clôture ne dise, durée et jetons compris.
- **Chips de sévérité en seuils** : « INFO+ » affiche INFO, WARN et ERROR ; « WARN+ » affiche WARN et ERROR ; « ERROR » les erreurs seules ; « DEBUG seul » isole l'instrumentation ; « Tout » ne filtre rien. L'égalité stricte précédente était un piège — sélectionner INFO masquait les erreurs, c'est-à-dire précisément ce qu'on cherchait.
- **Filtre par défaut : INFO+**. Le détail technique reste à un clic.

### Mise à jour release (12/08/2026 — v0.19.58)

#### Un traitement porte le nom du travail, pas celui d'un appel

- **Une écriture de recette = un traitement** : le recalcul des produits d'achat et la synchronisation nutrition tiraient chacun un identifiant de corrélation aléatoire. L'écran de logs y voyait deux traitements anonymes, sans lien entre eux ni avec l'écriture qui les avait déclenchés. Les deux partagent désormais le `correlationId` posé par `onRecipeWritten` et se lisent comme un seul bloc.
- **Titre du groupe** : le libellé vient d'abord de la racine du `correlationId`, qui nomme le traitement. Le poste (`feature`) n'est plus qu'un repli, et seulement pour les entrées dont l'identifiant est opaque : l'utiliser en titre faisait passer l'import d'une recette pour un « shopping_products_refresh », du nom du premier appel IA qu'il déclenchait.

### Mise à jour release (12/08/2026 — v0.19.57)

#### File de travail : un import, une ligne

- **Le brouillon remplace son traitement dès qu'il existe** : la pipeline d'import publie le brouillon, puis poursuit plusieurs minutes de normalisation des référentiels en arrière-plan. Pendant cette phase, la file de travail affichait deux lignes pour un seul import — le traitement en cours et le brouillon qu'il venait de produire. Le traitement disparaît désormais de la file dès qu'il a créé un brouillon : c'est le brouillon que l'utilisateur ouvre, et lui seul reste affiché. Les jobs en **erreur** ou **rejetés** restent visibles même s'ils ont produit un brouillon, sans quoi la panne disparaîtrait de l'écran.

#### Écran admin « Cloud Logging » : lecture par traitement

- **Regroupement par traitement** : un chip « Par traitement » (activé par défaut) regroupe les entrées partageant un même `correlationId`. Un import, un backfill ou un enrichissement se lit alors comme un bloc unique — replié, avec son libellé, son nombre de messages et sa date — au lieu d'être dispersé dans le flux entre les messages des autres traitements.
- **Ordre de lecture inversé dans le groupe** : le flux global présente le plus récent en premier, mais un traitement se déroule dans le temps : ses messages sont donc affichés du plus ancien au plus récent.
- **Les échecs s'ouvrent d'eux-mêmes** : un groupe contenant au moins une entrée `ERROR` est déplié à l'affichage et porte l'icône et la couleur d'erreur ; un groupe contenant un `WARNING` porte la couleur d'avertissement.
- **Isoler un traitement** : un bouton entonnoir sur l'en-tête du groupe reporte son `correlationId` dans le filtre exact et relance la requête.
- **Libellé lisible** : le groupe s'intitule par le poste fonctionnel (`feature`) quand il est connu, sinon par le module, sinon par la racine du `correlationId` débarrassée de son horodatage. Les entrées sans corrélation sont réunies sous « Hors traitement ».
- Le chip peut être désactivé pour retrouver la liste plate d'origine.

### Mise à jour release (05/07/2026 — v0.18.0)

#### Stabilisation de release multi-plateforme

- **Version applicative harmonisée** : la version affichée dans la documentation produit et les supports d'installation est alignée sur **v0.18.0** pour éviter toute ambiguïté entre web, mobile et desktop.
- **Diffusion cohérente** : la release est préparée pour les trois canaux cibles (mobile Android/iOS, web et desktop Windows) avec le pipeline standard de déploiement.

### Mise à jour release (11/07/2026 — v0.19.18)

#### Gouvernance unifiée des unités ingrédients (éditeur + IA + scan)

- **Source de vérité unique** : la gestion des unités repose sur un référentiel central (`nutrition_units`). Toute unité d'ingrédient saisie, générée par IA ou extraite par scan doit être résolue par ce référentiel avant d'être exploitée pour la nutrition.

- **Règle métier prioritaire** : la composition recette doit d'abord **piocher dans la liste du référentiel**. La création d'une nouvelle unité n'est autorisée qu'en **fallback** si aucune correspondance n'existe après normalisation.

- **Normalisation stricte anti-doublons** : différentes écritures d'une même unité doivent converger vers une forme canonique unique. Exemple attendu : `CAC`, `cac`, `c.C`, `C.c`, `c.a.c` et `cuillère à café` doivent toutes référencer la même unité canonique (`c_a_c`).

- **Fallback contrôlé** : lorsqu'une unité légitime absente du référentiel apparaît (ex: `tige`), elle est ajoutée automatiquement en entrée `unknown/pending_review` et réutilisée ensuite telle quelle (pas de duplication proche).

- **Couverture multi-canaux obligatoire** : ces règles s'appliquent uniformément à :
  - l'éditeur manuel d'ingrédients,
  - la génération de recettes via Gemini,
  - l'extraction/scan OCR,
  - les flux de backfill/recompute nutrition.

- **Traçabilité de résolution** : chaque graphie d'unité rencontrée est conservée dans le référentiel `nutrition_units` (`aliases`, `status`, `source`), avec sa provenance. Elle n'est **pas** recopiée sur chaque ingrédient de chaque recette : une recette ne stocke que ce qu'elle dit (`name`, `qty`, `unit`, `category`), la résolution se recalcule à la demande.

- **Contrôle qualité opérationnel** : l'admin doit pouvoir visualiser les unités inconnues, valider/fusionner les alias, et suivre la baisse des ingrédients non convertibles en nutrition.

### Mise à jour release (04/07/2026 — v0.17.0)

#### Retouche image — expérience unifiée

- **Atelier de retouche unique** : les actions de retouche photo sont regroupées dans un seul écran « Atelier de retouche », avec un parcours cohérent au lieu d'actions dispersées (recadrage d'un côté, couleur de l'autre).
- **Panneaux orientés intention** : l'atelier expose des sections claires côté utilisateur : **Cadre**, **Lumière**, **Détails**, **Presets**.
- **Comparaison avant/après** : l'utilisateur peut comparer l'original et la retouche en appui long (ou via bascule) sans quitter l'écran.
- **Historique immédiat** : l'atelier propose **Annuler / Refaire** pour sécuriser les essais et réduire la peur de se tromper.
- **Presets intelligents** : des presets rapides sont proposés avec une recommandation automatique basée sur l'analyse locale de l'image (lisibilité, naturel, couleurs pop, doux).
- **Point d'entrée simplifié dans les galeries** : dans les onglets photos des écrans d'édition/révision, une seule action **Retoucher** remplace les boutons dispersés Crop/Couleur.

### Mise à jour release (28/06/2026 — v0.15.90)

#### Traçabilité des fichiers rejetés par le scan de sécurité

- **Job au statut « Rejeté »** : lorsqu'un fichier importé (recette, couverture ou document de livre) est bloqué par le scan de sécurité, une entrée est désormais créée dans l'écran « Brouillons & Traitements » avec le statut **Rejeté** (badge rouge). Auparavant, le motif du blocage n'était affiché qu'éphémèrement à l'utilisateur et n'était conservé nulle part de consultable dans l'application.
- **Motif visible** : chaque entrée rejetée affiche le nom du fichier, son type et la **raison du rejet** retournée par le scan (incohérence de format, type non autorisé, signature antivirus, etc.). Le détail est consultable et copiable via un appui long.
- **Actions** : seule l'action **Supprimer** est proposée sur une entrée rejetée (pas de **Relancer**, car re-scanner le même fichier produirait le même rejet). Le fichier source reste en quarantaine et n'est pas exposé.

### Mise à jour release (02/06/2026 — v0.15.31)

#### Sécurité — Corrections de règles et nettoyage

- **Notes de recettes (`recipe_ratings`) — création restreinte** : la règle Firestore `allow create` sur la collection `recipe_ratings` exige désormais que le champ `user_id` du document créé corresponde à l'uid de l'utilisateur connecté (`request.resource.data.user_id == request.auth.uid`). Auparavant, un utilisateur authentifié pouvait créer une note avec l'identifiant d'un autre utilisateur.

- **CORS Cloud Functions restreint** : les fonctions HTTPS Callable (wrappers Gemini et admin) n'acceptent plus toutes les origines (`cors: true`) mais uniquement les domaines Firebase connus : `kassdale-6d948.web.app` et `kassdale-6d948.firebaseapp.com`.

#### Nettoyage — Code mort PWA retiré

- **Suppression du système d'installation PWA programmatique** : les fichiers `web_install.dart`, `web_install_web.dart` et `web_install_stub.dart` ont été supprimés. Ces fichiers exposaient `isPwaInstallAvailable()` et `triggerPwaInstall()` mais n'étaient importés nulle part dans l'UI. La capture de `window._pwaPrompt` dans `index.html` a également été retirée. Chrome gère nativement l'installation PWA via sa bannière `beforeinstallprompt` sans intervention Flutter.

### Mise à jour release (01/06/2026 — v0.15.29)

#### Distribution & Installation de l'application

- **Téléchargement de l'APK depuis le web (Android)** : sur la version web ouverte sur Android, un bandeau ou une vérification automatique au lancement détecte si une mise à jour est disponible. Le téléchargement de l'APK est déclenché via un lien direct servi par Firebase Hosting (`/app-release.apk`) avec les headers HTTP corrects (`Content-Type: application/vnd.android.package-archive`, `Content-Disposition: attachment; filename="kass-dalle.apk"`). Le fichier se télécharge directement dans le dossier Téléchargements du téléphone.

- **Installation PWA (Progressive Web App) native** : sur Chrome Android et Chrome Desktop, le mécanisme standard `beforeinstallprompt` du navigateur est utilisé. L'événement est capturé dans `index.html` **sans** appel à `preventDefault()`, ce qui laisse Chrome afficher sa propre bannière d'installation native. Aucune interface personnalisée n'est imposée — l'utilisateur voit la proposition d'installation standard du navigateur au moment opportun.

#### Export PDF

- **Export d'une recette en PDF imprimable** : depuis la fiche d'une recette validée, un bouton PDF (icône dans l'AppBar) permet d'exporter la recette au format PDF. L'export génère un document paginé avec : entête coloré (orange profond), titre, métadonnées (portions, difficulté, temps), liste des ingrédients, étapes numérotées, et optionnellement les photos de la recette. Un dialogue demande à l'utilisateur s'il souhaite inclure les images avant génération.

- **Positionnement des images dans le PDF** : les images sont positionnées selon leur marqueur dans le texte CookLang (`![left|40%](url)`, `![right|30%](url)`, `![after|80%](url)`). Le PDF respecte l'alignement gauche/droite/centré et le pourcentage de largeur déclaré dans le contenu.

- **Snackbar "Ouvrir" après export PDF sur mobile** : après génération et partage du PDF (via la share sheet système Android/iOS), un snackbar succès affiché pendant 8 secondes propose un bouton **OUVRIR** permettant de ré-ouvrir la share sheet avec le même document. Ce bouton n'apparaît que sur les plateformes mobiles natives (non-web) ; sur web, le PDF est déjà dans les Téléchargements du navigateur et aucun bouton supplémentaire n'est affiché.

#### Éditeur de recettes — Mode visuel (WYSIWYG)

- **Éditeur hybride CookLang** : l'éditeur de brouillon propose trois modes via des icônes de toggle : **Texte** (saisie CookLang brute avec coloration syntaxique), **Visuel** (édition bloc-par-bloc WYSIWYG), et **Aperçu** (rendu final de la recette). Le mode peut être changé à tout moment.

- **Édition bloc-par-bloc** : en mode visuel, chaque ligne ou section du CookLang est un bloc cliquable et éditable inline. Les types de blocs supportés : titre, ingrédient (`@nom{quantité}`), ustensile (`#outil{}`), section (`== Titre ==`), étape, conseil/note (`> texte`), commentaire (`-- texte`), image (`![pos|width](url)`).

- **Toolbar d'insertion** : une barre d'outils flottante permet d'insérer au curseur : section, étape, ingrédient, ustensile, conseil, liste, image (avec sélection depuis la galerie du brouillon). Chaque insertion se positionne précisément à la ligne active.

- **Réordonnancement par drag-and-drop** : les blocs peuvent être réordonnés par glisser-déposer dans l'éditeur visuel, modifiant directement l'ordre dans le CookLang sous-jacent.

- **Insertion d'images avec choix de position et largeur** : lors de l'insertion d'une image depuis la galerie, l'utilisateur choisit le positionnement (gauche / droite / après / pleine largeur) et la largeur en pourcentage (5 % à 80 %) via des `ChoiceChip`. Le tag CookLang correspondant est généré automatiquement.

- **Enter pour diviser un bloc** : dans l'éditeur visuel, appuyer sur Entrée dans un bloc le divise en deux blocs distincts. Un bouton de suppression de ligne (icône corbeille) est disponible sur chaque bloc.

#### Éditeur Markdown — Pages non-recette

- **Éditeur Markdown riche** : les pages non-recette (techniques culinaires, méthodes, notes) disposent d'un éditeur Markdown dédié avec toolbar : titres (H1/H2/H3), gras, italique, souligné, listes à puces, insertion d'images avec position (gauche/droite/après) et largeur en %.

- **Sélecteur de type de page** : dans l'éditeur d'un brouillon, un sélecteur permet de qualifier le type de contenu : recette structurée, page de technique, méthode, note ou autre. Ce choix influe sur le rendu affiché (vue recette CookLang vs aperçu Markdown), les champs du formulaire visibles, et le comportement du prompt IA.

- **Aperçu Markdown intégré** : un onglet Aperçu affiche le contenu Markdown rendu typographiquement avec les illustrations intercalées à leurs positions déclarées.

#### Bibliothèque de livres

- **Effet 3D sur les couvertures** : les vignettes de couverture de livres affichent un effet livre 3D avec ombres portées, tranche simulée et vernis. Ce rendu est appliqué à la liste des livres et à l'écran de détail.

- **Livres système avec couvertures par défaut** : les livres système (KassDalle, Recettes libres) disposent de couvertures illustrées par des assets locaux. Si aucune couverture personnalisée n'est définie, l'asset par défaut est utilisé.

- **Filtre de contenu dans un livre** : dans l'écran d'un livre, un `SegmentedButton` permet de filtrer l'affichage : Tout / Recettes / Autre (pages non-recette). Ce filtre remplace l'ancien bouton cyclique.

- **Sélection multiple** : un appui long sur un livre ou une recette libre active le mode sélection multiple. L'AppBar contextuelle propose "Tout sélectionner" et "Supprimer" (avec confirmation). La sélection est limitée aux éléments de l'utilisateur connecté.

#### Planning des repas — Améliorations

- **Préférences planning accessibles depuis le profil** : les préférences de planning (nombre de repas, contraintes, heures) sont accessibles depuis l'écran Profil en plus de l'icône engrenage dans l'écran Planning.

- **Sections repliables dans les préférences** : les sections de configuration du planning (contraintes globales, contraintes par jour) sont repliables pour simplifier l'interface.

- **Justification IA des suggestions** : lors d'une suggestion IA de planning, chaque repas proposé affiche la justification du choix IA (pourquoi cette recette à ce moment).

- **Sélection des sources pour les suggestions** : lors du batch planning, l'utilisateur peut sélectionner quels livres ou sources doivent être utilisés par l'IA pour les suggestions.

#### Écran Explorer (Recherche & Création)

- **Refonte en écran Explorer** : l'écran de recherche est renommé « Explorer » et propose trois actions clairement distinctes : **Chercher** (recherche dans la base), **Créer** (génération IA d'une nouvelle recette), **Web** (recherche web). La saisie du texte et la validation par Enter déclenchent la recherche.

- **Tri par pertinence** : les résultats de recherche sont triés par score de pertinence décroissant.

- **Diff des modifications après raffinement IA** : après un raffinement IA d'une recette, un écran de diff affiche les modifications apportées (ajouts en vert, suppressions en rouge) permettant de valider ou annuler avant sauvegarde.

- **Sauvegarde directe d'une recette générée par IA** : depuis l'écran de génération IA, la sauvegarde d'une recette validée crée directement la recette sans passer par un brouillon intermédiaire, et navigue vers la fiche de la recette créée.

#### Pipeline image — Améliorations qualité

- **Traitement Sharp côté serveur** : avant l'envoi à Gemini pour l'extraction de couverture ou la détection d'illustrations, les images passent par un pré-traitement Sharp (deskew, CLAHE, normalisation des niveaux) côté Cloud Function pour améliorer la lisibilité des scans.

- **Compression mobile** : sur Android/iOS, `flutter_image_compress` est utilisé pour réduire la taille des photos avant upload, avec un plafond configurable. Les thumbnails sont générés au format WebP.

- **Quality gate Gemini** : avant d'envoyer une image à Gemini pour l'analyse, un score de qualité est calculé (netteté, luminosité, contraste). Si le score est insuffisant, un avertissement est affiché à l'utilisateur avant de continuer.

#### Comptabilité & Suivi IA

- **Page Comptabilité** : accessible depuis le menu Admin, cette page présente deux onglets : **GCP** (coûts Cloud Functions, Storage, Tasks issus de BigQuery) et **Gemini** (tableau croisé coûts Gemini par utilisateur × feature × période mensuelle). Chaque ligne du tableau Gemini affiche le nombre d'appels, le volume de tokens et le coût estimé en euros.

- **Suivi usage tokens par feature** : l'écran "Usage IA" affiche un tableau filtrable par période mensuelle, avec une colonne "Période" pour l'agrégation. Un bandeau résume la période active. Une estimation de l'énergie consommée (en Wh) est calculée à partir du nombre total de tokens.

- **Backfill historique améliorations images** : une Cloud Function `backfillEnhanceUsageFn` scanne le Storage et reconstruit les données d'usage des améliorations d'images manquantes. Un bouton "Reconstruire données images" est disponible dans la page Comptabilité (admin).

### Mise à jour release (18/05/2026 — v0.13.62)

- **Architecture serveur pour le traitement IA** : tous les appels Gemini (extraction de recettes, raffinement, recherche, suggestion de planning, génération de recette, polissage Cooklang, extraction de couverture, détection d'illustrations, etc.) sont désormais exécutés côté serveur via des Cloud Functions. La clé API Gemini n'est plus présente sur les clients (web, mobile, desktop) ; elle est stockée dans Google Secret Manager. Conséquences fonctionnelles : les imports volumineux (PDF multi-pages, scans de livres) ne dépendent plus de la connexion du téléphone — l'utilisateur peut fermer l'app, le traitement continue.

- **File d'attente avec traitement parallèle** : les imports de recettes et de couvertures de livres sont mis en file d'attente Cloud Tasks (5 jobs en parallèle, 2 par seconde, 3 tentatives en cas d'échec transitoire). Le statut du job (queued → processing → done/error) est suivi en temps réel sur le mobile via le panneau d'imports. Si un job échoue 3 fois, il est déplacé dans une "Dead Letter Queue" (DLQ) accessible aux administrateurs.

- **Écran admin "Dead Letter Queue"** : accessible depuis l'écran Administration (icône problème). Liste les jobs ayant échoué après 3 tentatives, plus récents d'abord. Pour chaque entrée : raison de l'échec, date, nombre de tentatives, dernier message d'erreur (sélectionnable + copiable), identifiants original_job_id / user_id / correlation_id / file_path / queue_name (avec bouton copier). Deux actions par entrée (avec confirmation) : **Relancer** (recrée un job neuf dans la file ; l'entrée DLQ est marquée comme relancée et conserve l'historique avec le nouveau jobId) et **Supprimer** (suppression définitive). Une entrée déjà relancée affiche l'icône "replay" verte et le bouton Relancer est désactivé.

- **Écran admin "Cloud Logging"** : accessible depuis l'écran Administration (icône terminal). Permet de filtrer les logs structurés du pipeline IA :
  - **Sévérité** (chips) : Tous / INFO / WARN / ERROR / DEBUG.
  - **Fenêtre temporelle** (déroulant) : 15 min / 1 h / 6 h / 24 h / 7 j.
  - **Recherche libre** dans le message.
  - **Filtres exacts** par correlationId, jobId, userId.
  - Chaque entrée est dépliable : labels avec bouton copier par valeur + payload JSON complet en monospace sélectionnable.
  - Affichage avec icône et couleur selon la sévérité, badges pour le module et les identifiants.

- **Suppression de la clé Gemini côté client** : les builds web/mobile/desktop ne nécessitent plus l'argument `--dart-define=GEMINI_API_KEY=...`. Toute fonctionnalité IA passe désormais par les Cloud Functions authentifiées.

### Mise à jour release (17/05/2026 — v0.13.53)

- **Images agrandissables dans l'Aperçu des pages non-recette** : les illustrations affichées dans l'onglet Aperçu d'une page non-recette sont limitées à 280 px de hauteur par défaut. Un tap sur l'image ou sur le bouton fullscreen (visible en bas à droite de chaque photo) permet d'agrandir l'image en pleine hauteur ou de la réduire. Chaque image garde son état agrandi/réduit indépendamment des autres.

- **Suivi de la version d'import (admin)** : lors de chaque import ou scan d'une recette ou page, la version de l'application est enregistrée dans le champ `import_version` du document Firestore de la recette. Dans l'écran de révision d'un brouillon, les administrateurs voient s'afficher en dessous de « Analysé le… » une ligne « Importé avec vX.Y.Z » (icône clé, texte italique). Ce champ est invisible pour les Editors et Readers. Les anciennes recettes importées avant cette version ne possèdent pas ce champ ; la ligne n'est alors pas affichée.

### Mise à jour release (17/05/2026 — v0.13.52)

- **Extraction d'illustration depuis l'original** : dans l'onglet Photos d'un brouillon disposant d'un scan image source, un bouton « Depuis l'original » est affiché à côté du bouton « Ré-extraire ». Ce bouton télécharge le fichier source, ouvre l'outil d'amélioration d'image en mode recadrage et permet au propriétaire de sélectionner manuellement une zone du scan pour l'ajouter comme nouvelle illustration. Le résultat est ajouté à la liste des illustrations sans remplacer les existantes.

- **Suppression directe des illustrations** : l'icône poubelle est désormais visible en permanence sur chaque illustration dans l'onglet Photos, dans la prévisualisation Cooklang et dans l'Aperçu des pages non-recette. Un appui long n'est plus nécessaire. La suppression n'est disponible que pour le propriétaire du brouillon.

- **Icône poubelle unifiée** : l'icône de suppression de photo est harmonisée (`delete_outline`) sur l'ensemble de l'application, en remplacement de l'icône ✕ précédemment utilisée.

### Mise à jour release (17/05/2026 — v0.13.51)

- **Onglet « Aperçu » pour les pages non-recette** : les brouillons de type page de technique culinaire, méthode ou autre contenu textuel non structuré bénéficient d'un onglet « Aperçu » dédié. Cet onglet affiche le texte de la page formaté typographiquement (titres en gras, listes à puces, paragraphes) et intercale chaque illustration à sa position déclarée par un marqueur `[schéma : …]` dans le texte. Le propriétaire peut supprimer chaque illustration directement depuis cet onglet. Pour les brouillons de recettes structurées (avec ingrédients Cooklang), l'Aperçu existant basé sur le rendu Cooklang interactif est conservé.

### Mise à jour release (17/05/2026 — v0.13.50)

- **Correction de navigation après l'éditeur d'image** : fermer ou valider l'outil d'amélioration d'image (recadrage, correction de couleur) depuis un brouillon ramène désormais systématiquement à l'onglet Photos du brouillon, quelle que soit la façon dont l'outil a été ouvert.

- **Correction des icônes Material sur le web (build release)** : les icônes Material Design étaient absentes dans les builds web release en raison du tree-shaking Flutter. Tous les builds web utilisent désormais l'option `--no-tree-shake-icons` pour garantir l'affichage correct de l'ensemble des glyphes.

### Mise à jour release (15/05/2026 — v0.13.35)

- **Refactoring interne (aucun changement fonctionnel)** : nettoyage global de la qualité de code. Toutes les API dépréciées (`withOpacity` → `withValues(alpha:)`) ont été mises à jour, les `debugPrint` retirés du code de production, les avertissements `use_build_context_synchronously` corrigés, et les règles du linter Dart strictement respectées. Résultat : analyse statique propre (0 warning, 0 erreur ; 2 infos inévitables liées à `dart:html` legacy). Aucun comportement visible n'est modifié.

### Mise à jour release (15/05/2026 — v0.13.27)

- **Batch planning hebdomadaire** : depuis l'écran Planning, un bouton "Nouveau planning" ouvre `BatchPlanningScreen`. L'écran génère automatiquement les créneaux du prochain cycle (ex : 7 jours) à partir des préférences configurées. Pour chaque créneau, l'utilisateur peut : laisser l'IA suggérer une recette (bouton ✨), choisir manuellement une recette (icône loupe → picker avec recherche textuelle + suggestion IA), saisir un repas libre (texte libre), ou laisser le créneau vide. Une suggestion IA globale génère d'un coup tout le planning en respectant les contraintes. L'heure de chaque repas est réglable indépendamment via un sélecteur. Un bouton "Enregistrer" ajoute tous les repas non-vides en lot dans Firestore.

- **Configuration du planning (Préférences)** : un écran dédié `PlanningConfigScreen` est accessible depuis l'icône engrenage de l'écran Planning. Il permet de configurer : le nombre de repas par cycle (défaut : 7), le jour de démarrage du cycle (Lundi–Dimanche), l'heure et les minutes par défaut des repas, les contraintes globales en langage naturel (ex : "Pas de poisson deux fois dans la semaine"), et les contraintes par jour de la semaine (durée max de préparation en minutes, flag "batch cooking / réchauffage", note libre). Le calendrier Google cible (parmi les calendriers du compte) peut également être sélectionné depuis cet écran.

- **Export calendrier global** : dans l'écran Planning, un bouton calendrier dans l'AppBar exporte en lot tous les repas visibles vers Google Calendar (calendrier configuré dans les préférences). Chaque repas est créé comme événement individuel. Un bouton calendrier est également disponible sur chaque tuile de repas pour un export individuel.

- **Heure repas cliquable** : dans l'écran Planning, l'heure affichée sur chaque repas est cliquable et ouvre un sélecteur d'heure pour modifier le créneau directement.

- **Changer / vider une recette depuis le planning** : un menu contextuel (kebab) sur chaque tuile de repas propose "Changer la recette" (ouvre le picker) et "Vider le créneau" (supprime la recette sans supprimer le créneau).

- **Liste de courses multi-recettes** : dans la liste de courses (bottom sheet), chaque ingrédient agrégé affiche en sous-titre la ou les recettes sources, permettant de savoir d'où provient chaque quantité.

- **Sélection multiple dans livres et recettes libres** : un appui long sur un livre ou une recette libre active le mode sélection multiple. L'AppBar contextuelle propose "Tout sélectionner" et "Supprimer" (avec confirmation). La sélection est limitée aux éléments de l'utilisateur connecté.

- **Affichage toutes les pages d'un livre** : dans l'écran "Recettes d'un livre", toutes les recettes (pages normales) sont désormais visibles par défaut, sans toggle. Le regroupement par sections reste disponible pour les membres du groupe.

- **Compteur d'énergie estimée (token usage)** : l'écran "Usage IA" affiche désormais une estimation de l'énergie consommée (en Wh) calculée à partir du nombre total de tokens, pour sensibiliser à l'empreinte énergétique des appels IA.

### Mise à jour release (14/05/2026 — v0.13.5)

- **Écran "Planning des repas"** : un nouvel écran est accessible depuis la barre de navigation principale (5e entrée, icône calendrier, entre Recherche et Brouillons). Il affiche la liste chronologique des repas planifiés de l'utilisateur connecté, groupés par date. Chaque repas affiche l'heure, le titre de la recette et la durée totale. Un appui sur un repas ouvre directement la fiche recette associée. Un bouton poubelle permet de supprimer un repas planifié après confirmation. Les repas passés sont affichés en mode atténué (opacité réduite). Si aucun repas n'est planifié, un écran vide avec message explicatif est affiché.
- **Sauvegarde locale en Firestore** : lors de chaque planification depuis la fiche recette (via le bottom sheet Google Calendar), le repas est désormais également sauvegardé dans Firestore (collection `planned_meals`) avec : identifiant utilisateur, identifiant et titre de la recette, date/heure planifiée, durée totale. Cette sauvegarde alimente l'écran Planning en temps réel via un stream Firestore.

### Mise à jour release (13/05/2026 — v0.13.4)

- **Bouton "Planifier" dans la fiche recette** : un bouton avec icône calendrier (`calendar_month_outlined`) apparaît dans l'en-tête de la section Ingrédients de la fiche recette, uniquement si la recette possède des ingrédients structurés. Il s'affiche côte à côte avec le bouton "Liste de courses" existant.
- **Bottom sheet de planification** : un appui sur le bouton Planifier ouvre un bottom sheet permettant de : choisir la date (sélecteur de date, par défaut aujourd'hui), choisir l'heure (sélecteur d'heure, par défaut 19h00), configurer le rappel en minutes (pré-rempli avec le temps de préparation de la recette). La durée est calculée automatiquement à partir des champs `prepTime` et `cookTime` de la recette. Un bouton "Ajouter à Google Calendar" déclenche la création de l'événement.
- **Intégration Google Calendar (API REST OAuth)** : la planification crée un événement "Préparer : [titre]" dans le calendrier Google principal de l'utilisateur, avec description contenant les ingrédients, les temps de préparation/cuisson et un rappel popup configurable. Sur web : OAuth via `FirebaseAuth.signInWithPopup` avec le scope `calendar.events`. Sur mobile/desktop : via `GoogleSignIn.instance.authorizationClient`.


- **Filtre par livre dans la page Brouillons** : dans l'écran "Brouillons", une barre de filtres défilable horizontalement apparaît lorsque les brouillons appartiennent à plusieurs livres différents. Les chips disponibles sont : "Tous" (vue par défaut), "Sans livre" (brouillons non rattachés à un livre), et un chip par livre distinct présent dans la liste. La barre est masquée si tous les brouillons appartiennent au même contexte (zéro ou un seul livre distinct). La sélection d'un chip filtre immédiatement la liste affichée.
- **Suppression d'un livre depuis la liste de ses recettes** : dans l'AppBar de l'écran "Recettes d'un livre", un bouton poubelle apparaît pour les Editors et Admins. Il déclenche un dialogue de confirmation à trois options : Annuler, "Détacher les recettes" (supprime le livre mais conserve toutes les recettes, qui deviennent des recettes libres), "Supprimer aussi les recettes" (supprime le livre ET toutes ses recettes de façon irréversible). Après suppression, l'utilisateur est redirigé vers l'écran d'accueil avec un message de confirmation.

### Mise à jour release (13/05/2026 — v0.12.85)

- **Onglet "Photos" dans le brouillon** : un quatrième onglet "Photos" est disponible dans l'écran de révision des brouillons (`DraftReviewScreen`), visible pour tous. Il affiche les illustrations associées à la recette dans une grille. Le propriétaire peut supprimer individuellement chaque photo. Si la recette possède un fichier source image (scan), un bouton "Extraire les illustrations" (ou "Ré-extraire" si des illustrations existent déjà) permet de lancer l'extraction automatique via l'IA.
- **Bouton IA dans l'AppBar du brouillon** : le propriétaire d'un brouillon dispose d'un bouton ✨ ("Améliorer avec l'IA") dans l'AppBar de l'écran de révision. Un appui ouvre un dialogue permettant de saisir des instructions libres (ex : "Reformate en style Cooklang strict", "Corrige les quantités"). Si la recette a un scan image source, une case à cocher optionnelle "Extraire les illustrations" est proposée. L'IA raffine alors le CookLang + titre + ingrédients selon les instructions, et met à jour le brouillon en place.

### Mise à jour release (13/05/2026 — v0.12.84)

- **Suivi des tokens IA** : chaque appel Gemini (extraction de recette, détection d'illustrations, recherche, génération, raffinement, etc.) est enregistré dans Firestore sous la collection `ai_usage`. Chaque enregistrement contient : uid utilisateur, fonctionnalité (feature), nombre de tokens en entrée/sortie/total, modèle utilisé, et horodatage.
- **Page "Usage IA"** : accessible depuis le menu compte (icône graphique), elle affiche un tableau récapitulatif de la consommation de tokens, filtrable par fonctionnalité. Les Admins peuvent également filtrer par utilisateur et voir la consommation globale de tous les membres. La page affiche le total d'appels, tokens d'entrée, de sortie et total, agrégés par feature.
- **Suppression du cache** : un bouton "Vider le cache" est disponible dans les paramètres, permettant de forcer la recharge des données depuis Firestore.

### Mise à jour release (13/05/2026 — v0.12.83)

- **Illustrations dans le brouillon** : les illustrations extraites par l'IA lors du scan (ou extraites manuellement depuis l'onglet Photos) sont stockées dans Firebase Storage sous `illustrations/{uid}/` et associées à la recette via le champ `image_urls`. Elles sont visibles dans l'onglet Photos du brouillon et persistent après validation.
- **Extraction IA depuis le scan** : depuis l'onglet Photos du brouillon, si la recette possède un scan image source, Gemini détecte automatiquement les zones de photographies culinaires dans l'image, découpe chaque région et l'uploade comme illustration séparée. Les illustrations existantes sont remplacées lors d'une ré-extraction.

### Mise à jour release (13/05/2026 — v0.12.74)

- **Fusion "Brouillons & Traitements" en WorkQueue** : les anciens onglets séparés "Brouillons" et "Traitements" sont fusionnés en une seule vue unifiée `WorkQueueScreen`. Cette vue affiche, dans une liste chronologique, à la fois les jobs de traitement en cours/terminés/en erreur et les brouillons de recettes non validés. Trois modes de filtrage sont disponibles : "Mes éléments" (vue par défaut), "Famille" (éléments des membres du groupe), "Tous" (admin uniquement — tous les utilisateurs). En mode famille et admin, les éléments sont regroupés par propriétaire dans des sections rétractables. La sélection multiple reste disponible pour les actions groupées (valider, réessayer, supprimer).

### Mise à jour release (12/05/2026 — v0.12.67)

- **Détection automatique des coins de document** : à l'ouverture de l'écran de recadrage (amélioration d'image), les 4 coins de la page ou du livre visible sont automatiquement détectés par analyse de gradient (Sobel + régression PCA). Une barre de progression orange apparaît en haut de l'image pendant l'analyse (~0,5 s). L'utilisateur peut ensuite affiner manuellement chaque coin. Un bouton ⊕ permet de relancer la détection à tout moment. Si le document n'est pas détectable (fond homogène, faible contraste), les coins reviennent à la position par défaut.
- **Sélection multiple de brouillons** : dans la liste des brouillons, un appui long sur un brouillon active le mode de sélection multiple. L'AppBar contextuelle affiche le nombre de sélections, avec actions "tout sélectionner", "valider" (✓) et "supprimer" (🗑). La validation nécessite une confirmation par dialogue ; la suppression idem (bouton rouge). Le FAB est masqué en mode sélection. Les brouillons des autres membres du groupe restent non sélectionnables (lecture seule).
- **Correction de la déduplication d'ingrédients** : les apostrophes typographiques (' ') et les caractères accentués français (é, è, ê, à, ç, ù, ô, î, â, û) sont normalisés avant le calcul de la clé d'ingrédient, évitant les doublons comme "tronçon d'asperge" × 2 causés par des apostrophes Unicode différentes retournées par Gemini.

### Mise à jour release (12/05/2026)

- **Téléchargement du scan original** : un bouton de téléchargement est disponible à côté du bouton de prévisualisation dans l'en-tête de toute recette disposant d'un fichier source.
- **Scan multi-pages** : lors de l'import d'une recette, l'utilisateur arrive dans un mode "Pages en attente" plutôt qu'un déclenchement immédiat. Il peut accumuler autant de pages qu'il souhaite (via fichier ou caméra), puis lancer l'analyse de toutes les pages en un seul appel Gemini multi-part.
- **Extraction automatique d'illustrations** : pour les scans image (JPEG/PNG), Gemini détecte automatiquement les zones de photographies culinaires. Chaque zone est découpée et uploadée sur Firebase Storage (`illustrations/`), puis associée à la recette créée.
- **Progression détaillée** : dans l'écran "Traitements", le job affiche l'étape courante ("Extraction du texte…", "Extraction des illustrations…") en italique pendant le traitement.
- **Texte collé conservé comme source** : lorsqu'un utilisateur colle un texte dans l'écran "Nouvelle recette" et le met en forme avec l'IA, le texte original est automatiquement uploadé sur Firebase Storage (`scans/`) et attaché à la recette comme fichier source (`sourceFileUrl`). Le bouton de téléchargement de l'original est alors disponible sur la fiche recette, exactement comme pour un scan.

### Mise à jour release (08/05/2026)

- **Copie cross-utilisateur de recettes/brouillons** : un utilisateur peut copier la recette validée ou le brouillon d'un membre de son groupe dans sa propre collection. La copie d'une recette validée est immédiatement disponible dans les recettes, sans validation nécessaire. La copie d'un brouillon crée un brouillon dans ses brouillons, à valider. La redirection est automatique vers la copie créée.
- **Affichage de l'origine** (auteur + livre) : dans l'AppBar de l'écran brouillon (DraftReviewScreen) et de l'écran détail recette, le nom de l'auteur (icône 👤) et le titre du livre source sont affichés sous le titre si la recette n'appartient pas à l'utilisateur connecté.
- **Protection des validations** : seul le propriétaire d'un brouillon peut le valider ou le supprimer (garde UI + vérification côté dépôt avant écriture). Un non-propriétaire voit uniquement le bouton "Copier".
- **Brouillons des membres du groupe** : l'écran Brouillons propose un toggle 👥 pour afficher les brouillons des membres du groupe, organisés par sections collapsibles par membre.
- **Cover automatique "Mes créations Kass'Dalle ✨"** : le livre IA est créé automatiquement au premier scan. Sa couverture est générée programmatiquement (dart:ui) et uploadée sur Firebase Storage. La migration silencieuse est déclenchée à l'ouverture de la bibliothèque.

### Mise à jour release (03/05/2026)

- Groupes familiaux : chaque utilisateur gère ses propres livres et recettes. Un utilisateur peut créer un groupe familial, y inviter d'autres membres (recherche par nom/email). Une fois dans un groupe, les livres et recettes validés des autres membres sont visibles par sections dans la bibliothèque et dans les recettes libres.
- Bibliothèque : sections "Mes livres" + "Livres de [membre]" avec toggles par section. Chaque section affiche une grille de livres.
- Recettes libres : sections "Mes recettes" + "Recettes de [membre]" avec toggles par section.
- Brouillons : visibles uniquement pour l'utilisateur connecté (inchangé).
- Traitements (admin) : l'admin voit tous les traitements de tous les utilisateurs avec filtre par utilisateur et affichage du propriétaire sur chaque tuile.
- Téléchargement APK : bouton "Télécharger l'APK Android" dans le menu compte, visible uniquement sur web/desktop. Pointe vers la dernière version intégrée au déploiement Firebase Hosting.
- Déploiement web : l'APK est désormais inclus dans chaque déploiement Firebase Hosting (`app-release.apk` servi sur le même domaine).

### Mise a jour release (02/05/2026)

- Ajout d'un mode de scan multi-intentions : recettes, couverture de livre, livre complet.
- Creation de brouillons livre a partir d'une photo de page de garde avec validation explicite.
- Ajout d'un traitement asynchrone en file d'attente : plusieurs imports peuvent etre lances sans attendre la fin du precedent.
- Ajout d'une page "Etat des traitements" pour suivre les scans en cours, termines et en erreur.
- Rattachement automatique des recettes extraites d'un document complet au livre cible, y compris en statut brouillon.
- Ajout/edition des champs structures en brouillon recette : portions, difficulte, temps preparation/cuisson, ingredients structures.
- Ajout/edition des champs structures en brouillon livre : sous-titre, editeur, serie, ISBN, description, tags.

### Mise a jour release (01/05/2026)

- Activation complete du parcours Android Google Sign-In (certificats debug/release et configuration Firebase Android).
- Ajout d'un profil utilisateur detaille (role, permissions, identite, activite, deconnexion).
- Ajout d'un visualiseur de source recette (image zoomable ou ouverture externe PDF/DOCX).
- Stabilisation du flux d'import scan (correction d'un crash Riverpod lors de la fermeture d'ecran).
- Uniformisation des icones applicatives a partir de l'asset `assets/icon.jpg` pour Android, iOS, Web, Windows et macOS.

---

## 1. Contexte et Objectif

**Kass'dalle** est une application privée à usage familial permettant de digitaliser une collection personnelle de livres de cuisine physiques et de notes d'ateliers culinaires (ex : Sasasa, recettes du terroir belge). L'application transforme des photos de pages de recettes en fiches numériques structurées, consultables et interactives, grâce à l'IA de reconnaissance visuelle (Gemini Vision) et au format de balisage Cooklang.

L'application est destinée à un cercle familial restreint :
- quelques personnes peuvent **modifier** et enrichir le contenu ;
- tous les membres authentifiés peuvent **consulter** et **annoter** les recettes ;
- un administrateur gère les accès.

---

## 2. Plateformes Cibles

| Plateforme | Usage principal | Particularités |
|---|---|---|
| **Mobile (iOS / Android)** | Scan, saisie, consultation | Accès caméra pour la capture des recettes; possibilités d'uploader des scans |
| **Web** | Consultation, correction, gestion | Pas de scan caméra ; interface plein écran ; possibilités d'uploader des scans pour suivre le meme process que la version mobile |
| **Desktop (Windows / macOS)** | Consultation, correction, gestion | Identique au Web ; fenêtre redimensionnable |

Les trois plateformes partagent le même backend Firebase et la même codebase Flutter. Seul le module de scan est conditionné à la plateforme mobile.

**Ce qui change n'est pas la plateforme, c'est la largeur.** Toutes les routes — y compris l'administration complète — sont ouvertes sur mobile. La bascule se fait sur trois seuils (`PlatformUtils`) : navigation latérale ou barre basse à 800 px, présentation compacte du détail à 700 px, raccourci galerie à 900 px. Un navigateur de bureau rétréci passe donc en présentation compacte, et un mobile en paysage large peut recevoir la présentation étendue. Aucune fonctionnalité n'est réservée à un format : la présentation compacte réorganise, elle ne retire pas. Dépendent réellement de la plateforme, et d'elle seule : la caméra (mobile et web), la mise à jour par APK et le lien de téléchargement de l'APK (Android natif / grand écran), le partage du PDF (feuille de partage sur mobile, téléchargement dans le navigateur), et les raccourcis clavier, sans effet là où il n'y a pas de clavier.

---

## 3. Authentification et Rôles

### 3.1 Connexion

L'authentification est exclusivement basée sur **Google Sign-In** (Firebase Auth). Aucune création de compte par email/mot de passe n'est prévue.

- À la première ouverture, l'utilisateur est invité à se connecter avec son compte Google.
- **Un compte neuf naît en attente (`pending`) et n'accède à rien.** Il voit une salle d'attente qui affiche son adresse et l'invite à la communiquer ; l'écran se referme de lui-même dès qu'un rôle lui est attribué.
- **Le rôle n'est jamais choisi par l'application.** Les règles Firestore imposent `pending` à la création, et seul un Admin le change ensuite.
- **Le compte fondateur** (`china.fred.75@gmail.com`) est le seul administrateur d'origine : le déclencheur serveur `enforceFounderRole` lui rend le rôle `admin` en vérifiant l'adresse du compte **Auth**, jamais celle écrite dans le document. Il rétablit aussi ce rôle s'il est rabaissé ou révoqué — un administrateur adoubé ne peut pas mettre dehors celui qui l'a nommé.

### 3.2 Rôles

| Rôle | Accès |
|---|---|
| **Admin** | Tout : gestion des utilisateurs, des rôles, des livres, des recettes, des annotations. Peut promouvoir d'autres utilisateurs en Admin ou Editor. |
| **Editor** | Création, modification et suppression de livres et de recettes. Validation des brouillons IA. Peut annoter. |
| **Reader** | Consultation uniquement. Peut annoter les recettes (notes personnelles) mais ne peut pas modifier le contenu des recettes. |
| **Pending** | Rien. Ni livre, ni recette, ni référentiel, ni appel d'IA. C'est l'état par défaut d'un compte qui vient d'être créé. |

> Règle de sécurité clé : être connecté ne donne aucun accès. Tout ce qui est partagé — livres, recettes, annotations, référentiels, grille tarifaire — exige un compte **nommé et non révoqué** (`isApproved()` dans `firestore.rules`). La révocation vaut pour tous les rôles, Admin compris, côté règles comme côté Cloud Functions.

### 3.3 Gestion des utilisateurs (Admin)

Un écran dédié (Web / Desktop / Mobile) permet à l'Admin de :
- voir la liste des utilisateurs connectés au moins une fois, **les comptes en attente en tête**, précédés d'un bandeau qui les compte ;
- attribuer ou modifier un rôle (Pending → Reader, Reader → Editor, Editor → Admin) — l'attribution d'un premier rôle **est** l'approbation ;
- révoquer l'accès d'un utilisateur.

---

## 4. Parcours Utilisateur

### 4.1 Gestion d'un Livre

**Qui :** Editor ou Admin.

1. L'utilisateur crée un nouveau livre via un formulaire.
2. Il saisit :
   - Titre du livre
   - Auteur(s)
   - Année de publication (optionnel)
   - Langue principale des recettes (liste déroulante)
   - Tags/thèmes associés au livre (ex : Terroir belge, Pâtisserie)
3. Il peut scanner ou importer une photo de la couverture (mobile : caméra ou galerie ; web/desktop : import de fichier).
4. Le livre est enregistré et apparaît dans la bibliothèque.

Creation automatique via scan de couverture :
- L'utilisateur peut photographier ou importer la page de garde.
- L'IA extrait les champs structures du livre (titre, auteur, sous-titre, editeur, serie, annee, langue, ISBN, description, tags).
- Un brouillon livre est cree avec statut `draft`.
- L'utilisateur valide ensuite ce brouillon depuis l'ecran d'edition du livre via l'action "Valider le livre".

**Modification / Suppression :** accessible via le détail du livre. La suppression d'un livre demande une confirmation explicite car elle entraîne la dissociation des recettes liées (les recettes ne sont pas supprimées, elles deviennent "sans livre").

---

### 4.2 Capture d'une Recette (caméra : mobile et web — import de fichier : partout)

**Qui :** Editor ou Admin.

**Étape 1 — Sélection de la source**
- L'utilisateur sélectionne le livre source depuis la bibliothèque (ou crée un nouveau livre à la volée).
- Il indique optionnellement le numéro de page dans le livre.

**Étape 2 — Capture photo**
- L'utilisateur prend une ou plusieurs photos de la page de recette via la caméra intégrée.
- L'interface propose un outil de recadrage et de correction de perspective avant envoi.
- Il est possible d'ajouter plusieurs images pour une recette qui s'étale sur plusieurs pages.

Comportement asynchrone :
- Chaque import cree un job de traitement IA en file d'attente.
- L'utilisateur peut lancer un second scan pendant qu'un premier est encore en cours.
- Les brouillons generes apparaissent automatiquement a la fin de chaque job.

**Étape 3 — Traitement IA (pipeline asynchrone)**
- Les images sont déposées dans la **quarantaine** (`quarantine/{uid}/`), inspectées côté serveur — type MIME, signature binaire, taille — puis promues. Aucune image ne rejoint un dossier publié sans être passée par la modération.
- Le client crée un job dans `processing_jobs/` et n'attend rien : `jobDispatcher` le met en file Cloud Tasks, `recipeProcessor` déroule le pipeline.
- Deux à cinq appels d'IA sont déclenchés avec des prompts structurés. **Le moteur n'est pas figé dans le code** : chaque poste est routé vers Gemini ou Claude selon `app_config/ai_routing_policy`, modifiable depuis *Admin › Moteur d'IA* sans déploiement. Par défaut, Gemini.
- Le moteur retourne une réponse JSON contenant :
  - Le titre détecté de la recette
  - La langue détectée
  - Le contenu de la recette formaté directement en **Cooklang**
  - Des suggestions de tags (thèmes, type de cuisine, difficulté, temps de préparation, temps de cuisson)
- L'étape courante du job (`current_step`) est affichée dans l'écran *Traitements*. Un import complet prend de quelques dizaines de secondes à quelques minutes ; l'utilisateur peut en lancer un second pendant ce temps.
- Après trois échecs, le job part en `dead_letters/`, d'où un administrateur le relance depuis *Admin › File d'échecs*.

**Étape 4 — Écran de Révision (Split View)**
- L'utilisateur arrive sur un écran divisé en deux panneaux :
  - **Panneau gauche** : éditeur de texte Cooklang brut (modifiable directement, avec coloration syntaxique basique).
  - **Panneau droit** : rendu interactif en temps réel de la recette (liste d'ingrédients + instructions formatées).
- L'utilisateur peut corriger le Cooklang directement dans le panneau gauche ; le rendu se met à jour en temps réel.
- Un bouton **"Voir l'original"** (icône scanner) est toujours présent dans la barre d'actions :
  - Si le fichier source est une image (jpg/png) : affiche une visionneuse plein écran zoomable.
  - Si le fichier est un PDF ou un DOCX : ouvre le document dans le navigateur ou le lecteur système.
  - Sur mobile (vue en onglets), un onglet dédié **"Original"** affiche l'image directement dans l'écran.
- Le document source est **lié à vie à la recette** : il ne peut jamais être dissocié ni supprimé tant que la recette existe.
- Il complète / corrige les métadonnées suggérées par Gemini : titre, tags, numéro de page.
- Deux actions disponibles :
  - **Enregistrer en brouillon** (`draft`) : la recette est sauvegardée mais pas marquée comme validée.
  - **Valider** : la recette passe au statut `validated`.

---

### 4.3 Saisie Manuelle d'une Recette (Web / Desktop / Mobile)

**Qui :** Editor ou Admin.

Pour les recettes sans photo source (recettes mémorisées, recettes tapées manuellement) :
- L'utilisateur accède à un formulaire de création de recette.
- Il saisit directement le contenu en Cooklang dans l'éditeur avec rendu split view.
- Les métadonnées sont saisies manuellement.
- Un bouton **"Mettre en forme avec l'IA"** permet de coller un texte brut (texte web, note, etc.) et de le convertir automatiquement en CookLang via Gemini.
- **Le texte original collé est automatiquement conservé** : il est uploadé sur Firebase Storage et attaché à la recette comme fichier source. Le bouton de téléchargement de l'original apparaît ensuite dans l'en-tête de la recette, comme pour un scan.
- Si l'IA n'est pas utilisée (saisie CookLang directe), aucun fichier source n'est attaché.

---

### 4.4 Consultation d'une Recette

**Qui :** Tout utilisateur authentifié (Reader, Editor, Admin).

1. L'utilisateur navigue dans la bibliothèque (vue par livre ou vue globale).
2. Il peut filtrer/rechercher par : titre, ingrédient, tag, livre, type de cuisine.
3. Il clique sur une recette et accède à la fiche détaillée :
   - **En-tête** : titre, livre source, page, langue, tags.
   - **Portions** : affichées sous forme de chip (ex : « 4 portions ») si renseignées dans les métadonnées CookLang (`>> portions: 4`). Ce champ est également stocké comme donnée structurée dans Firestore (`portions: int?`).
   - **Ingrédients** : liste structurée extraite du Cooklang, avec quantités et unités bien formatées. Chaque ingrédient est stocké dans Firestore sous forme d'objet `{ name, qty, unit }` (champ `ingredients`).
   - **Instructions** : étapes numérotées, avec mise en valeur des ingrédients et du matériel (rendu Cooklang interactif).
   - **Document original** : bouton "Voir l'original" (icône scanner) toujours visible dans la barre d'actions. Ouvre l'image en plein écran zoomable ou le PDF dans le navigateur.
   - **Annotations** : section en bas de fiche pour consulter et ajouter des notes personnelles.

---

### 4.5 Annotation d'une Recette

**Qui :** Tout utilisateur authentifié (Reader, Editor, Admin).

- Chaque recette dispose d'une section d'annotations visible en bas de la fiche.
- Un utilisateur peut ajouter une annotation de type :
  - `note`, affiché **« Remarque »** : observation personnelle
  - `tip`, affiché **« Astuce »** : conseil de préparation
  - `correction` : signalement d'une erreur dans la recette numérisée
- L'annotation affiche le nom de l'auteur et la date.
- Le dialogue d'annotation rappelle en tête la note chiffrée de l'utilisateur
  (« Ma note ») avec un raccourci vers le sélecteur 0–10. C'est un raccourci :
  la note reste stockée dans `recipe_ratings`, jamais dans l'annotation.
- Un utilisateur peut modifier ou supprimer **ses propres** annotations.
- Un Admin ou Editor peut supprimer n'importe quelle annotation.

---

## 5. Modules Fonctionnels

### 5.1 Module Bibliothèque (tous les clients)

- Vue en grille des livres avec couverture, titre, auteur et compteur de recettes.
- Si l'utilisateur appartient à un ou plusieurs groupes familiaux, la bibliothèque est divisée en sections :
  - **Mes livres** : tous les livres de l'utilisateur connecté (validés et brouillons).
  - **Livres de [Prénom]** : une section par membre du groupe, affichant uniquement ses livres validés.
- Chaque section dispose d'un toggle pour la masquer/afficher.
- **Rangement au glisser-déposer** : dans « Mes livres », maintenir une couverture puis la déposer
  sur une autre la met à sa place. L'emplacement visé s'éclaire pendant le déplacement, et la
  grille ne se réorganise qu'au lâcher — les voisines ne dansent pas sous le doigt. L'ordre est
  enregistré et retrouvé à la session suivante, sur tous les appareils. C'est un choix de **lecteur** : il ne modifie pas les livres, que toute la
  famille partage, et ne change donc rien à ce que voient les autres membres. Un livre créé après
  coup se range à la fin, un livre supprimé disparaît sans laisser de trou.
- Accès à la liste des recettes d'un livre.
- Vue globale "Toutes les recettes" (sans filtre de livre).

### 5.2 Module Scan (caméra : mobile et web — import de fichier : partout)

- Accès caméra natif sur mobile, `getUserMedia` sur le web ; l'import de fichier (photo, PDF, DOCX, texte collé) est disponible sur les quatre plateformes.
- Recadrage et correction de perspective avant envoi.
- **Mode multi-pages** : après sélection de la première image, l'utilisateur entre en mode "Pages en attente". Il peut ajouter d'autres pages (fichier ou caméra) avant de lancer l'analyse globale. Toutes les pages sont envoyées en un seul appel Gemini multi-part.
- Déclenchement de l'appel Gemini.
- **Extraction automatique d'illustrations** : l'IA identifie les photographies culinaires **sur chaque page** du scan, les découpe, et les propose comme illustrations de la recette.
  - **Trois filtres locaux** écartent d'abord ce qui n'est manifestement pas une photo : trop petit, bande plutôt qu'image, ou presque blanc et sans couleur — c'est-à-dire du papier ou du texte. Ils ne coûtent aucun appel d'IA, et sont volontairement conservateurs : jeter une vraie photo est irrattrapable.
  - **Les découpes passent par la modération**, comme toute image vue par la famille. Une découpe refusée, ou laissée en attente parce que le moteur est injoignable, n'apparaît simplement pas dans la recette : pas de repli.
  - **Quand une page porte plusieurs recettes, chacune reçoit sa propre copie des photos.** Elles se partageaient le même fichier : invisible tant que supprimer une illustration se contente d'oublier son adresse, mais le jour où l'on supprime vraiment le fichier, la première suppression viderait l'image de l'autre recette sans un mot. La modération, elle, n'a lieu qu'une fois — c'est la même image.
- **Progression affichée** : l'écran Traitements affiche l'étape courante du traitement en cours.

### 5.3 Module Révision et Édition (tous les clients)

- Éditeur Cooklang brut avec coloration syntaxique basique.
- Rendu interactif Cooklang en temps réel (panneau split).
- Visualisation du scan original.
- Gestion des métadonnées (titre, tags, page, langue, statut).
- Edition directe des champs structures recette (portions, difficulte, temps, ingredients structures) en brouillon.
- Validation explicite des brouillons livre crees par IA.
- Sur Web / Desktop : accessible pour modifier des recettes existantes (pas de nouveau scan).

### 5.4 Module Traitements IA (tous les clients)

- Liste des traitements recents avec statut (`queued`, `processing`, `done`, `error`).
- Indicateur de traitements actifs visible dans la zone Brouillons.
- Navigation directe vers les brouillons recettes ou le brouillon livre cree a la fin du traitement.
- **Vue Admin** : l'admin voit tous les traitements de tous les utilisateurs. Un filtre par utilisateur (dropdown) permet de restreindre l'affichage. Chaque tuile affiche le nom du propriétaire du traitement.

### 5.5 Module Recherche et Filtres (tous les clients)

- Recherche textuelle full-text sur : titre, ingrédients (champ `ingredients_index`).
- Filtres combinables : livre, type de cuisine, thème, difficulté, statut.
- Tri par : date de création, titre alphabétique.

### 5.6 Module Administration (Admin uniquement)

Un écran d'accueil d'administration donne accès à dix zones. Toutes sont ouvertes sur mobile : rien n'est réservé au grand écran.

- **Utilisateurs** : liste, attribution de rôle, révocation. Les comptes en attente sont mis en tête, sous un bandeau qui les compte — l'attribution d'un premier rôle *est* l'approbation.
- **Brouillons et annotations** : vue sur les recettes en statut `draft` et sur l'ensemble des annotations de toutes les recettes.
- **Moteur d'IA** : quel moteur — Gemini ou Claude — sert quel poste, poste par poste, et la grille tarifaire. Les deux vivent dans Firestore : une bascule prend effet en moins d'une minute, sans déploiement.
- **Coûts** : dépense d'IA par poste, par processus, par moteur et par compte, sur la période choisie ; coûts d'infrastructure GCP par service ; réconciliation mensuelle entre l'estimé et le facturé. Le tableau se trie par ses en-têtes et se filtre par le libellé du poste.
- **Plafonds de dépense** : deux limites par compte et par jour — en euros et en nombre d'appels. La seconde protège pendant une panne de grille tarifaire, quand plus rien n'est chiffré. Une alerte mensuelle est vérifiée chaque matin.
- **Attestation de l'application (App Check)** : trois modes — désactivé, observation, exigé. Le passage en *exigé* est refusé depuis un client non attesté, pour que l'interrupteur ne s'enferme pas lui-même.
- **Modération des images** : journal complet de ce que la modération a laissé passer, refusé, mis en attente ou n'a pas pu juger ; décision humaine sur les images en attente ; relance des images sans verdict.
- **Référentiels** : KPIs du référentiel nutrition, enrichissement des unités et des ingrédients, politique de calcul nutritionnel (seuils d'affichage, repli, priorité des sources).
- **File d'échecs** : jobs d'import abandonnés après trois tentatives, avec leur motif — relance ou purge.
- **Logs** : explorateur de Cloud Logging, filtré INFO+ par défaut.

### 5.7 Module Groupes Familiaux (tous les clients)

- Un utilisateur peut créer un ou plusieurs groupes familiaux (avec un nom libre).
- Le créateur est propriétaire du groupe. Il peut renommer ou supprimer le groupe.
- Invitation de membres : recherche d'utilisateurs par nom ou email (parmi les comptes existants). Ajout en un clic.
- Retrait de membres : le propriétaire peut retirer n'importe quel membre. Un non-propriétaire peut quitter le groupe.
- Accès depuis le menu compte (icône en haut à droite) → "Groupes familiaux".
- Une fois membre d'un groupe, les livres et recettes validés des autres membres deviennent visibles dans la bibliothèque et les recettes libres, organisés par sections.

### 5.8 Module Planning des Repas (tous les clients)

- Écran dédié "Planning des repas" accessible depuis la navigation principale (5e entrée, icône calendrier).
- **Deux onglets, deux lectures des mêmes repas** : *Liste* — l'affichage chronologique groupé par journée — et *Calendrier* — la grille du mois.
- **Onglet Calendrier** : une **bande de trois mois** occupant le tiers haut de l'écran — le mois courant au centre, le précédent et le suivant à ses côtés en plus petit. Les jours porteurs de repas sont surlignés, chacun montrant une pastille par repas ; un appui ouvre l'agenda du jour, **en bas**, avec les mêmes actions que dans la liste. Trois pastilles au plus par case, le surplus est annoncé par un « +n ».
- **La bande ne déborde jamais de la hauteur qu'on lui donne** : la taille d'une case se déduit de la hauteur reçue *et* de la largeur restante, jamais d'une seule des deux. Une grille qui prend toute la largeur disponible produit des cases de deux cents pixels — un mois qui ne tient plus dans l'écran n'est plus un calendrier.
- Sur un écran trop étroit pour trois mois entiers, seul le mois central s'affiche : un mois tronqué se lit moins bien que pas de mois du tout, et les flèches suffisent à y aller.
- Les pastilles se lisent dans des champs stockés, jamais dans une règle rejouée : pleine pour un repas avec recette, pâle pour un créneau vide, creuse pour un **jour de préparation** — ce jour-là on cuisine, même si l'on ne sert rien.
- La navigation vers le passé s'arrête là où s'arrête l'historique chargé (quatre-vingt-dix jours) : un mois vide faute de chargement ressemblerait à un mois sans repas.
- Affichage chronologique des repas planifiés de l'utilisateur, groupés par journée.
- Chaque entrée affiche l'heure (cliquable pour modifier), le titre de la recette et la durée totale.
- Navigation directe vers la fiche recette en appuyant sur un repas.
- Menu contextuel sur chaque repas : "Changer la recette", "Vider le créneau", "Supprimer".
- Bouton calendrier sur chaque repas pour export individuel vers Google Calendar.
- Export global vers Google Calendar (tous les repas du planning courant en un clic).
- Suppression d'un repas avec dialogue de confirmation.
- Affichage atténué des repas passés.
- Alimentation en temps réel via un stream Firestore.
- **Batch planning** : bouton "Nouveau planning" pour générer un cycle complet de repas, avec suggestion IA ou assignation manuelle par créneau.
  - Sur **grand écran**, la demande de suggestions est un bouton nommé — *Planifier avec l'IA*, qui annonce le nombre de créneaux vides — posé juste au-dessus de *Valider le planning*. Sur **mobile**, elle reste une icône dans la barre de titre, faute de place. Les deux ouvrent le même menu : compléter les créneaux vides, ou tout regénérer.
  - **La question « où chercher des recettes ? » est posée dans les deux cas**, pour le cycle entier comme pour un créneau isolé : mes recettes validées, mes brouillons, celles de la famille, et faut-il inventer quand rien ne convient. C'est le même choix, donc la même feuille.
- **Configuration des préférences** : accès depuis l'icône engrenage — nombre de repas par cycle, jour de démarrage, heure par défaut, contraintes quotidiennes et globales en langage naturel, choix du calendrier Google cible.
- **Chaque jour de la semaine peut porter sa propre heure de repas**, à côté du temps de préparation et des parts. Un jour qui n'en a pas suit l'heure par défaut, et ne stocke rien. **Changer l'heure par défaut ramène tous les jours à elle** — l'écran annonce combien de jours personnalisés seront remis à l'heure avant de le faire.

### 5.9 Module Nutrition (tous les clients)

- Valeurs nutritionnelles calculées à partir des ingrédients de la recette, d'un référentiel partagé (`nutrition_ingredients`, `nutrition_units`) et de l'IA quand le référentiel ne sait pas.
- **Les valeurs affichées sont dérivées, jamais stockées pour un lecteur** : les calories par portion valent le total divisé par le nombre de parts choisi. Changer ce nombre ne touche pas la recette partagée.
- Un ingrédient que le référentiel ignore est estimé plutôt qu'ignoré : une approximation signalée vaut mieux qu'un ingrédient qui disparaît du calcul.
- La politique de calcul — seuils d'affichage, priorité des sources, repli — se règle depuis l'administration.

### 5.10 Module Liste de courses (tous les clients)

- Construite depuis les repas **à venir** du planning : une liste qui reprend les courses de repas déjà mangés ne sert à rien.
- Elle connaît les brouillons et les recettes des autres membres du groupe, pas seulement les recettes validées de l'utilisateur.
- Les ingrédients sont fusionnés en produits d'achat et rangés par rayon.
- **Envoi vers Google Tasks** : les rayons deviennent des tâches, les articles des sous-tâches cochables. Seuls les articles non cochés partent.

### 5.11 Module Modération des images (tous les clients — revue réservée à l'Admin)

- **Toute image passe par la quarantaine**, puis par Cloud Vision, avant d'être publiée. Les quatre portes qui publiaient en direct — couverture de livre, illustration de recette, illustration de brouillon, couverture de recette libre — sont fermées en écriture côté Storage.
- **Le serveur ne fait pas exception.** Les illustrations découpées dans un scan par le pipeline d'import empruntent la même porte : elles sont déposées en quarantaine, jugées, puis promues. Elles écrivaient auparavant en direct avec les droits de l'Admin SDK — donc sans verdict, alors que ce sont des photographies choisies par une personne.
- Trois issues : **approuvée** (le cas courant, quelques secondes), **refusée** (jamais publiée, motif annoncé, image conservée pour un administrateur), **à revoir** (attend une décision humaine).
- Le contexte culinaire l'emporte sur la violence ; le contenu sexuel explicite ne bénéficie d'aucun contexte.
- **Pas de repli** : moteur injoignable, l'image attend et l'écran le dit. Publier par défaut modérerait pour rien ; refuser par défaut accuserait à tort.
- La revue vit dans *Admin › Modération*, et montre aussi bien ce qui est passé que ce qui a été bloqué.

### 5.12 Module Export PDF (tous les clients)

- Export d'une recette en PDF mis en forme, avec ses photos, ses badges et ses minuteurs.
- Sur mobile, le PDF part dans la feuille de partage du système ; sur web et desktop, il se télécharge.

---

## 6. Règles Métier

| Règle | Détail |
|---|---|
| Accès conditionnel | Toute consultation requiert une authentification Google active. |
| Accès conditionnel (2) | Un compte connecté mais non nommé (`pending`) n'accède à rien. L'approbation est le geste par lequel un Admin lui donne son premier rôle. |
| Premier admin | Le compte **fondateur** — l'adresse `china.fred.75@gmail.com`, vérifiée sur le compte Auth par le déclencheur `enforceFounderRole` — est administrateur, et le reste. Tous les autres administrateurs procèdent d'une nomination. La règle précédente (« le premier UID enregistré reçoit `admin` ») était appliquée **par le client** : elle laissait n'importe qui créer son document avec `role: "admin"`. |
| Autorité sur le fondateur | Seul le fondateur peut modifier son propre rôle ou sa révocation, et son compte ne peut pas être supprimé. Sans cette réserve, un administrateur adoubé pouvait destituer celui qui l'avait nommé. |
| Conservation du scan | L'image ou le fichier source (PDF/image) est toujours conservé dans Firebase Storage et lié à vie à la recette (`sourceFileUrl`). Il ne peut pas être supprimé tant que la recette existe. |
| Brouillons visibles | Les recettes en statut `draft` sont visibles uniquement par leur propriétaire (si Editor/Admin). Les brouillons d'un groupe sont visibles en lecture seule via le toggle 👥 dans l'écran Brouillons. |
| Isolation des données | Chaque utilisateur possède ses propres livres et recettes (champ `created_by`). La visibilité cross-utilisateur est contrôlée exclusivement par l'appartenance aux groupes familiaux. |
| Validation exclusive | Seul le propriétaire d'un brouillon peut le valider ou le supprimer. Cette règle est enforced à la fois dans l'UI (boutons masqués) et dans le dépôt (vérification Firestore avant écriture). |
| Copie cross-utilisateur | Tout membre d'un groupe peut copier une recette ou un brouillon d'un autre membre. La copie d'une recette validée hérite du statut `validated`. La copie d'un brouillon crée un brouillon indépendant (`draft`). Dans les deux cas la copie n'hérite pas des images. |
| Annotations non modifiables par autrui | Un Reader ne peut modifier/supprimer que ses propres annotations. |
| Multi-pages | Une recette peut avoir plusieurs images sources (scan multi-pages). |
| Toute recette a un livre | Il n'y a plus de recette orpheline : sans choix, elle rejoint « Mes recettes libres » ; conçue par l'IA, elle rejoint « Mes créations Kass'Dalle ». La règle est posée à l'entonnoir de création, pas dans un écran. |
| Les livres système ne se suppriment pas | « Mes recettes libres », « Mes créations Kass'Dalle » et « Mes recettes secrètes » se **renomment** — c'est leur tag interne qui les identifie, pas leur titre — mais ne se suppriment ni depuis l'écran, ni depuis le code, ni depuis les Security Rules. Ce sont les destinations par défaut : les perdre laisserait la règle ci-dessus sans issue. |
| Deux icônes, deux sens | Le **robot** marque ce qu'une machine a produit — une raison de recherche, une valeur estimée, une recette conçue, le pourquoi d'un repas. Les **étoiles** et la **baguette** sont des verbes : générer, suggérer, affiner. Les confondre laisse l'utilisateur devant une étoile sans savoir si elle annonce un bouton ou un constat. |
| Une contrainte d'ensemble se donne à chaque appel | L'IA conçoit les plats **un créneau à la fois**. Une consigne qui porte sur la semaine — la variété — n'a de sens que si chaque appel voit ce que les autres ont déjà produit. Sept appels indépendants respectant chacun « fais varier » rendent sept fois le même réflexe. |
| Adapter ne modifie jamais l'originale | Une recette est un document partagé : plusieurs membres la lisent et la cuisinent en même temps, chacun pour un nombre de parts différent. Redimensionner se fait sur une **dérivée** (rien de stocké, tout recalculé à l'affichage), à défaut sur une **copie attachée** à son porteur, jamais dans le document commun. Un état propre à une personne — parts choisies, liste de courses — vit sous `users/{uid}/…`. Le symptôme d'une violation est silencieux : chacun écrase le résultat de l'autre, sans erreur. |
| Aucune image publiée sans modération | Les dossiers publiés sont fermés en écriture côté Storage. La seule porte est la quarantaine, suivie d'un verdict. Une image sans verdict attend : ni publiée, ni refusée. |
| Pas de repli sur une valeur plausible | Grille tarifaire illisible, taux de change absent : on affiche la panne ou l'unité d'origine, jamais une constante figée dans le code. Un coût manquant se voit ; un coût faux ne se voit pas. Les appels passés pendant une panne de grille sont enregistrés **sans montant**, comptés à part. |
| Plafond de dépense par compte | Deux limites par compte et par jour, en euros **et** en nombre d'appels — la seconde protège pendant une panne de grille, quand plus rien n'est chiffré. Le refus arrive avant la dépense ; un import coupé par le plafond part directement en dead letter, sans réessayer. |
| Aucun catch silencieux | Toute erreur est journalisée — `logError` côté Functions, `ErrorReportService` côté Flutter — y compris quand le code retourne ensuite un résultat dégradé. C'est la règle la plus stricte du projet, et la CI la fait respecter. |

---

## 7. Périmètre — ce qui est livré, ce qui reste

### Livré
- Authentification Google, sas d'entrée `pending`, rôles et révocation
- CRUD livres et recettes, groupes familiaux
- Import (photo, PDF, DOCX, texte collé) → CookLang, par un pipeline asynchrone
- Écran de révision split view, rendu interactif CookLang, mode lecture livre
- Recherche et filtres, annotations, notes personnelles
- Planning des repas + intégration Google Calendar, conseils de conservation
- Liste de courses des repas à venir, envoyée dans Google Tasks (rayons en tâches, articles en sous-tâches cochables)
- Nutrition calculée depuis un référentiel partagé, dérivée du nombre de parts choisi
- Export PDF d'une recette, partagé ou téléchargé selon la plateforme
- Illustrations : extraction depuis un scan, retouche, génération, conseil de dressage
- Routage multi-fournisseur Gemini / Claude, piloté depuis l'administration
- Comptabilité des coûts d'IA par poste, moteur et compte, plafonds quotidiens, réconciliation mensuelle
- Modération de toutes les images par Cloud Vision, avec journal de revue
- Attestation App Check (web, Android)
- Plateformes : Mobile, Web, Desktop

### Reste à faire

| Sujet | Pourquoi ce n'est pas fait | Complexité |
|---|---|---|
| **Mode hors-ligne** | Aucune persistance locale n'est activée. La cuisine est précisément l'endroit où le réseau manque. | Moyenne |
| **Partage externe (lien public)** | Rien ne sort aujourd'hui du cercle authentifié. Demande une décision sur ce qu'un lien expose, et pour combien de temps. | Faible |
| **Minuteur interactif depuis CookLang** | Les durées sont analysées et affichées ; rien ne décompte. Demande des notifications locales. | Faible |
| **Attestation du client Windows** | Sa seule voie serait un jeton de débogage, c'est-à-dire un secret partagé dans un binaire distribué. Limite assumée, non contournable par une exemption de plateforme. | — |

---

## 8. Diagrammes d'états et de séquence

### 8.1 États d'une recette (`ReviewStatus`)

Une recette passe par trois états définis dans l'enum `ReviewStatus` : `draft`, `inReview`, `validated`.

```mermaid
stateDiagram-v2
    [*] --> draft : Création\n(scan IA ou saisie manuelle)

    draft --> inReview : Ouverture écran révision\n(Editor / Admin)
    inReview --> draft : "Enregistrer brouillon"
    inReview --> validated : "Valider"

    validated --> inReview : Modifier la recette\n(Editor / Admin)

    draft --> [*] : Supprimer (Editor / Admin)
    validated --> [*] : Supprimer (Editor / Admin)

    note right of draft
        Visible uniquement
        par Editor et Admin
    end note

    note right of validated
        Visible par tous
        les utilisateurs authentifiés
    end note
```

### 8.2 États du processus de scan (`ScanStatus`)

Le scan est le process d'acquisition d'un fichier image, de son envoi vers Firebase Storage puis de son analyse par Gemini. Ces états sont gérés dans `ScanState`.

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> picking : Lancer le scan\n(bouton "Numériser")
    picking --> uploading : Fichier sélectionné
    picking --> error : Annulation / erreur sélection

    uploading --> processing : Upload terminé\n(Firebase Storage → URL)
    uploading --> error : Erreur réseau / stockage

    processing --> done : Réponse JSON Gemini reçue\nRecette(s) créées en draft
    processing --> error : Timeout / erreur Gemini

    done --> [*] : Redirection écran révision

    error --> idle : Réessayer
```

### 8.3 États d'un utilisateur (`UserRole` + `isRevoked`)

```mermaid
stateDiagram-v2
    [*] --> pending : Première connexion Google\n(rôle imposé par les règles)

    pending --> reader : Approbation par Admin
    pending --> editor : Approbation par Admin
    pending --> admin : Approbation par Admin
    pending --> revoked : Refus par Admin

    reader --> editor : Promotion par Admin
    editor --> admin : Promotion par Admin
    admin --> editor : Rétrogradation par Admin
    editor --> reader : Rétrogradation par Admin

    reader --> revoked : Révocation par Admin
    editor --> revoked : Révocation par Admin
    admin --> revoked : Révocation par Admin

    revoked --> reader : Réactivation par Admin

    note right of pending
        Aucun accès : ni lecture,
        ni écriture, ni appel d'IA.
        Salle d'attente (/pending)
    end note

    note right of reader
        Consultation + annotations
        uniquement
    end note

    note right of editor
        CRUD livres, recettes
        et validation des brouillons
    end note

    note right of admin
        Gestion des utilisateurs
        + tous les droits Editor
    end note

    note right of revoked
        Accès bloqué
        (isRevoked = true)
    end note
```

---

### 8.4 Diagramme de séquence — Import et validation d'une recette

Ce diagramme couvre le flux complet depuis la sélection du fichier jusqu'à la validation de la
recette par un Editor ou Admin. **Le client ne parle à aucun moteur d'IA** : il dépose un fichier
et écoute un document.

```mermaid
sequenceDiagram
    actor User as Editor / Admin
    participant App as Flutter App
    participant Storage as Firebase Storage
    participant Scan as scanAndPromoteUploadFn
    participant Firestore as Cloud Firestore
    participant Worker as recipeProcessor
    participant Router as ai/router
    participant Model as Gemini · Claude

    User->>App: Sélectionne un fichier\n(photo, PDF, DOCX, texte collé)
    App->>App: ScanStatus: idle → picking

    App->>Storage: Upload dans quarantine/{uid}/
    App->>App: ScanStatus: picking → uploading
    Note over App,Storage: Progression affichée (uploadProgress)\nRègle Storage : propriétaire + rôle + 50 Mo + type MIME

    App->>Scan: scanAndPromoteUpload(storagePath)
    Note over Scan: Extension, type MIME, signature binaire\nPuis promotion hors quarantaine
    Scan-->>App: URL du fichier promu

    App->>Firestore: crée processing_jobs (status: queued)
    App->>User: Rend la main — l'écran Traitements suit l'avancement

    Firestore->>Worker: jobDispatcher → Cloud Tasks → recipeProcessor
    Worker->>Router: extraction, tags, illustrations
    Router->>Router: lit app_config/ai_routing_policy\net le plafond du compte
    Router->>Model: prompt structuré (Gemini par défaut, Claude si désigné)
    Model-->>Router: JSON { titre, langue, cooklang, tags }
    Router->>Firestore: recordUsage — appel, moteur, modèle, coût
    Worker->>Firestore: createRecipe(status: draft, rawCooklang…)
    Worker->>Firestore: current_step: done

    Note over Worker,Firestore: Trois échecs → dead_letters/, sans exception relancée\n(sans quoi Cloud Tasks recommencerait indéfiniment)

    Firestore-->>App: le brouillon apparaît (stream temps réel)
    User->>App: Ouvre DraftReviewScreen
    Note over User,App: Split view : éditeur Cooklang (gauche)\n+ rendu interactif (droite)

    User->>App: Corrige le Cooklang\net les métadonnées (titre, tags, livre, page)

    alt Enregistrer en brouillon
        User->>App: Tap "Enregistrer brouillon"
        App->>Firestore: update(status: draft, draftCooklang)
        Firestore-->>App: OK
        App->>User: Retour liste des brouillons
    else Valider la recette
        User->>App: Tap "Valider"
        App->>Firestore: validateDraft(\n  rawCooklang ← texte édité,\n  status: validated,\n  ingredients_index\n)
        Note over Firestore: onRecipeWritten recalcule\nnutrition et produits d'achat
        Firestore-->>App: OK
        App->>User: Retour liste des brouillons\n(recette disparaît des brouillons)
    else Supprimer le brouillon
        User->>App: Tap "Supprimer"
        App->>Firestore: deleteRecipe(recipeId)
        App->>Storage: deleteFiles(imageUrls)
        Firestore-->>App: OK
        App->>User: Retour liste des brouillons
    end
```
