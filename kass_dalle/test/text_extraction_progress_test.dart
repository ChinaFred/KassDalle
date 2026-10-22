import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/core/utils/language_names.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/ai_processing_overlay.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/text_extraction_progress.dart';

const _lecture = TextExtractionStep(TextExtractionStep.lecture);
const _balisage = TextExtractionStep(TextExtractionStep.balisage);
const _traductionEn = TextExtractionStep(
  TextExtractionStep.traduction,
  langue: 'en',
);

const _done = AiProcessingStepState.done;
const _current = AiProcessingStepState.current;
const _upcoming = AiProcessingStepState.upcoming;

void main() {
  group('textExtractionProgressSteps', () {
    test('aucune étape reçue : pas de liste', () {
      expect(textExtractionProgressSteps(const []), isEmpty);
    });

    test('lecture en cours : la traduction n\'est pas annoncée d\'avance', () {
      expect(textExtractionProgressSteps(const [_lecture]), const [
        AiProcessingStep('Lecture du texte', _current),
        AiProcessingStep('Repérage des ingrédients et des étapes', _upcoming),
      ]);
    });

    test('traduction annoncée : elle s\'insère entre les deux', () {
      expect(textExtractionProgressSteps(const [_lecture, _traductionEn]), [
        const AiProcessingStep('Lecture du texte', _done),
        const AiProcessingStep("Traduction depuis l'anglais", _current),
        const AiProcessingStep(
          'Repérage des ingrédients et des étapes',
          _upcoming,
        ),
      ]);
    });

    test('balisage après traduction : les deux premières sont faites', () {
      expect(
        textExtractionProgressSteps(const [_lecture, _traductionEn, _balisage]),
        [
          const AiProcessingStep('Lecture du texte', _done),
          const AiProcessingStep("Traduction depuis l'anglais", _done),
          const AiProcessingStep(
            'Repérage des ingrédients et des étapes',
            _current,
          ),
        ],
      );
    });

    test('balisage sans traduction : deux lignes', () {
      expect(textExtractionProgressSteps(const [_lecture, _balisage]), const [
        AiProcessingStep('Lecture du texte', _done),
        AiProcessingStep('Repérage des ingrédients et des étapes', _current),
      ]);
    });
  });

  group('translationStepLabel', () {
    test('élision et article selon la langue', () {
      expect(translationStepLabel('en'), "Traduction depuis l'anglais");
      expect(translationStepLabel('it'), "Traduction depuis l'italien");
      expect(translationStepLabel('ja'), 'Traduction depuis le japonais');
      expect(translationStepLabel('pt-BR'), 'Traduction depuis le portugais');
    });

    test('code inconnu ou absent : « Traduction »', () {
      expect(translationStepLabel('xx'), 'Traduction');
      expect(translationStepLabel(null), 'Traduction');
    });
  });

  group('TextExtractionStep.fromChunk', () {
    test('lit les trois étapes', () {
      expect(TextExtractionStep.fromChunk({'etape': 'lecture'}), _lecture);
      expect(
        TextExtractionStep.fromChunk({'etape': 'traduction', 'langue': 'en'}),
        _traductionEn,
      );
      expect(TextExtractionStep.fromChunk({'etape': 'balisage'}), _balisage);
    });

    test('ignore un message inconnu ou une erreur', () {
      expect(TextExtractionStep.fromChunk({'etape': 'autre'}), isNull);
      expect(TextExtractionStep.fromChunk('lecture'), isNull);
      expect(
        TextExtractionStep.fromChunk({
          'erreur': {'code': 'internal'},
        }),
        isNull,
      );
    });

    test('la langue ne vaut que pour la traduction', () {
      expect(
        TextExtractionStep.fromChunk({'etape': 'lecture', 'langue': 'en'}),
        _lecture,
      );
    });
  });

  group('parseCallableStreamLine', () {
    test('message, résultat et erreur', () {
      final message = parseCallableStreamLine(
        'data: {"message":{"etape":"lecture"}}',
      );
      expect(message, isA<CallableStreamMessage>());
      expect((message! as CallableStreamMessage).data, {'etape': 'lecture'});

      final result = parseCallableStreamLine(
        'data: {"result":{"cooklang":null}}',
      );
      expect(result, isA<CallableStreamResult>());
      expect((result! as CallableStreamResult).data, {'cooklang': null});

      final failure = parseCallableStreamLine(
        'data: {"error":{"status":"RESOURCE_EXHAUSTED","message":"Plafond",'
        '"details":{"scope":"ai_budget"}}}',
      );
      expect(failure, isA<CallableStreamFailure>());
      final error = (failure! as CallableStreamFailure).error;
      expect(error.code, 'resource_exhausted');
      expect(error.message, 'Plafond');
      expect(error.details, {'scope': 'ai_budget'});
    });

    test('ping, ligne vide et ligne illisible sont ignorés', () {
      expect(parseCallableStreamLine(': ping'), isNull);
      expect(parseCallableStreamLine(''), isNull);
      expect(parseCallableStreamLine('data: [1, 2]'), isNull);
    });
  });

  group('callableStreamError', () {
    test('lit l\'erreur annoncée par le serveur', () {
      final error = callableStreamError({
        'erreur': {
          'code': 'resource-exhausted',
          'message': 'Plafond atteint',
          'details': {'scope': 'ai_budget'},
        },
      });
      expect(error, isNotNull);
      expect(error!.code, 'resource-exhausted');
      expect(error.message, 'Plafond atteint');
      expect(error.details, {'scope': 'ai_budget'});
    });

    test('une étape n\'est pas une erreur', () {
      expect(callableStreamError({'etape': 'lecture'}), isNull);
      expect(callableStreamError(null), isNull);
    });
  });
}
