/**
 * Les prompts de l'extraction d'illustrations.
 *
 * **Copiés du bac à sable, mot pour mot.** `functions/src/sandbox/page.ts`,
 * `orientation.ts` et `regions.ts` portent les mêmes textes, à la virgule près.
 * Ce n'est pas un oubli de factorisation : le bac à sable a le droit de dériver,
 * et il dérivera. Un prompt partagé entre les deux ferait qu'un essai raté du
 * bac à sable changerait le comportement de l'import de production — exactement
 * ce que la règle d'isolement interdit.
 *
 * Chaque phrase de ces textes a coûté un essai raté. Les plus chères :
 *
 * - **« PLUSIEURS LIVRES À LA FOIS : PRENDS CELUI DU DESSUS »** — une photo de
 *   livre montre presque toujours d'autres livres dessous, du même papier. Le
 *   modèle mélangeait un morceau de l'un et un morceau de l'autre.
 * - **« Le pli peut être une limite »** — un pli central n'est un bord que si
 *   rien de lisible ne se trouve derrière. Rien dans son allure ne le dit.
 * - **« UNE ZONE = UNE PHOTOGRAPHIE »** — deux photos qui se touchent bord à
 *   bord restent deux photos ; une grande scène continue reste une seule.
 * - **« AVANT DE COUPER, NOMME LA PREUVE »** — le modèle qui scinde à tort une
 *   photo ne sait pas nommer ce qui sépare les deux moitiés. On lui demande
 *   donc de le nommer, et la coupure tombe d'elle-même.
 * - **aucun exemple rempli** dans les prompts qui n'en portent pas : le modèle
 *   recopiait la réponse d'exemple, valeur de confiance comprise.
 *
 * Une seule question a été reformulée plutôt qu'affinée, et c'est la leçon
 * générale : « de combien de degrés tourner cette page » est du raisonnement
 * spatial, et un modèle y répond mal. « Dans laquelle de ces quatre vignettes
 * sais-tu lire » est de la reconnaissance, et il y répond bien. Le programme
 * garde la géométrie, le modèle garde le sens.
 */

/**
 * Y a-t-il quelque chose à extraire ? — la question posée avant tout le reste.
 *
 * Une page de texte pur est le cas le plus fréquent, et la chaîne complète y
 * coûte quatre appels pour rendre zéro illustration. Cette question-ci en coûte
 * un seul, sur la photo brute, et arrête tout quand la réponse est non.
 *
 * Elle se pose donc sur une page qui n'a été ni mise à plat ni remise à
 * l'endroit : c'est voulu. Reconnaître qu'une page porte une photographie ne
 * demande ni perspective corrigée ni sens de lecture — un humain le voit d'un
 * coup d'œil sur une photo de travers.
 */
export const PRECHECK_PROMPT = String.raw`
TÂCHE : dire si cette page porte des IMAGES, et combien.

CE QUE TU REGARDES est la photographie d'une page : une page de livre de
cuisine, une page de magazine, une feuille imprimée ou des notes manuscrites.
Elle est photographiée de biais, elle peut être de travers, et il peut y avoir
du décor autour. Rien de tout cela n'a d'importance ici.

LA SEULE QUESTION : y a-t-il, IMPRIMÉ OU DESSINÉ SUR CETTE PAGE, au moins une
photographie, un dessin, un croquis, une illustration ou un schéma ?

CE QUI COMPTE :
- une photographie imprimée sur la page — un plat, un ingrédient, une scène ;
- un dessin, un croquis, une aquarelle, une illustration au trait ;
- un schéma, un plan, un diagramme dessiné.

CE QUI NE COMPTE PAS, et c'est là qu'on se trompe :
- le texte imprimé, quel qu'il soit : titres, paragraphes, listes d'ingrédients,
  numéros de page, en-têtes ;
- l'écriture manuscrite ;
- les filets, cadres décoratifs, puces, logos, culs-de-lampe ;
- **ce qui est AUTOUR de la page** : la table, la nappe, le canapé, une main,
  le décor de la photo. Tu ne juges QUE ce qui est imprimé sur le papier.
- **la page elle-même** : que la photo de la page soit belle ne fait pas de la
  page une image.

Si tu hésites, réponds oui. Le coût des deux erreurs n'est pas le même : dire
oui à tort fait travailler la suite pour rien, dire non à tort fait perdre les
images de cette page, et personne ne le saura jamais.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, avec ces
quatre champs et dans cet ordre.

- "observed" : ce que porte cette page, en une phrase, avec tes propres mots.
- "count"    : le nombre d'images distinctes que tu distingues, un entier.
- "has_images" : true ou false.
- "confidence" : un nombre entre 0 et 1.

Aucun exemple rempli ne t'est donné, et c'est délibéré : il n'y a rien à
recopier, réponds sur CETTE page.
`;

