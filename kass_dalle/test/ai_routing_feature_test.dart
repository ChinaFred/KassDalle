import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_routing_repository.dart';

/// Le poste verrouillé, et ce que coûte de l'ignorer.
///
/// Le serveur déclare `providers` et `lockedReason` sur les postes qu'un seul
/// fournisseur peut servir. Le client les jetait au parsing : l'écran affichait
/// « Gemini » sur la modération d'images, servie par Cloud Vision, et un clic
/// sur « Tout Claude » écrivait `anthropic` sur ces deux postes — ce que le
/// serveur refuse, en rejetant la politique entière.
///
/// Aucune de ces deux pannes ne lève d'erreur au parsing : le champ manquant
/// disparaît, et la valeur affichée reste plausible. D'où ces tests.
void main() {
  group('AiProvider', () {
    test('reconnaît Vision plutôt que de le replier sur Gemini', () {
      expect(AiProvider.tryFromWire('vision'), AiProvider.vision);
      expect(AiProvider.vision.label, 'Vision');
      expect(AiProvider.vision.wireName, 'vision');
    });

    test('rend null sur un fournisseur inconnu', () {
      expect(AiProvider.tryFromWire('mistral'), isNull);
      expect(AiProvider.tryFromWire(null), isNull);
    });

    test('le repli sur Gemini reste celui de la politique', () {
      // Une politique sans valeur pour un poste vaut le moteur par défaut :
      // ce repli-là est légitime, il ne doit pas disparaître avec le correctif.
      expect(AiProvider.fromWire(null), AiProvider.gemini);
      expect(AiProvider.fromWire('anthropic'), AiProvider.anthropic);
    });
  });

  group('parseRoutableFeatures', () {
    test('un poste sans providers accepte les deux moteurs', () {
      final features = parseRoutableFeatures([
        {
          'id': 'transcription_page',
          'label': 'Transcription',
          'group': 'Import',
        },
      ]);

      expect(features, hasLength(1));
      final feature = features.single;
      expect(feature.lockedProvider, isNull);
      expect(feature.allows(AiProvider.gemini), isTrue);
      expect(feature.allows(AiProvider.anthropic), isTrue);
    });

    test(
      'un poste verrouillé sur Vision garde son fournisseur et sa raison',
      () {
        final features = parseRoutableFeatures([
          {
            'id': 'image_moderation',
            'label': "Modération d'une image",
            'group': 'Modération',
            'providers': ['vision'],
            'lockedReason': 'Seul Cloud Vision rend un verdict reproductible.',
          },
        ]);

        final feature = features.single;
        expect(feature.lockedProvider, AiProvider.vision);
        expect(feature.allows(AiProvider.gemini), isFalse);
        expect(feature.allows(AiProvider.anthropic), isFalse);
        expect(feature.lockedReason, isNotNull);
      },
    );

    test('une liste de fournisseurs inconnus ne rouvre pas la bascule', () {
      // Le jour où le serveur déclare un moteur que ce client ignore, le poste
      // doit cesser d'être basculable. Retomber sur « les deux moteurs
      // habituels » serait la panne d'aujourd'hui, sous un autre nom.
      final features = parseRoutableFeatures([
        {
          'id': 'poste_futur',
          'label': 'Poste futur',
          'providers': ['moteur-inconnu'],
        },
      ]);

      final feature = features.single;
      expect(feature.allowedProviders, isEmpty);
      expect(feature.allows(AiProvider.gemini), isFalse);
      expect(feature.allows(AiProvider.anthropic), isFalse);
    });

    test('un poste sans identifiant est écarté', () {
      expect(
        parseRoutableFeatures([
          {'label': 'Sans identifiant'},
        ]),
        isEmpty,
      );
      expect(parseRoutableFeatures(null), isEmpty);
    });
  });
}
