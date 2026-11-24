enum ChapterStatus {
  pending,
  inProgress,
  partial,
  completed,
}

class Book {
  final String id;
  final String title;
  final String format;
  final int totalChapters;

  const Book({
    required this.id,
    required this.title,
    required this.format,
    required this.totalChapters,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'format': format,
      'totalChapters': totalChapters,
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'] as String,
      title: map['title'] as String,
      format: map['format'] as String,
      totalChapters: map['totalChapters'] as int,
    );
  }
}

class Chapter {
  final String bookId;
  final int index;
  final String title;
  final ChapterStatus status;

  const Chapter({
    required this.bookId,
    required this.index,
    required this.title,
    this.status = ChapterStatus.pending,
  });

  Map<String, dynamic> toMap() {
    return {
      'bookId': bookId,
      'chapterIndex': index,
      'title': title,
      'status': status.index,
    };
  }

  factory Chapter.fromMap(Map<String, dynamic> map) {
    final statusIdx = (map['status'] as int?) ?? 0;
    return Chapter(
      bookId: map['bookId'] as String,
      index: map['chapterIndex'] as int,
      title: map['title'] as String,
      status: ChapterStatus
          .values[statusIdx.clamp(0, ChapterStatus.values.length - 1)],
    );
  }
}

class ParagraphItem {
  final int? id;
  final String bookId;
  final int chapterIndex;
  final int orderIndex;
  final String sourceText;
  final String? translatedText;

  const ParagraphItem({
    this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.orderIndex,
    required this.sourceText,
    this.translatedText,
  });

  bool get isTranslated =>
      translatedText != null && translatedText!.trim().isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'bookId': bookId,
      'chapterIndex': chapterIndex,
      'orderIndex': orderIndex,
      'sourceText': sourceText,
      'translatedText': translatedText,
    };
  }

  factory ParagraphItem.fromMap(Map<String, dynamic> map) {
    return ParagraphItem(
      id: map['id'] as int?,
      bookId: map['bookId'] as String,
      chapterIndex: map['chapterIndex'] as int,
      orderIndex: map['orderIndex'] as int,
      sourceText: map['sourceText'] as String,
      translatedText: map['translatedText'] as String?,
    );
  }
}
