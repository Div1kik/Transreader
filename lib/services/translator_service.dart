import 'dart:async';
import 'dart:convert';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:http/http.dart' as http;
import 'offline_translator_service.dart';
import 'settings_service.dart';

class ModelRateLimitException implements Exception {
  final String model;
  final int retryAfterSeconds;
  final String rawMessage;

  ModelRateLimitException({
    required this.model,
    required this.retryAfterSeconds,
    required this.rawMessage,
  });

  @override
  String toString() =>
      'Лимит модели $model (пауза ${retryAfterSeconds}с): $rawMessage';
}

class TranslatedParagraphOutput {
  final String translation;
  final Map<String, String> wordAlignMap;

  const TranslatedParagraphOutput({
    required this.translation,
    this.wordAlignMap = const {},
  });
}

class TranslatorService {
  TranslatorSettings settings;
  final Map<String, DateTime> _routeRateLimitedUntil = {};
  final Map<String, DateTime> _routeErrorCooldownUntil = {};

  TranslatorService({required this.settings});

  String _routeKey(ApiProviderProfile provider, String model) =>
      '${provider.id}::$model';

  bool isRouteCoolingDown(ApiProviderProfile provider, String model) {
    final key = _routeKey(provider, model);
    final now = DateTime.now();

    final rateUntil = _routeRateLimitedUntil[key];
    if (rateUntil != null) {
      if (now.isAfter(rateUntil)) {
        _routeRateLimitedUntil.remove(key);
      } else {
        return true;
      }
    }

    final errUntil = _routeErrorCooldownUntil[key];
    if (errUntil != null) {
      if (now.isAfter(errUntil)) {
        _routeErrorCooldownUntil.remove(key);
      } else {
        return true;
      }
    }

    return false;
  }

  int getShortestRateLimitSeconds() {
    if (_routeRateLimitedUntil.isEmpty) return 0;
    final now = DateTime.now();
    int minSec = 999999;
    for (final until in _routeRateLimitedUntil.values) {
      final diff = until.difference(now).inSeconds;
      if (diff > 0 && diff < minSec) {
        minSec = diff;
      }
    }
    return minSec == 999999 ? 0 : minSec;
  }

  bool _isCyrillic(String text) {
    return RegExp(r'[а-яА-ЯёЁ]').hasMatch(text);
  }

