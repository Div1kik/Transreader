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
  final String author;
  final String format;
  final String? coverBase64;
  final int totalChapters;
  final int lastChapterIndex;
  final int lastPageIndex;
  final double lastScrollOffset;

  const Book({
    required this.id,
    required this.title,
    this.author = '',
    required this.format,
    this.coverBase64,
    required this.totalChapters,
    this.lastChapterIndex = 0,
    this.lastPageIndex = 0,
    this.lastScrollOffset = 0.0,
  });

  double get readingProgressPercent {
    if (totalChapters <= 0) return 0.0;
    return ((lastChapterIndex + 1) / totalChapters).clamp(0.0, 1.0);
  }

  Book copyWith({
    String? id,
    String? title,
    String? author,
    String? format,
    String? coverBase64,
    int? totalChapters,
    int? lastChapterIndex,
    int? lastPageIndex,
    double? lastScrollOffset,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      format: format ?? this.format,
      coverBase64: coverBase64 ?? this.coverBase64,
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
      'author': author,
      'format': format,
      'coverBase64': coverBase64,
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
      author: (map['author'] as String?) ?? '',
      format: map['format'] as String,
      coverBase64: map['coverBase64'] as String?,
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

class BookBookmark {
  final int? id;
  final String bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int pageIndex;
  final String quoteText;
  final String noteText;
  final int colorHex;
  final int createdAt;

  const BookBookmark({
    this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.pageIndex = 0,
    required this.quoteText,
    this.noteText = '',
    this.colorHex = 0xFFFFD54F,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'bookId': bookId,
      'chapterIndex': chapterIndex,
      'chapterTitle': chapterTitle,
      'pageIndex': pageIndex,
      'quoteText': quoteText,
      'noteText': noteText,
      'colorHex': colorHex,
      'createdAt': createdAt,
    };
  }

  factory BookBookmark.fromMap(Map<String, dynamic> map) {
    return BookBookmark(
      id: map['id'] as int?,
      bookId: map['bookId'] as String,
      chapterIndex: (map['chapterIndex'] as int?) ?? 0,
      chapterTitle: (map['chapterTitle'] as String?) ?? '',
      pageIndex: (map['pageIndex'] as int?) ?? 0,
      quoteText: (map['quoteText'] as String?) ?? '',
      noteText: (map['noteText'] as String?) ?? '',
      colorHex: (map['colorHex'] as int?) ?? 0xFFFFD54F,
      createdAt: (map['createdAt'] as int?) ?? 0,
    );
  }
}
