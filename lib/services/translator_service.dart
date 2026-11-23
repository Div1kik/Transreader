import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/book_models.dart';

class TranslatorService {
  final TranslatorSettings settings;

  TranslatorService({required this.settings});

  Future<List<String>> translateBatch({
    required List<String> paragraphs,
    required String targetLanguage,
    String? overrideModel,
  }) async {
    if (paragraphs.isEmpty) return [];
    if (settings.apiKey.trim().isEmpty) {
      throw Exception('Не указан API Key в настройках переводчика');
    }

    final activeModel = (overrideModel != null && overrideModel.trim().isNotEmpty)
        ? overrideModel.trim()
        : settings.model.trim();

    final indexedInput = >[
      for (int i = 0; i < paragraphs.length; i++)
        {'index': i, 'text': paragraphs[i]},
    ];

    final systemPrompt = '''
Ты профессиональный литературный переводчик художественной литературы на $targetLanguage язык.
Переводи естественно, сохраняя авторский стиль, интонацию диалогов, имена собственные и атмосферу текста.
На вход ты получаешь JSON-массив объектов с полями "index" и "text".
Верни СТРОГО валидный JSON-массив такого же размера с полями "index" и "translation", без markdown-обёрток (```json) и без каких-либо пояснений.
''';

    final response = await http.post(
      Uri.parse(settings.endpointUrl),
      headers: {
        'Content-Type': 'application/json',
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

    final cleanedJson = _extractJsonArray(rawContent);
    final parsedList = jsonDecode(cleanedJson) as List<dynamic>;

    final result = List<String>.filled(paragraphs.length, '');
    for (final item in parsedList) {
      if (item is Map<String, dynamic>) {
        final idx = item['index'];
        final trans = item['translation']?.toString() ?? '';
        if (idx is int && idx >= 0 && idx < result.length) {
          result[idx] = trans.trim();
        }
      }
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
}
