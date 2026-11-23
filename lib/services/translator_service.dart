import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/book_models.dart';

class TranslatorService {
  final TranslatorSettings settings;

  TranslatorService({required this.settings});

  Future<List<String>> translateBatch({
    required List<String> paragraphs,
    required String targetLanguage,
    List<String> contextTail = const [],
    String? overrideModel,
  }) async {
    if (paragraphs.isEmpty) return [];
    if (settings.apiKey.trim().isEmpty) {
      throw Exception('Не указан API Key в настройках переводчика');
    }

    final activeModel = (overrideModel != null && overrideModel.trim().isNotEmpty)
        ? overrideModel.trim()
        : settings.model.trim();

    final indexedInput = [
      for (int i = 0; i < paragraphs.length; i++)
        {'index': i, 'text': paragraphs[i]},
    ];

    final contextSection = contextTail.isEmpty
        ? ''
        : '''

Контекст предыдущих абзацев (уже переведены, НЕ включай их в ответ, используй только для согласования рода, времени, имён и стиля речи):
${contextTail.join('\n')}
''';

    final systemPrompt = '''
Ты профессиональный литературный переводчик художественной литературы на $targetLanguage язык.
Переводи естественно, художественно и связно, сохраняя авторский стиль, интонацию диалогов, пол персонажей, обращения на «ты/вы» и имена собственные.
Не сокращай и не объединяй абзацы: каждому входному элементу с "index" должен строго соответствовать один переведённый элемент с тем же "index".
На вход ты получаешь JSON-массив объектов с полями "index" и "text".$contextSection
Верни СТРОГО валидный JSON-массив такого же размера с полями "index" и "translation", без markdown-обёрток (```json) и без каких-либо пояснений.
''';

    final response = await http.post(
      Uri.parse(settings.endpointUrl),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36',
        'Authorization': 'Bearer ${settings.apiKey}',
      },
      body: jsonEncode({
        'model': activeModel,
        'temperature': 0.3,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': jsonEncode(indexedInput)},
        ],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errBody = utf8.decode(response.bodyBytes);
      throw Exception('API ${response.statusCode}:$errBody');
    }

    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final rawContent =
        decoded['choices'][0]['message']['content']?.toString() ?? '';

    final cleanedJson = _sanitizeJsonArray(_extractJsonArray(rawContent));
    final result = List<String>.filled(paragraphs.length, '');

    try {
      final parsedList = jsonDecode(cleanedJson) as List<dynamic>;
      for (final item in parsedList) {
        if (item is Map<String, dynamic>) {
          final rawIdx = item['index'];
          final idx = rawIdx is int
              ? rawIdx
              : int.tryParse(rawIdx?.toString() ?? '');
          final trans = item['translation']?.toString() ?? '';
          if (idx != null && idx >= 0 && idx < result.length) {
            result[idx] = trans.trim();
          }
        }
      }
    } on FormatException {
      final fallbackPairs = _regexFallbackExtract(cleanedJson);
      if (fallbackPairs.isEmpty) rethrow;
      fallbackPairs.forEach((idx, trans) {
        if (idx >= 0 && idx < result.length) {
          result[idx] = trans.trim();
        }
      });
    }

    for (int i = 0; i < result.length; i++) {
      if (result[i].isEmpty) {
        result[i] = paragraphs[i];
      }
    }

    return result;
  }

  String _extractJsonArray(String text) {
    var trimmed = text.trim();
    if (trimmed.startsWith('```')) {
      trimmed = trimmed
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    final start = trimmed.indexOf('[');
    final end = trimmed.lastIndexOf(']');
    if (start != -1 && end != -1 && end > start) {
      return trimmed.substring(start, end + 1);
    }
    return trimmed;
  }

  String _sanitizeJsonArray(String raw) {
    var fixed = raw;
    fixed = fixed.replaceAllMapped(
      RegExp(r'"index"\s*:\s*"?(\d+)"+'),
      (m) => '"index":${m.group(1)}',
    );
    fixed = fixed.replaceAll(RegExp(r',\s*([\]\}])'), r'$1');
    return fixed;
  }

  Map<int, String> _regexFallbackExtract(String raw) {
    final extracted = <int, String>{};
    final pattern = RegExp(
      r'"index"\s*:\s*"?(\d+)"?\s*,\s*"translation"\s*:\s*"((?:\\.|[^"\\])*)"',
      dotAll: true,
    );
    for (final match in pattern.allMatches(raw)) {
      final idx = int.tryParse(match.group(1) ?? '');
      final rawStr = match.group(2);
      if (idx != null && rawStr != null) {
        try {
          extracted[idx] = jsonDecode('"$rawStr"').toString();
        } catch (_) {
          extracted[idx] = rawStr
              .replaceAll(r'\"', '"')
              .replaceAll(r'\n', '\n');
        }
      }
    }
    return extracted;
  }
}