/** Où est la page dans la photo — passe 1 du cadrage. */
export const BOX_PROMPT = String.raw`
TÂCHE : encadrer la PAGE photographiée, d'un rectangle droit.

CE QUE TU REGARDES est une photographie prise à main levée. Quelqu'un a posé un
livre, un magazine ou une feuille quelque part, et l'a photographié.

CE QU'IL FAUT ENCADRER — le papier porteur du contenu, ENTIER :
- une page simple d'un livre ou d'un magazine → "page" ;
- les DEUX pages d'un livre ouvert, prises ensemble → "double_page" ;
- une feuille volante, imprimée ou manuscrite → "feuille".

Le rectangle contient la page TOUT ENTIÈRE : ses quatre bords, ses marges
blanches, et tout ce qui est imprimé dessus — les photos comme le texte. Si la
page est de travers, le rectangle droit qui la contient déborde forcément un peu
sur les côtés : c'est normal et c'est voulu. Mieux vaut un peu trop large que
trop court.

CE QU'IL NE FAUT PAS ENCADRER — et c'est là que tout se joue :
- **ce qui est SOUS le livre** : une serviette, un torchon, une nappe, un
  sous-main, un plateau. Ces choses sont souvent claires, rectangulaires et plus
  grandes que le livre. Elles ressemblent à du papier. Elles n'en sont pas :
  rien n'est imprimé dessus, et le livre est POSÉ DESSUS.
- **ce qui est AUTOUR** : la table, le canapé, le bureau, le sol, une main, un
  clavier, l'ombre du photographe.
- **une PARTIE de la page** : ni la seule photo du plat, ni le seul bloc de
  texte. La page est un tout, et le rectangle va d'un bord du papier à l'autre.

PLUSIEURS LIVRES À LA FOIS : PRENDS CELUI DU DESSUS.

C'est le cas le plus fréquent, et le plus mal traité. Un livre ouvert est
rarement seul : il est posé sur d'autres livres ou d'autres magazines, ouverts
ou fermés, et souvent du même genre. Plusieurs pages sont donc visibles en même
temps, de même papier et de même contenu.

**Une seule est photographiée : celle du DESSUS.** C'est celle-là, et rien
d'autre, que tu dois encadrer.

Comment la reconnaître, à coup sûr :
- ses quatre bords sont ENTIERS. Rien ne passe par-dessus, rien ne l'interrompt.
- c'est elle qui CACHE les autres. Une page du dessous s'arrête net là où celle
  du dessus commence, et reparaît de l'autre côté.
- elle est la plus nette et la mieux éclairée : elle est la plus proche de
  l'objectif.

Et ce qu'il ne faut surtout pas faire : mélanger. Ne prends jamais un morceau
de la page du dessus et un morceau de celle du dessous dans le même rectangle,
même si les deux se ressemblent et se prolongent l'une l'autre. Le bord d'une
page qui en recouvre une autre est une VRAIE limite, pas une continuation.

Dis dans "observed" combien de livres ou de pages tu distingues, et lequel tu
as retenu.

LE PLI DE RELIURE : REGARDE CE QU'IL Y A DERRIÈRE.

Un pli central est une ligne sombre, souvent bordée d'une ombre. Il peut être
une limite de ton cadre, ou pas du tout — et rien dans son allure ne le dit.
**C'est ce qui se trouve de l'autre côté qui tranche**, et cela seulement :

- de l'autre côté, une SECONDE PAGE avec du contenu, entièrement ou largement
  visible ? Alors les deux pages sont photographiées ensemble : ton rectangle
  les contient toutes les deux, le pli passe en son milieu, et c'est une
  "double_page".
- de l'autre côté, la table, le linge, le vide, une page qui plonge hors du
  cadre, ou une page coupée dont on ne voit qu'une lisière ? Alors le pli EST
  le bord de ce qui est photographié : ton rectangle s'y arrête, et c'est une
  "page".

Ne cadre jamais une page à moitié : si les deux sont là, prends-les. Ne cadre
jamais du vide : si la seconde n'y est pas, arrête-toi au pli.

MÉTHODE, dans cet ordre :
1. Décris ce que tu vois : quel objet porte le contenu, ce qu'il y a dessous,
   ce qu'il y a autour, et s'il y a un pli de reliure — en disant ce qu'il y a
   de chaque côté. Écris-le dans "observed".
2. Repère le bord HAUT du papier, puis le bord BAS, puis le GAUCHE, puis le
   DROIT. Chacun est une transition entre le papier porteur de contenu et autre
   chose.
3. Le rectangle est celui qui contient ces quatre bords.

COORDONNÉES :
  • le HAUT de l'image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • la boîte s'écrit [y_min, x_min, y_max, x_max] — la VERTICALE D'ABORD.

Des entiers de 0 à 1000. Ni pixels, ni pourcentages, ni valeurs entre 0 et 1.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, et "observed"
en premier.
{"observed":"double page d'un magazine de cuisine posée sur un torchon blanc, le tout sur un canapé gris","box":[110,180,880,760],"kind":"double_page","confidence":0.9}

Si aucune page n'est visible :
{"observed":"…","box":null,"kind":"autre","confidence":0}
`;

