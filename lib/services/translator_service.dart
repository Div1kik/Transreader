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
      final translated = await translateBatch(
        paragraphs: [clean],
        previousContext: const [],
        targetLanguage: effectiveTarget,
      );
      return translated.isNotEmpty ? translated.first : '';
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

    if (settings.engineMode != TranslationEngineMode.offlineLocal &&
        settings.hasAnyOnlineKey) {
      final providers = settings.effectiveProviders;
      for (final provider in providers) {
        for (final model in provider.models) {
          if (isRouteCoolingDown(provider, model)) continue;
          try {
            final pct = (relativePosition * 100).round();
            final response = await http
                .post(
                  Uri.parse(provider.endpointUrl),
                  headers: _buildProviderHeaders(provider),
                  body: jsonEncode({
                    'model': model,
                    'temperature': 0.0,
                    'max_tokens': 24,
                    'messages': [
                      {
                        'role': 'system',
                        'content':
                            'You are a bilingual word-alignment engine. Given a tapped word in a source paragraph (at roughly $pct% through the text) and its translated counterpart paragraph, output ONLY the single exact matching word from the target paragraph. No punctuation, no explanations, just that one word.',
                      },
                      {
                        'role': 'user',
                        'content':
                            'Tapped word: "$cleanWord"\nSource paragraph: "$sourceParagraph"\nTarget paragraph: "$targetParagraph"\nExact matching word from Target paragraph:',
                      },
                    ],
                  }),
                )
                .timeout(const Duration(seconds: 7));

            if (response.statusCode >= 200 && response.statusCode < 300) {
              final decoded = jsonDecode(utf8.decode(response.bodyBytes));
              final rawReply =
                  decoded['choices']?[0]?['message']?['content']?.toString() ??
                      '';
              final cleanedReply = rawReply
                  .trim()
                  .replaceAll(RegExp(r'^["«“„]+|["»”„.,!?;:]+$'), '');
              if (cleanedReply.isNotEmpty) {
                return cleanedReply;
              }
            }
          } catch (_) {
            continue;
          }
        }
      }
    }

    try {
      return await OfflineTranslatorService.instance.translateText(
        cleanWord,
        source: isRussianTap
            ? TranslateLanguage.russian
            : TranslateLanguage.english,
        targetLanguage: isRussianTap ? 'English' : settings.targetLanguage,
      );
    } catch (_) {
      return '';
    }
  }

  Future<List<String>> _translateWithOfflineMlKit(
    List<String> paragraphs,
    String targetLanguage,
    void Function(String activeModel)? onModelSelected,
  ) async {
    onModelSelected?.call('Offline ML Kit');
    final results = <String>[];
    for (final p in paragraphs) {
      final tr = await OfflineTranslatorService.instance.translateText(
        p,
        targetLanguage: targetLanguage,
      );
      results.add(tr);
    }
    return results;
  }

  Future<List<String>> translateBatch({
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

  Future<List<String>> _callRouteWithRetry({
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

  Future<List<String>> _sendRequest({
    required ApiProviderProfile provider,
    required String model,
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
  }) async {
    final uri = Uri.parse(provider.endpointUrl);

    final contextBlock = previousContext.isEmpty
        ? 'Начало сцены / главы.'
        : previousContext.join('\n');

    final numberedInput = <String, String>{};
    for (int i = 0; i < paragraphs.length; i++) {
      numberedInput['$i'] = paragraphs[i];
    }

    final systemPrompt = '''
Ты опытный литературный переводчик художественной прозы и эпического фэнтези на $targetLanguage язык.
Твоя задача — сделать живой, естественный, грамотный и точный художественный перевод, который читается как книга, написанная носителем языка.

Строгие правила качества:
1. Никакого подстрочника и дословной кальки английского синтаксиса: перестраивай фразы так, чтобы они звучали естественно по-русски, сохраняя смысл, атмосферу и ритм автора.
2. Имена собственные, топонимы и названия кланов/орденов аккуратно транслитерируй в едином стиле и склоняй по правилам русского языка (например: Uthas -> Утас, Veradis -> Верадис, Corban -> Корбан, Benothi -> Беноти, Forn Forest -> лес Форн). Не переводи имена нарицательными словами!
3. Следи за согласованием родов, падежей и местоимений, опираясь на контекст предыдущих абзацев.
4. Прямую речь оформляй в соответствии с нормами русского языка («...» или тире).
5. Переводи строго каждый абзац из входного JSON-объекта ("0", "1", ...), не пропуская предложения и не объединяя соседние абзацы.
6. Ответь СТРОГО валидным JSON-объектом без markdown-обёрток и комментариев: {"translations": ["перевод 0", "перевод 1", ...]}.
''';

    final userPrompt = '''
ПРЕДЫДУЩИЙ КОНТЕКСТ СЦЕНЫ (оригинал для понимания сюжета, родов и имён — не включать в ответ):
$contextBlock

АБЗАЦЫ ДЛЯ ХУДОЖЕСТВЕННОГО ПЕРЕВОДА (ровно ${paragraphs.length} шт.):
${jsonEncode(numberedInput)}
''';

    final body = jsonEncode({
      'model': model,
      'temperature': 0.25,
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
        .timeout(const Duration(seconds: 60));

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
    final translationsRaw = parsedContent['translations'];

    if (translationsRaw is! List || translationsRaw.length != paragraphs.length) {
      throw Exception(
        'Модель $model вернула ${translationsRaw is List ? translationsRaw.length : 0} абзацев вместо ${paragraphs.length}',
      );
    }

    final result = <String>[];
    for (int i = 0; i < translationsRaw.length; i++) {
      final tr = translationsRaw[i].toString().trim();
      final src = paragraphs[i].trim();
      if (tr.isEmpty) {
        throw Exception('Модель $model вернула пустой перевод абзаца #$i');
      }
      if (targetLanguage.toLowerCase().contains('russian') &&
          src.length > 25 &&
          !_isCyrillic(tr)) {
        throw Exception('Модель $model не перевела абзац #$i на русский язык');
      }
      result.add(tr);
    }

    return result;
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
