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