/** Les quatre sommets du papier, sur le gros plan — passe 2 du cadrage. */
export const CORNERS_PROMPT = String.raw`
TÂCHE : donner les quatre coins du papier dans ce gros plan.

CE QUE TU REGARDES est un recadrage autour d'une page déjà repérée. La page en
occupe la plus grande part, et une marge de décor l'entoure — le support sur
lequel elle est posée, et ce qu'il y a plus loin. Cette marge est volontaire :
elle garantit que la page tient entièrement dans le cadre, même si le repérage
précédent était un peu court.

Ton travail n'est plus de trouver la page : elle est là, devant toi. Il est de
placer ses QUATRE SOMMETS, au pixel près.

La page est photographiée de biais : c'est un QUADRILATÈRE, pas un rectangle.
Ses côtés opposés n'ont ni la même longueur ni la même inclinaison. Ne rends
JAMAIS un rectangle droit — s'il l'était, tes quatre coins auraient deux à deux
la même verticale et la même horizontale, et ce n'est presque jamais le cas.

Suis le bord du papier, coin par coin :
- coin haut-gauche : là où le bord haut rencontre le bord gauche ;
- coin haut-droit, puis bas-droit, puis bas-gauche.

Le coin est sur le PAPIER, pas dans la marge de décor autour. S'il y a une
ombre portée le long d'un bord, le coin est du côté du papier, pas de l'ombre.

EN CAS DE DOUTE, ÉLARGIS. Les deux erreurs ne se valent pas : un ou deux pour
cent de décor gardés autour de la page se retirent après coup, tandis qu'un bord
de photo rogné est perdu pour de bon. Vise le bord du papier ; si tu hésites de
quelques pixels, place le coin du côté extérieur.

COORDONNÉES, dans le repère de CE gros plan :
  • le HAUT de cette image vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • chaque coin s'écrit [y, x] — la VERTICALE D'ABORD.

Ordre : haut-gauche, haut-droit, bas-droit, bas-gauche — le sens des aiguilles
d'une montre en partant du coin supérieur gauche DU PAPIER, et non de l'image.

AVANT TOUT, UNE VÉRIFICATION. Ce gros plan est censé contenir la page entière.
Regarde ses quatre bords : la page est-elle **coupée** par l'un d'eux, c'est-à-
dire se poursuit-elle au-delà du cadre ? Si oui, dis-le et n'invente pas de
coins : un quadrilatère bien placé sur une page amputée est pire qu'un aveu.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, avec ces
quatre champs et dans cet ordre.

- "observed" : ce que tu vois, et notamment si la page touche un bord du gros
  plan. En une phrase, avec tes propres mots.
- "cut"      : true si la page est coupée par un bord du gros plan, false si
  elle tient entièrement dedans.
- "quad"     : les quatre coins, sous la forme [[y,x],[y,x],[y,x],[y,x]], dans
  l'ordre haut-gauche, haut-droit, bas-droit, bas-gauche. Mets null quand "cut"
  vaut true.
- "confidence" : un nombre entre 0 et 1.

Aucun exemple rempli ne t'est donné, et c'est délibéré : il n'y a rien à
recopier, réponds sur CE gros plan.
`;

