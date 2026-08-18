> **Obsolete — remplace par la specification du dossier documentation/.**
>
> Voir « Specification — Moderation des images » (FunctionalRequirements.md) et
> « Specification technique — Moderation des images » (TechnicalRequirements.md).
> Deux decisions y ont ete revisees : violence avec contexte culinaire fort est
> **approuvee** (et non mise en revue), et la revue est reservee aux administrateurs,
> avec un badge de file d attente sur le menu.

# Prompt d'implementation future - Moderation des images

Contexte:
- Projet: KassDalle.
- Stack actuelle: Flutter (mobile/web/desktop) + Firebase (Auth, Firestore, Storage, Functions).
- Objectif: empecher la publication d'images pornographiques ou violentes non pertinentes, tout en conservant les cas legitimes lies a la cuisine (ex: decoupe de poulet).
- Contrainte de cout et d'exploitation: rester sur Google pour eviter de multiplier les points de facturation.

Objectif du dev:
Implementer un systeme complet de moderation d'images base sur Google Cloud Vision (SafeSearch + Label Detection), avec workflow de quarantaine, decision automatique en 3 etats, et revue manuelle via une nouvelle section admin.

Portee fonctionnelle attendue:
1. Moderation automatique a l'upload
- Toute image uploadee passe d'abord en quarantaine (non publique).
- Une Cloud Function se declenche et analyse l'image.
- Le systeme assigne un statut: approved, rejected, manual_review.

2. Gestion des contenus cuisine vs violence hors sujet
- Les contenus explicitement sexuels sont bloques en priorite.
- Les contenus violents sont evalues avec un contexte culinaire.
- Si contexte cuisine fort (ex: viande crue, planche, couteau de cuisine, ingredients), passer en manual_review plutot qu'en rejet automatique.

3. Administration
- Ajouter une entree de menu admin: Moderation.
- Ajouter une page admin Moderation permettant:
  - de lister les images en attente (manual_review),
  - de previsualiser image + scores + labels,
  - de valider (approve) ou refuser (reject),
  - de filtrer par statut et date,
  - de journaliser les actions moderateur (qui, quand, decision, raison).

Architecture cible:
1. Storage
- Bucket/chemins recommandes:
  - uploads/quarantine/... (non public)
  - uploads/public/... (publie)
  - uploads/rejected/... (optionnel, retention limitee)

2. Firestore (collection suggeree: imageModeration)
- Champs minimaux:
  - imageId: string
  - ownerUid: string
  - originalPath: string
  - moderatedPath: string | null
  - status: 'pending' | 'approved' | 'rejected' | 'manual_review'
  - safeSearch: {
      adult: string,
      spoof: string,
      medical: string,
      violence: string,
      racy: string
    }
  - labels: string[]
  - cookingContextScore: number (0..1)
  - moderationReason: string
  - reviewedBy: string | null
  - reviewedAt: Timestamp | null
  - createdAt: Timestamp
  - updatedAt: Timestamp

3. Functions
- Trigger on object finalize sur uploads/quarantine.
- Appeler Google Cloud Vision:
  - SafeSearch Detection
  - Label Detection
- Evaluer les seuils et produire une decision.
- Appliquer l'action:
  - approved: copier vers uploads/public, MAJ Firestore
  - rejected: supprimer ou deplacer selon politique
  - manual_review: conserver en quarantaine et notifier admin

4. Client admin Flutter
- Nouveau point d'entree dans le menu admin: Moderation.
- Page de moderation avec pagination, tri, filtres.
- Actions bouton: Approuver / Rejeter.
- Confirmation obligatoire avant action finale.

Politique de decision (V1 proposee):
1. Rejet immediat
- Si adult est LIKELY ou VERY_LIKELY -> rejected.
- Si racy est VERY_LIKELY et labels cuisine faibles -> rejected.

2. Revue manuelle
- Si violence est LIKELY ou VERY_LIKELY ET cookingContextScore >= 0.5 -> manual_review.
- Si signaux contradictoires (ex: racy possible + labels cuisine forts) -> manual_review.

3. Approbation auto
- Si adult/racy faibles et violence faible -> approved.
- Si labels cuisine forts et aucun signal explicite sexuel -> approved.

Heuristique cookingContextScore (V1 simple):
- Construire un dictionnaire de labels cuisine (ex: food, meat, chicken, poultry, cutting board, kitchen knife, ingredient, recipe, cooking).
- Score = nombre de labels cuisine detectes / nombre de labels pertinents (borne entre 0 et 1).
- Le dictionnaire doit etre configurable (fichier config ou collection Firestore admin).

Securite et droits:
1. Firestore rules
- Ecriture decision moderation reservee aux admins.
- Lecture des metadonnees de moderation reservee aux admins.

2. Storage rules
- Interdire acces public au dossier quarantine.
- Autoriser lecture publique uniquement des assets approuves.

3. Audit
- Chaque decision manuelle doit etre tracee.

Observabilite:
- Logs structures dans Functions (decision, scores, latence, erreurs API).
- Metrique du taux de faux positifs/faux negatifs (a partir des corrections manuelles).
- Dashboard simple admin: volumes, accepted/rejected/manual_review.

Tests attendus:
1. Unit tests
- Mapping SafeSearch -> decision.
- Calcul cookingContextScore.

2. Integration tests
- Upload image mockee -> statut final attendu.
- Flux manual_review -> approve/reject.

3. Regression
- Cas cuisine legitimes (decoupe poulet) ne doivent pas etre rejetes automatiquement.
- Cas porno explicite doivent etre rejetes automatiquement.

Contraintes non fonctionnelles:
- Minimiser la latence percue a l'upload.
- Eviter la double facturation inutile (un seul provider: Google).
- Rendre la solution configurable sans redeploiement complet (seuils stockables en config).

Livrables attendus:
1. Code Functions pour moderation automatique.
2. Nouvelles structures Firestore + eventuelle migration.
3. Ecran admin Moderation + entree menu admin.
4. Rules Firestore/Storage mises a jour.
5. Documentation technique courte (flux, seuils, cout).
6. Jeux de tests unitaires et integration.

Definition of Done:
- Aucune image n'est publiee sans statut approved.
- La page admin Moderation permet de traiter les pending/manual_review de bout en bout.
- Les cas explicites porno sont bloques.
- Les cas culinaires ambigus sont diriges vers revue manuelle, pas rejetes en masse.
- Tous les couts de moderation passent par Google (aucun provider additionnel).

Notes implementation:
- Commencer en V1 avec regles explicites + revue manuelle.
- Reporter une V2 potentielle avec modele contextuel plus fin si besoin.
