import 'dart:convert';
import 'package:http/http.dart' as http;

abstract class TranslatorService {
  Future<List<String>> translateBatch({
    required List<String> paragraphs,
    required String targetLanguage,
  });
}

class OpenAiCompatibleTranslator implements TranslatorService {
  final Uri endpoint;
  final String apiKey;
  final String model;

  OpenAiCompatibleTranslator({
    required this.endpoint,
    required this.apiKey,
    required this.model,
  });

  @override
  Future<List<String>> translateBatch({
    required List<String> paragraphs,
    required String targetLanguage,
  }) async {
    if (paragraphs.isEmpty) return [];

    final indexedInput = <String, String>{
      for (int i = 0; i < paragraphs.length; i++) '$i': paragraphs[i],
    };

    final response = await http.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'temperature': 0.3,
        'messages': [
          {
            'role': 'system',
            'content':
                'Ты литературный переводчик книг. Переведи каждый фрагмент на язык: $targetLanguage. '
                'Сохраняй стиль автора, имена собственных персонажей и смысл. '
                'Верни строго JSON-объект с теми же ключами ("0", "1", ...), без markdown-оформления и пояснений.',
          },
          {
            'role': 'user',
            'content': jsonEncode(indexedInput),
          },
        ],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Ошибка API переводчика: ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final content = decoded['choices'][0]['message']['content'] as String;
    final cleaned = content
        .replaceAll(RegExp(r'^```json\s*|\s*```$', multiLine: true), '')
        .trim();

    final mapResult = jsonDecode(cleaned) as Map<String, dynamic>;
    return List.generate(
      paragraphs.length,
      (i) => (mapResult['$i'] as String?)?.trim() ?? paragraphs[i],
    );
  }
}