/** Laquelle des quatre vignettes se lit — le sens de la page. */
export const ORIENTATION_PROMPT = String.raw`
TÂCHE : dire laquelle de ces quatre pages est à l'endroit.

CE QUE TU REGARDES est une planche de quatre cases, marquées A en haut à
gauche, B en haut à droite, C en bas à gauche et D en bas à droite. Chaque
lettre est écrite dans le bandeau blanc au-dessus de sa case.

Les quatre cases montrent **la même page**, tournée différemment. Une seule est
à l'endroit. Dis laquelle.

TROIS INDICES, dans cet ordre de fiabilité. Prends le premier qui répond.

**1. LE TEXTE** — l'indice le plus sûr. "basis" vaut "texte".
Dans une seule des quatre cases, le texte se lit normalement : les lignes
courent horizontalement, de gauche à droite, et les lettres sont à l'endroit.
Dans les trois autres il est couché ou retourné. Lis un titre, un paragraphe,
une légende, un numéro de page — n'importe quoi de lisible suffit à trancher.

**2. LA GRAVITÉ** — quand la page ne porte que des images. "basis" vaut "image".
Une photographie montre un monde qui obéit à la pesanteur. Dans la bonne case :
- ce qui REPOSE sur quoi est cohérent. Une assiette repose sur une table, un
  verre sur une nappe ; le support est EN DESSOUS de ce qu'il porte.
- les ombres portées tombent vers le bas, et l'objet touche son ombre par le bas.
- le liquide occupe le FOND d'un verre ou d'une assiette creuse, jamais le haut.
- une table photographiée en biais s'éloigne vers le HAUT de la case ; son bord
  proche est en bas.
- les mains, les bras, les couverts tenus entrent par le bas ou les côtés.
- une pile se construit du bas vers le haut, et sa base est plus large.

**3. LA MISE EN PAGE** — le dernier recours. "basis" vaut "mise_en_page".
Un numéro de page est en bas. Une légende est sous sa photo. Un titre est
au-dessus de son texte. Ces indices ne séparent pas toujours une page de son
retournement : baisse ta confiance en conséquence.

ATTENTION : deux des quatre cases sont l'exacte symétrie l'une de l'autre —
même structure, mêmes blocs, mêmes marges. Elles ne se distinguent qu'aux
LETTRES, ou à défaut à ce qui repose sur quoi. Ne te fie pas à la forme de la
page : une page plus large que haute peut très bien être à l'endroit.

Si vraiment rien ne tranche, réponds "A" avec une confiance basse et "basis" à
"aucun". La case A est la page telle qu'elle est arrivée : ne rien changer est
moins gênant que de la retourner pour rien.

RÉPONSE : UNIQUEMENT un objet JSON, sans markdown ni explication, avec ces cinq
champs et dans cet ordre.

- "reading" : les TROIS PREMIERS MOTS que tu lis vraiment dans la case retenue,
  recopiés exactement, avec leur casse et leurs accents. Si tu ne parviens à
  lire aucun mot, mets une chaîne vide. Ne devine pas, n'invente pas de titre
  plausible : une chaîne vide est une réponse acceptable, un mot inventé ne
  l'est pas.
- "observed" : ce qui t'a fait choisir cette case, en une phrase, avec tes
  propres mots.
- "basis" : "texte", "image", "mise_en_page" ou "aucun".
- "choice" : "A", "B", "C" ou "D".
- "confidence" : un nombre entre 0 et 1.

Aucun exemple de réponse rempli ne t'est donné, et c'est délibéré. Il n'y a rien
à recopier ici : réponds sur ce que tu vois dans CETTE planche.
`;

