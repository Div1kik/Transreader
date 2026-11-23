enum TranslateMode { nextChapters, fullBook }

enum ChapterStatus { pending, inProgress, partial, completed }

class Book {
  final String id;
  final String title;
  final String format; // 'txt' или 'fb2'
  final int totalChapters;

  Book({
    required this.id,
    required this.title,
    required this.format,
    required this.totalChapters,
  });
}

class Chapter {
  final int? id;
  final String bookId;
  final int index; // 0, 1, 2...
  final String title;
  final ChapterStatus status;

  Chapter({
    this.id,
    required this.bookId,
    required this.index,
    required this.title,
    this.status = ChapterStatus.pending,
  });
}

class ParagraphItem {
  final int? id;
  final String bookId;
  final int chapterIndex;
  final int orderIndex;
  final String sourceText;
  final String? translatedText;

  ParagraphItem({
    this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.orderIndex,
    required this.sourceText,
    this.translatedText,
  });

  bool get isTranslated =>
      translatedText != null && translatedText!.trim().isNotEmpty;
}

class TranslatorSettings {
  final String endpointUrl;
  final String apiKey;
  final String model;
  final List<String> fallbackModels;
  final bool autoSwitchModels;
  final String targetLanguage;

  const TranslatorSettings({
    this.endpointUrl = 'https://api.groq.com/openai/v1/chat/completions',
    this.apiKey = '',
    this.model = 'openai/gpt-oss-120b',
    this.fallbackModels = const ['qwen/qwen3.8-27b', 'openai/gpt-oss-20b'],
    this.autoSwitchModels = true,
    this.targetLanguage = 'русский',
  });

  List<String> get activeModelChain {
    final list = <String>[];
    if (model.trim().isNotEmpty) list.add(model.trim());
    if (autoSwitchModels) {
      for (final m in fallbackModels) {
        final clean = m.trim();
        if (clean.isNotEmpty && !list.contains(clean)) {
          list.add(clean);
        }
      }
    }
    return list;
  }
}
