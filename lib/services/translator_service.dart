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
  final Map<String, DateTime> _routeCooldownUntil = {};

  TranslatorService({required this.settings});

  String _routeKey(ApiProviderProfile provider, String model) =>
      '${provider.id}::$model';

  bool isRouteCoolingDown(ApiProviderProfile provider, String model) {
    final key = _routeKey(provider, model);
    final until = _routeCooldownUntil[key];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _routeCooldownUntil.remove(key);
      return false;
    }
    return true;
  }

  int getShortestCooldownSeconds() {
    if (_routeCooldownUntil.isEmpty) return 0;
    final now = DateTime.now();
    int minSec = 999999;
    for (final until in _routeCooldownUntil.values) {
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
                  headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'Authorization': 'Bearer ${provider.apiKey}',
                  },
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

    // Собираем все пары (Провайдер -> Модель) в порядке приоритета
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
      final waitSec = getShortestCooldownSeconds().clamp(3, 90);
      throw ModelRateLimitException(
        model: '${routes.first.provider.name}: ${routes.first.model}',
        retryAfterSeconds: waitSec,
        rawMessage: 'Все подключённые модели временно в лимите',
      );
    }

    Exception? lastError;

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
        _routeCooldownUntil[_routeKey(route.provider, route.model)] =
            DateTime.now().add(Duration(seconds: rateErr.retryAfterSeconds));
        lastError = rateErr;
        continue;
      } catch (e) {
        // При любой ошибке (403 Forbidden, 500, таймаут, сбой JSON) ставим связку на короткую паузу и идём к следующей модели/провайдеру
        _routeCooldownUntil[_routeKey(route.provider, route.model)] =
            DateTime.now().add(const Duration(seconds: 25));
        lastError = e is Exception ? e : Exception(e.toString());
        continue;
      }
    }

    // Если все онлайн-провайдеры и модели выдали ошибку, но включён страховочный переход на офлайн-словарь
    if (settings.fallbackToOfflineOnError) {
      try {
        return await _translateWithOfflineMlKit(
          paragraphs,
          targetLanguage,
          onModelSelected,
        );
      } catch (_) {}
    }

    final waitSec = getShortestCooldownSeconds();
    if (waitSec > 0) {
      throw ModelRateLimitException(
        model: availableRoutes.first.model,
        retryAfterSeconds: waitSec.clamp(3, 90),
        rawMessage: lastError?.toString() ?? 'Все модели достигли лимита',
      );
    }

    throw lastError ?? Exception('Ни одна из подключённых моделей не ответила');
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
        attemptError = e is Exception ? e : Exception(e.toString());
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
        ? 'Нет предыдущего контекста (начало главы).'
        : previousContext.join('\n');

    final numberedInput = <String, String>{};
    for (int i = 0; i < paragraphs.length; i++) {
      numberedInput['$i'] = paragraphs[i];
    }

    final systemPrompt = '''
Ты профессиональный художественный переводчик книг. Переводи текст на $targetLanguage язык.
Правила:
1. Сохраняй единый стиль, терминологию, имена собственные и пол персонажей, опираясь на контекст.
2. Переводи строго каждый абзац из входного JSON-объекта, сохраняя то же количество ключей ("0", "1", ...).
3. Не добавляй отсебятину, комментарии или пояснения.
4. Ответь СТРОГО валидным JSON-объектом формата: {"translations": ["перевод 0", "перевод 1", ...]}.
''';

    final userPrompt = '''
КОНТЕКСТ ПРЕДЫДУЩИХ АБЗАЦЕВ (только для понимания стиля и имён, не переводить повторно):
$contextBlock

АБЗАЦЫ ДЛЯ ПЕРЕВОДА (ровно ${paragraphs.length} шт.):
${jsonEncode(numberedInput)}
''';

    final body = jsonEncode({
      'model': model,
      'temperature': 0.3,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
    });

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': 'TransReader/1.0',
            'HTTP-Referer': 'https://transreader.app',
            'X-Title': 'TransReader',
            'Authorization': 'Bearer ${provider.apiKey}',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 55));

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
      throw Exception(
        '${provider.name} (${response.statusCode}): ${response.body}',
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

    return translationsRaw.map((e) => e.toString().trim()).toList();
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