/** Les zones imagées de la page mise à plat et remise à l'endroit. */
export const REGIONS_PROMPT = String.raw`
TÂCHE : trouver TOUTES les zones IMAGÉES de cette page, et dire ce que chacune contient.

CE QUE TU REGARDES est une page à plat : une page de livre, une feuille
imprimée, ou des notes manuscrites. Elle a déjà été redressée.

CE QUE TU CHERCHES — quatre natures, et une zone appartient à une seule :
- "photo"          : une photographie imprimée ou collée.
- "dessin"         : un dessin, un croquis, une illustration au trait, une
                     aquarelle. Fait à la main ou imprimé, peu importe.
- "schema"         : un schéma, un plan, un diagramme, un tableau dessiné —
                     de la géométrie porteuse d'information, pas une image.
- "texte_manuscrit": un bloc d'écriture à la main. Une annotation dans la marge
                     en est un.
- "autre"          : imagé, mais aucune des quatre natures ci-dessus.

CE QUE TU NE CHERCHES PAS :
- le texte imprimé courant : titres, paragraphes, listes d'ingrédients,
  numéros de page, en-têtes. Ne les liste JAMAIS.
- les filets, cadres décoratifs, puces, logos et culs-de-lampe.
- la page elle-même : une zone qui couvre presque toute l'image est presque
  toujours fausse.

COMPTER D'ABORD, CADRER ENSUITE :
1. Balaye la page et COMPTE les zones imagées distinctes.
2. Une grille de vignettes vaut une zone PAR case. Une grille 3×3 vaut 9 zones.
3. Une grande image ne se découpe pas : elle vaut UNE zone.
4. Pour chaque zone, encadre-la d'un rectangle DROIT.

UNE ZONE = UNE PHOTOGRAPHIE. C'est la définition, et elle tranche tout.

Une photographie est une prise de vue : une scène, un moment, un cadrage. Deux
photographies distinctes valent DEUX zones — **même si elles se touchent bord à
bord**, sans marge blanche entre elles. Le montage à fond perdu est courant en
édition culinaire : deux plats empilés l'un au-dessus de l'autre, sans le
moindre filet pour les séparer. Ça reste deux photos.

Le test est donc celui de la SCÈNE, jamais celui de l'espace blanc :

- la scène CONTINUE d'un bord à l'autre de la ligne que tu envisages ? Le même
  verre, la même nappe, la même table qui se prolonge, des assiettes qui se
  chevauchent, la même lumière et la même perspective ? Alors c'est **UNE
  SEULE** photographie, et ta ligne la découperait à tort.
- la scène CHANGE ? Un décor différent, un angle différent, un éclairage
  différent, ou une COUTURE NETTE où deux images se rencontrent sans que rien ne
  se poursuive ? Alors ce sont **DEUX** photographies.

**AVANT DE COUPER, NOMME LA PREUVE.** Pour tracer une ligne à l'intérieur d'un
bloc imagé continu, tu dois pouvoir désigner ce qui atteste la coupure : un
objet tranché qui ne se poursuit pas de l'autre côté, un bord de table qui ne
s'aligne pas, un fond qui change brutalement. Si tu ne peux pas le nommer, il
n'y a pas de coupure — c'est une seule photo.

DEUX PIÈGES, et ce sont les deux qu'on rencontre :

- **plusieurs plats ne font pas plusieurs photos.** Une photographie de cuisine
  montre couramment deux ou trois préparations dans la même scène, l'une au
  premier plan, l'autre derrière ou plus haut sur la table.
- **une légende qui nomme deux plats ne prouve rien.** « X (en haut) et Y »
  décrit le plus souvent UNE SEULE image où les deux figurent, X étant
  simplement placé plus haut dans le cadre. Ne compte jamais les zones d'après
  la légende.

CADRAGE : serre au bord de la zone. Pas de marge de papier autour, pas de
légende, pas la zone voisine. Les zones ne doivent pas se chevaucher.

Le rectangle est DROIT, et c'est normal : cette page a déjà été mise à plat et
remise à l'endroit. Une photo imprimée dessus est donc alignée sur ses bords.
Rien ici n'est de travers, tu n'as pas de perspective à décrire.

COORDONNÉES — la partie qu'on rate.

Repère NORMALISÉ, indépendant de la taille de l'image :
  • le HAUT de la page vaut 0, le BAS vaut 1000 ;
  • la GAUCHE vaut 0, la DROITE vaut 1000 ;
  • la boîte s'écrit [y_min, x_min, y_max, x_max] — la VERTICALE D'ABORD.

Ni pixels, ni pourcentages, ni valeurs entre 0 et 1 : des entiers de 0 à 1000.
Et forcément y_min < y_max, x_min < x_max.

RÉPONSE : UNIQUEMENT un tableau JSON, sans markdown ni explication. Un objet par
zone, avec ces cinq champs :

- "box"        : [y_min, x_min, y_max, x_max], entiers de 0 à 1000.
- "kind"       : "photo", "dessin", "schema", "texte_manuscrit" ou "autre".
- "label"      : ce que la zone montre, en trois ou quatre mots.
- "bounded_by" : ce qui délimite cette zone du reste de la page, en quelques
                 mots — « marge blanche sur les quatre côtés », « bord de la
                 page en haut et à droite, marge en bas ». Si la zone touche une
                 AUTRE zone imagée, dis ce qui prouve la séparation : l'objet
                 tranché, le fond qui change, la couture. Ce champ existe pour
                 rendre une coupure vérifiable ; une coupure qu'on ne sait pas
                 justifier ne doit pas être faite.
- "confidence" : un nombre entre 0 et 1.

Rends [] si la page ne porte aucune zone imagée. Aucun exemple rempli ne t'est
donné : il n'y a rien à recopier, réponds sur CETTE page.
`;
