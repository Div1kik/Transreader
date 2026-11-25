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
  final Map<String, DateTime> _modelCooldownUntil = {};

  TranslatorService({required this.settings});

  bool isModelCoolingDown(String model) {
    final until = _modelCooldownUntil[model];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _modelCooldownUntil.remove(model);
      return false;
    }
    return true;
  }

  int getShortestCooldownSeconds() {
    if (_modelCooldownUntil.isEmpty) return 0;
    final now = DateTime.now();
    int minSec = 999999;
    for (final until in _modelCooldownUntil.values) {
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

  /// Быстрый перевод выделенного слова или фразы (в поп-апе при выделении)
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
        settings.apiKey.trim().isEmpty) {
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

  /// Контекстный поиск точного парного слова в соседнем абзаце (работает в обе стороны: EN->RU и RU->EN)
  Future<String> findCounterpartWordInContext({
    required String tappedWord,
    required String sourceParagraph,
    required String targetParagraph,
    required double relativePosition,
  }) async {
    final cleanWord = tappedWord.trim();
    if (cleanWord.isEmpty) return '';

    final isRussianTap = _isCyrillic(cleanWord);

    // 1. Если доступен онлайн-ключ (Groq / Custom API), просим модель выбрать ОДНО точное слово прямо из targetParagraph
    if (settings.engineMode != TranslationEngineMode.offlineLocal &&
        settings.apiKey.trim().isNotEmpty) {
      try {
        final pool = settings.activeModelPool
            .where((m) => !isModelCoolingDown(m))
            .toList();
        if (pool.isNotEmpty) {
          final model = pool.first;
          final pct = (relativePosition * 100).round();
          final response = await http
              .post(
                Uri.parse(settings.endpointUrl),
                headers: {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                  'Authorization': 'Bearer ${settings.apiKey}',
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
              .timeout(const Duration(seconds: 8));

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
        }
      } catch (_) {
        // При любой сетевой задержке мгновенно переходим к локальному переводу слова
      }
    }

    // 2. Офлайн-перевод слова в нужном направлении (RU->EN или EN->RU)
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

  Future<List<String>> translateBatch({
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
    void Function(String activeModel)? onModelSelected,
  }) async {
    if (paragraphs.isEmpty) return [];

    if (settings.engineMode == TranslationEngineMode.offlineLocal) {
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

    if (settings.apiKey.trim().isEmpty) {
      throw Exception(
        'Не подключён переводчик: вставьте ключ Groq или включите офлайн-модель в настройках',
      );
    }

    final pool = settings.activeModelPool;
    if (pool.isEmpty) {
      throw Exception('Не указаны модели в настройках');
    }

    final availableModels =
        pool.where((m) => !isModelCoolingDown(m)).toList();

    if (availableModels.isEmpty) {
      final waitSec = getShortestCooldownSeconds().clamp(3, 90);
      throw ModelRateLimitException(
        model: pool.first,
        retryAfterSeconds: waitSec,
        rawMessage: 'Все модели временно в лимите',
      );
    }

    Exception? lastError;

    for (final candidateModel in availableModels) {
      onModelSelected?.call(candidateModel);
      try {
        return await _callModelWithRetry(
          model: candidateModel,
          paragraphs: paragraphs,
          previousContext: previousContext,
          targetLanguage: targetLanguage,
        );
      } on ModelRateLimitException catch (rateErr) {
        _modelCooldownUntil[candidateModel] =
            DateTime.now().add(Duration(seconds: rateErr.retryAfterSeconds));
        lastError = rateErr;
        continue;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        continue;
      }
    }

    final waitSec = getShortestCooldownSeconds();
    if (waitSec > 0) {
      throw ModelRateLimitException(
        model: pool.first,
        retryAfterSeconds: waitSec.clamp(3, 90),
        rawMessage: lastError?.toString() ?? 'Все модели достигли лимита',
      );
    }

    throw lastError ?? Exception('Не удалось выполнить перевод');
  }

  Future<List<String>> _callModelWithRetry({
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
          await Future.delayed(Duration(milliseconds: 900 * attempt));
        }
      }
    }
    throw attemptError ?? Exception('Ошибка запроса к модели $model');
  }

  Future<List<String>> _sendRequest({
    required String model,
    required List<String> paragraphs,
    required List<String> previousContext,
    required String targetLanguage,
  }) async {
    final uri = Uri.parse(settings.endpointUrl);

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
            'Authorization': 'Bearer ${settings.apiKey}',
          },
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
      throw Exception('API ${response.statusCode}: ${response.body}');
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