  Map<String, String> _buildProviderHeaders(ApiProviderProfile provider) {
    final isOpenRouter = provider.endpointUrl.contains('openrouter.ai');
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ${provider.apiKey}',
      if (isOpenRouter) ...{
        'HTTP-Referer': 'https://github.com/Div1kik/Transreader',
        'X-Title': 'TransReader',
      },
    };
  }

  Future<String> translateSelection({
    required String selectedText,
    required String targetLanguage,
  }) async {
    final clean = selectedText.trim();
    if (clean.isEmpty) return '';

    final sourceLang = _isCyrillic(clean)
        ? TranslateLanguage.russian
        : TranslateLanguage.english;
    final effectiveTarget = _isCyrillic(clean) ? 'English' : targetLanguage;

    if (settings.engineMode == TranslationEngineMode.offlineLocal ||
        !settings.hasAnyOnlineKey) {
      return OfflineTranslatorService.instance.translateText(
        clean,
        source: sourceLang,
        targetLanguage: effectiveTarget,
      );
    }

    try {
      final translated = await translateBatchWithAlignments(
        paragraphs: [clean],
        previousContext: const [],
        targetLanguage: effectiveTarget,
      );
      return translated.isNotEmpty ? translated.first.translation : '';
    } catch (_) {
      return OfflineTranslatorService.instance.translateText(
        clean,
        source: sourceLang,
        targetLanguage: effectiveTarget,
      );
    }
  }

  Future<String> findCounterpartWordInContext({
    required String tappedWord,
    required String sourceParagraph,
    required String targetParagraph,
    required double relativePosition,
  }) async {
    final cleanWord = tappedWord.trim();
    if (cleanWord.isEmpty) return '';

    final isRussianTap = _isCyrillic(cleanWord);
    final targetLang = isRussianTap ? 'English' : settings.targetLanguage;

    final mlKitReady = await OfflineTranslatorService.instance.isPairDownloaded(
      targetLanguage: settings.targetLanguage,
    );

    if (mlKitReady) {
      try {
        final translated = await OfflineTranslatorService.instance
            .translateText(
              cleanWord,
              source: isRussianTap
                  ? TranslateLanguage.russian
                  : TranslateLanguage.english,
              targetLanguage: targetLang,
            )
            .timeout(const Duration(milliseconds: 350));
        if (translated.trim().isNotEmpty) {
          return translated.trim();
        }
      } catch (_) {}
    }

    return '';
  }

  Future<List<TranslatedParagraphOutput>> _translateWithOfflineMlKit(
    List<String> paragraphs,
    String targetLanguage,
    void Function(String activeModel)? onModelSelected,
  ) async {
    onModelSelected?.call('Offline ML Kit');
    final results = <TranslatedParagraphOutput>[];
    for (final p in paragraphs) {
      final tr = await OfflineTranslatorService.instance.translateText(
        p,
        targetLanguage: targetLanguage,
      );
      results.add(TranslatedParagraphOutput(translation: tr));
    }
    return results;
  }

  Future<List<TranslatedParagraphOutput>> translateBatchWithAlignments({
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
    void Function(String activeModel)? onModelSelected,
  }) async {
    if (paragraphs.isEmpty) return [];

    if (settings.engineMode == TranslationEngineMode.offlineLocal) {
      return _translateWithOfflineMlKit(
        paragraphs,
        targetLanguage,
        onModelSelected,
      );
    }

    final providers = settings.effectiveProviders;
    if (providers.isEmpty) {
      if (settings.fallbackToOfflineOnError) {
        return _translateWithOfflineMlKit(
          paragraphs,
          targetLanguage,
          onModelSelected,
        );
      }
      throw Exception(
        'Не подключён ни один ИИ-провайдер: добавьте ключ в настройках или переключитесь на Офлайн-словарь',
      );
    }

    final routes = <({ApiProviderProfile provider, String model})>[];
    for (final p in providers) {
      for (final m in p.models) {
        routes.add((provider: p, model: m));
      }
    }

    final availableRoutes = routes
        .where((r) => !isRouteCoolingDown(r.provider, r.model))
        .toList();

    if (availableRoutes.isEmpty) {
      if (settings.fallbackToOfflineOnError) {
        return _translateWithOfflineMlKit(
          paragraphs,
          targetLanguage,
          onModelSelected,
        );
      }
      final waitSec = getShortestRateLimitSeconds();
      if (waitSec > 0) {
        throw ModelRateLimitException(
          model: '${routes.first.provider.name}: ${routes.first.model}',
          retryAfterSeconds: waitSec.clamp(3, 90),
          rawMessage: 'Все подключённые модели временно в лимите',
        );
      }
      throw Exception(
        'Все провайдеры отклонили запрос (проверьте модели и ключи в настройках)',
      );
    }

    final errorSummary = <String>[];

    for (final route in availableRoutes) {
      final badge = '${route.provider.name} • ${route.model}';
      onModelSelected?.call(badge);

      try {
        return await _callRouteWithRetry(
          provider: route.provider,
          model: route.model,
          paragraphs: paragraphs,
          previousContext: previousContext,
          targetLanguage: targetLanguage,
        );
      } on ModelRateLimitException catch (rateErr) {
        _routeRateLimitedUntil[_routeKey(route.provider, route.model)] =
            DateTime.now().add(Duration(seconds: rateErr.retryAfterSeconds));
        errorSummary.add('${route.provider.name}: 429 лимит');
        continue;
      } catch (e) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        _routeErrorCooldownUntil[_routeKey(route.provider, route.model)] =
            DateTime.now().add(const Duration(seconds: 20));
        if (errorSummary.length < 3) {
          errorSummary.add(msg);
        }
        continue;
      }
    }

    if (settings.fallbackToOfflineOnError) {
      try {
        return await _translateWithOfflineMlKit(
          paragraphs,
          targetLanguage,
          onModelSelected,
        );
      } catch (_) {}
    }

    final waitSec = getShortestRateLimitSeconds();
    if (waitSec > 0) {
      throw ModelRateLimitException(
        model: availableRoutes.first.model,
        retryAfterSeconds: waitSec.clamp(3, 90),
        rawMessage: errorSummary.join(' | '),
      );
    }

    throw Exception(
      errorSummary.isNotEmpty
          ? errorSummary.join(' | ')
          : 'Ни одна из подключённых моделей не ответила',
    );
  }

  Future<List<TranslatedParagraphOutput>> _callRouteWithRetry({
    required ApiProviderProfile provider,
    required String model,
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
  }) async {
    const maxAttempts = 2;
    Exception? attemptError;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _sendRequest(
          provider: provider,
          model: model,
          paragraphs: paragraphs,
          previousContext: previousContext,
          targetLanguage: targetLanguage,
        );
      } on ModelRateLimitException {
        rethrow;
      } catch (e) {
        final text = e.toString();
        if (text.contains('(400)') ||
            text.contains('(401)') ||
            text.contains('(403)') ||
            text.contains('(404)')) {
          rethrow;
        }
        attemptError = e is Exception ? e : Exception(text);
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 700 * attempt));
        }
      }
    }
    throw attemptError ??
        Exception('Ошибка запроса к ${provider.name} ($model)');
  }

  String _cleanTokenKey(String raw) {
    return raw
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r"[^\p{L}\p{N}'’-]", unicode: true), '')
        .trim();
  }

  Future<List<TranslatedParagraphOutput>> _sendRequest({
    required ApiProviderProfile provider,
    required String model,
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
  }) async {
    final uri = Uri.parse(provider.endpointUrl);

    final contextBlock = previousContext.isEmpty
        ? 'Начало документа / главы.'
        : previousContext.join('\n');

    final numberedInput = <String, String>{};
    for (int i = 0; i < paragraphs.length; i++) {
      numberedInput['$i'] = paragraphs[i];
    }

    final isTechnical = settings.styleMode == TranslationStyleMode.technical;

    final systemPrompt = isTechnical
        ? '''
Ты профессиональный технический переводчик документации, стандартов, спецификаций и деловых отчётов на $targetLanguage язык.
Твоя задача — выполнить точный, терминологически выверенный и строгий технический перевод И построить для каждого абзаца карту соответствий значащих слов ("align").

Строгие правила:
1. Соблюдай отраслевую терминологию, стандарты и точные формулировки без художественных вольностей.
2. Числа, единицы измерения, коды стандартов, артикулы, формулы и аббревиатуры (ASTM, ISO, GOST, MPa, kN, mm и др.) сохраняй без искажений.
3. Переводи каждый абзац из входного JSON-объекта ("0", "1", ...), не пропуская пункты и не объединяя абзацы.
4. Для каждого абзаца сформируй объект "align": словарь вида {"слово_из_перевода": "word_from_source"}, связывающий все значащие термины и слова ровно в той словоформе, как они написаны в тексте (без артиклей the, a, an и предлогов).
5. Ответь СТРОГО валидным JSON-объектом без markdown-обёрток:
{"items": [{"translation": "перевод абзаца 0", "align": {"испытание": "test", "нагрузка": "load"}}, ...]}
'''
        : '''
Ты опытный литературный переводчик художественной прозы и эпического фэнтези на $targetLanguage язык.
Твоя задача — сделать живой, естественный, грамотный художественный перевод И построить для каждого абзаца карту соответствий значащих слов ("align"), чтобы читатель мог нажать на любое слово в русском или английском тексте и увидеть его точный эквивалент.

Строгие правила качества:
1. Никакого подстрочника и дословной кальки: перестраивай фразы так, чтобы они звучали естественно по-русски, сохраняя смысл, атмосферу и ритм автора.
2. Имена собственные, топонимы и названия кланов аккуратно транслитерируй в едином стиле и склоняй по правилам русского языка (например: Uthas -> Утас, Veradis -> Верадис, Corban -> Корбан, Benothi -> Беноти, Forn Forest -> лес Форн). Не переводи имена нарицательными словами!
3. Следи за согласованием родов, падежей и местоимений, опираясь на контекст предыдущих абзацев. Прямую речь оформляй в русских кавычках «...» или через тире.
4. Для каждого абзаца сформируй объект "align": словарь вида {"слово_из_перевода": "word_from_source"}, связывающий все значащие слова (существительные, глаголы, прилагательные, наречия, имена) ровно в той словоформе, как они написаны в тексте! Не включай в "align" артикли (the, a, an) и предлоги.
5. Ответь СТРОГО валидным JSON-объектом без markdown-обёрток:
{"items": [{"translation": "перевод абзаца 0", "align": {"котел": "cauldron", "массивную": "hulking"}}, ...]}
''';

    final userPrompt = '''
ПРЕДЫДУЩИЙ КОНТЕСТ (оригинал для понимания терминов, родов и имён — не включать в ответ):
$contextBlock

АБЗАЦЫ ДЛЯ ПЕРЕВОДА И ВЫРАВНИВАНИЯ СЛОВ (ровно ${paragraphs.length} шт.):
${jsonEncode(numberedInput)}
''';

    final body = jsonEncode({
      'model': model,
      'temperature': isTechnical ? 0.1 : 0.25,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
    });

    final response = await http
        .post(
          uri,
          headers: _buildProviderHeaders(provider),
          body: body,
        )
        .timeout(const Duration(seconds: 65));

    if (response.statusCode == 429) {
      final retryHeader = response.headers['retry-after'];
      int waitSec = int.tryParse(retryHeader ?? '') ?? 15;
      if (waitSec < 3) waitSec = 10;
      if (waitSec > 90) waitSec = 60;
      throw ModelRateLimitException(
        model: model,
        retryAfterSeconds: waitSec,
        rawMessage: 'HTTP 429 Too Many Requests',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bodyLower = response.body.toLowerCase();
      if (bodyLower.contains('rate_limit') ||
          bodyLower.contains('rate limit') ||
          bodyLower.contains('quota')) {
        throw ModelRateLimitException(
          model: model,
          retryAfterSeconds: 20,
          rawMessage: 'API ${response.statusCode}',
        );
      }
      final shortBody = response.body.length > 140
          ? '${response.body.substring(0, 140)}...'
          : response.body;
      throw Exception(
        '${provider.name} (${response.statusCode}): $shortBody',
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final content =
        decoded['choices']?[0]?['message']?['content']?.toString() ?? '';

    if (content.isEmpty) {
      throw Exception('Пустой ответ от модели $model');
    }

    final cleanJson = _extractJsonObject(content);
    final parsedContent = jsonDecode(cleanJson);

    final itemsRaw = parsedContent['items'];
    final translationsFallback = parsedContent['translations'];

    if (itemsRaw is List && itemsRaw.length == paragraphs.length) {
      final result = <TranslatedParagraphOutput>[];
      for (int i = 0; i < itemsRaw.length; i++) {
        final item = itemsRaw[i];
        if (item is! Map) {
          throw Exception('Некорректный элемент #$i в ответе модели $model');
        }
        final tr = (item['translation'] ?? '').toString().trim();
        final src = paragraphs[i].trim();
        if (tr.isEmpty) {
          throw Exception('Модель $model вернула пустой перевод абзаца #$i');
        }
        if (targetLanguage.toLowerCase().contains('russian') &&
            src.length > 25 &&
            !_isCyrillic(tr)) {
          throw Exception('Модель $model не перевела абзац #$i на русский язык');
        }

        final biMap = <String, String>{};
        final rawAlign = item['align'];
        if (rawAlign is Map) {
          rawAlign.forEach((k, v) {
            final cleanK = _cleanTokenKey(k.toString());
            final cleanV = _cleanTokenKey(v.toString());
            if (cleanK.isNotEmpty && cleanV.isNotEmpty) {
              biMap[cleanK] = cleanV;
              biMap[cleanV] = cleanK;
            }
          });
        }

        result.add(
          TranslatedParagraphOutput(
            translation: tr,
            wordAlignMap: biMap,
          ),
        );
      }
      return result;
    }

    if (translationsFallback is List &&
        translationsFallback.length == paragraphs.length) {
      final result = <TranslatedParagraphOutput>[];
      for (int i = 0; i < translationsFallback.length; i++) {
        final tr = translationsFallback[i].toString().trim();
        final src = paragraphs[i].trim();
        if (tr.isEmpty) {
          throw Exception('Модель $model вернула пустой перевод абзаца #$i');
        }
        if (targetLanguage.toLowerCase().contains('russian') &&
            src.length > 25 &&
            !_isCyrillic(tr)) {
          throw Exception('Модель $model не перевела абзац #$i на русский язык');
        }
        result.add(TranslatedParagraphOutput(translation: tr));
      }
      return result;
    }

    throw Exception(
      'Модель $model вернула неверное число абзацев вместо ${paragraphs.length}',
    );
  }

  String _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start != -1 && end != -1 && end > start) {
      return raw.substring(start, end + 1);
    }
    return raw;
  }
}
