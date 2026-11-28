import 'dart:convert';

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
  final int lastChapterIndex;
  final int lastPageIndex;
  final double lastScrollOffset;

  const Book({
    required this.id,
    required this.title,
    required this.format,
    required this.totalChapters,
    this.lastChapterIndex = 0,
    this.lastPageIndex = 0,
    this.lastScrollOffset = 0.0,
  });

  Book copyWith({
    String? id,
    String? title,
    String? format,
    int? totalChapters,
    int? lastChapterIndex,
    int? lastPageIndex,
    double? lastScrollOffset,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      format: format ?? this.format,
      totalChapters: totalChapters ?? this.totalChapters,
      lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
      lastPageIndex: lastPageIndex ?? this.lastPageIndex,
      lastScrollOffset: lastScrollOffset ?? this.lastScrollOffset,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'format': format,
      'totalChapters': totalChapters,
      'lastChapterIndex': lastChapterIndex,
      'lastPageIndex': lastPageIndex,
      'lastScrollOffset': lastScrollOffset,
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'] as String,
      title: map['title'] as String,
      format: map['format'] as String,
      totalChapters: map['totalChapters'] as int,
      lastChapterIndex: (map['lastChapterIndex'] as int?) ?? 0,
      lastPageIndex: (map['lastPageIndex'] as int?) ?? 0,
      lastScrollOffset: ((map['lastScrollOffset'] as num?) ?? 0.0).toDouble(),
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
  final Map<String, String> wordAlignMap;

  const ParagraphItem({
    this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.orderIndex,
    required this.sourceText,
    this.translatedText,
    this.wordAlignMap = const {},
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
      'wordAlignJson': wordAlignMap.isEmpty ? null : jsonEncode(wordAlignMap),
    };
  }

  factory ParagraphItem.fromMap(Map<String, dynamic> map) {
    Map<String, String> parsedAlign = const {};
    final rawJson = map['wordAlignJson'] as String?;
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map) {
          parsedAlign = decoded.map(
            (k, v) => MapEntry(
              k.toString().toLowerCase().trim(),
              v.toString().toLowerCase().trim(),
            ),
          );
        }
      } catch (_) {}
    }

    return ParagraphItem(
      id: map['id'] as int?,
      bookId: map['bookId'] as String,
      chapterIndex: map['chapterIndex'] as int,
      orderIndex: map['orderIndex'] as int,
      sourceText: map['sourceText'] as String,
      translatedText: map['translatedText'] as String?,
      wordAlignMap: parsedAlign,
    );
  }
}

class DictionaryEntry {
  final int? id;
  final String sourceText;
  final String translatedText;
  final String bookTitle;
  final int createdAt;

  const DictionaryEntry({
    this.id,
    required this.sourceText,
    required this.translatedText,
    required this.bookTitle,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'sourceText': sourceText,
      'translatedText': translatedText,
      'bookTitle': bookTitle,
      'createdAt': createdAt,
    };
  }

  factory DictionaryEntry.fromMap(Map<String, dynamic> map) {
    return DictionaryEntry(
      id: map['id'] as int?,
      sourceText: map['sourceText'] as String,
      translatedText: map['translatedText'] as String,
      bookTitle: (map['bookTitle'] as String?) ?? '',
      createdAt: (map['createdAt'] as int?) ?? 0,
    );
  }
}
