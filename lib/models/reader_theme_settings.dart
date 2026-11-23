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
          background: Color(0xFFFAFAFA),
          surface: Color(0xFFEEEEEE),
          text: Color(0xFF1C1C1E),
          secondaryText: Color(0xFF6E6E73),
          accent: Color(0xFF00796B),
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
          background: Color(0xFF181A1B),
          surface: Color(0xFF232628),
          text: Color(0xFFE4E6EB),
          secondaryText: Color(0xFF9AA0A6),
          accent: Color(0xFF4DB6AC),
          brightness: Brightness.dark,
        );
      case ReaderColorTheme.amoled:
        return const ReaderPalette(
          name: 'AMOLED',
          background: Color(0xFF000000),
          surface: Color(0xFF121212),
          text: Color(0xFFD8D8D8),
          secondaryText: Color(0xFF808080),
          accent: Color(0xFF4DB6AC),
          brightness: Brightness.dark,
        );
    }
  }
}

class ReaderAppearance {
  final ReaderColorTheme colorTheme;
  final ReaderPageMode pageMode;
  final double fontSize;
  final double lineHeight;
  final bool showOriginal;

  const ReaderAppearance({
    this.colorTheme = ReaderColorTheme.dark,
    this.pageMode = ReaderPageMode.scroll,
    this.fontSize = 18.0,
    this.lineHeight = 1.55,
    this.showOriginal = false,
  });

  ReaderAppearance copyWith({
    ReaderColorTheme? colorTheme,
    ReaderPageMode? pageMode,
    double? fontSize,
    double? lineHeight,
    bool? showOriginal,
  }) {
    return ReaderAppearance(
      colorTheme: colorTheme ?? this.colorTheme,
      pageMode: pageMode ?? this.pageMode,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      showOriginal: showOriginal ?? this.showOriginal,
    );
  }

  static Future<ReaderAppearance> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIdx = prefs.getInt('reader_color_theme') ?? ReaderColorTheme.dark.index;
    final modeIdx = prefs.getInt('reader_page_mode') ?? ReaderPageMode.scroll.index;
    return ReaderAppearance(
      colorTheme: ReaderColorTheme.values[themeIdx.clamp(0, ReaderColorTheme.values.length - 1)],
      pageMode: ReaderPageMode.values[modeIdx.clamp(0, ReaderPageMode.values.length - 1)],
      fontSize: prefs.getDouble('reader_font_size') ?? 18.0,
      lineHeight: prefs.getDouble('reader_line_height') ?? 1.55,
      showOriginal: prefs.getBool('reader_show_original') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('reader_color_theme', colorTheme.index);
    await prefs.setInt('reader_page_mode', pageMode.index);
    await prefs.setDouble('reader_font_size', fontSize);
    await prefs.setDouble('reader_line_height', lineHeight);
    await prefs.setBool('reader_show_original', showOriginal);
  }
}
