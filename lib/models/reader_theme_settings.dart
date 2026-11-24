import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderColorTheme {
  light,
  sepia,
  dark,
  amoled,
}

enum ReaderPageMode {
  scroll,
  pageSlide,
  pageCurl,
}

enum ReaderTextDisplay {
  translationOnly,
  bilingual,
  originalOnly,
}

class ReaderPalette {
  final String name;
  final Color background;
  final Color surface;
  final Color text;
  final Color secondaryText;
  final Color accent;
  final Brightness brightness;

  const ReaderPalette({
    required this.name,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.accent,
    required this.brightness,
  });

  static ReaderPalette of(ReaderColorTheme theme) {
    switch (theme) {
      case ReaderColorTheme.light:
        return const ReaderPalette(
          name: 'Светлая',
          background: Color(0xFFFAF8F5),
          surface: Color(0xFFEFECE6),
          text: Color(0xFF1F1C18),
          secondaryText: Color(0xFF6E675F),
          accent: Color(0xFFB86B24),
          brightness: Brightness.light,
        );
      case ReaderColorTheme.sepia:
        return const ReaderPalette(
          name: 'Сепия',
          background: Color(0xFFF4ECD8),
          surface: Color(0xFFE8DEC3),
          text: Color(0xFF3E3224),
          secondaryText: Color(0xFF7A6852),
          accent: Color(0xFF8D5524),
          brightness: Brightness.light,
        );
      case ReaderColorTheme.dark:
        return const ReaderPalette(
          name: 'Тёмная',
          background: Color(0xFF191613),
          surface: Color(0xFF241F1B),
          text: Color(0xFFEAE3DA),
          secondaryText: Color(0xFFA89E93),
          accent: Color(0xFFD98A3C),
          brightness: Brightness.dark,
        );
      case ReaderColorTheme.amoled:
        return const ReaderPalette(
          name: 'AMOLED',
          background: Color(0xFF000000),
          surface: Color(0xFF14110F),
          text: Color(0xFFDCD5CC),
          secondaryText: Color(0xFF8A8177),
          accent: Color(0xFFD98A3C),
          brightness: Brightness.dark,
        );
    }
  }
}

class ReaderAppearance {
  final ReaderColorTheme colorTheme;
  final ReaderPageMode pageMode;
  final ReaderTextDisplay textDisplay;
  final double fontSize;
  final double lineHeight;

  const ReaderAppearance({
    this.colorTheme = ReaderColorTheme.sepia,
    this.pageMode = ReaderPageMode.pageCurl,
    this.textDisplay = ReaderTextDisplay.translationOnly,
    this.fontSize = 18.0,
    this.lineHeight = 1.55,
  });

  bool get showOriginal => textDisplay == ReaderTextDisplay.bilingual;
  bool get isOriginalOnly => textDisplay == ReaderTextDisplay.originalOnly;

  ReaderAppearance copyWith({
    ReaderColorTheme? colorTheme,
    ReaderPageMode? pageMode,
    ReaderTextDisplay? textDisplay,
    double? fontSize,
    double? lineHeight,
  }) {
    return ReaderAppearance(
      colorTheme: colorTheme ?? this.colorTheme,
      pageMode: pageMode ?? this.pageMode,
      textDisplay: textDisplay ?? this.textDisplay,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
    );
  }

  static Future<ReaderAppearance> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIdx =
        prefs.getInt('reader_color_theme') ?? ReaderColorTheme.sepia.index;
    final modeIdx =
        prefs.getInt('reader_page_mode') ?? ReaderPageMode.pageCurl.index;
    final displayIdx = prefs.getInt('reader_text_display') ??
        ReaderTextDisplay.translationOnly.index;

    return ReaderAppearance(
      colorTheme: ReaderColorTheme
          .values[themeIdx.clamp(0, ReaderColorTheme.values.length - 1)],
      pageMode: ReaderPageMode
          .values[modeIdx.clamp(0, ReaderPageMode.values.length - 1)],
      textDisplay: ReaderTextDisplay
          .values[displayIdx.clamp(0, ReaderTextDisplay.values.length - 1)],
      fontSize: prefs.getDouble('reader_font_size') ?? 18.0,
      lineHeight: prefs.getDouble('reader_line_height') ?? 1.55,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('reader_color_theme', colorTheme.index);
    await prefs.setInt('reader_page_mode', pageMode.index);
    await prefs.setInt('reader_text_display', textDisplay.index);
    await prefs.setDouble('reader_font_size', fontSize);
    await prefs.setDouble('reader_lineHeight', lineHeight);
  }
}
