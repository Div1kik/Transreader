import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../db/book_database.dart';
import '../services/offline_translator_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final TranslatorSettings initialSettings;

  const SettingsScreen({
    super.key,
    required this.initialSettings,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final SettingsService _settingsService = SettingsService();
  late TranslationEngineMode _engineMode;
  late TextEditingController _endpointController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late TextEditingController _fallbacksController;
  late TextEditingController _langController;

  bool _obscureKey = true;
  bool _advancedExpanded = false;
  bool _downloadingOfflineModel = false;
  String? _offlineStatusStep;
  bool _offlineModelReady = false;
  bool _backupBusy = false;
  bool _waitingForGroqKey = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engineMode = widget.initialSettings.engineMode;
    _endpointController =
        TextEditingController(text: widget.initialSettings.endpointUrl);
    _apiKeyController =
        TextEditingController(text: widget.initialSettings.apiKey);
    _modelController =
        TextEditingController(text: widget.initialSettings.model);
    _fallbacksController = TextEditingController(
      text: widget.initialSettings.fallbackModels.join(', '),
    );
    _langController =
        TextEditingController(text: widget.initialSettings.targetLanguage);

    _advancedExpanded = _engineMode == TranslationEngineMode.customApi;
    _checkOfflineModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForGroqKey) {
      _waitingForGroqKey = false;
      _tryPasteGroqKeyFromClipboard(silentIfNotFound: true);
    }
  }

  Future<void> _openGroqKeysPage() async {
    _waitingForGroqKey = true;
    final uri = Uri.parse('https://console.groq.com/keys');
    // Открываем в Chrome Custom Tab — сверху будет крестик «✕» для возврата в 1 тап
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.inAppBrowserView,
    );
    if (!launched && mounted) {
      _waitingForGroqKey = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть console.groq.com')),
      );
    }
  }

  Future<void> _tryPasteGroqKeyFromClipboard({
    bool silentIfNotFound = false,
  }) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = data?.text?.trim() ?? '';

    if (clipText.startsWith('gsk_') && clipText.length > 20) {
      if (!mounted) return;
      setState(() {
        _engineMode = TranslationEngineMode.groqCloud;
        _apiKeyController.text = clipText;
        _endpointController.text =
            'https://api.groq.com/openai/v1/chat/completions';
        _modelController.text = 'llama-3.3-70b-versatile';
        _fallbacksController.text =
            'openai/gpt-oss-120b, openai/gpt-oss-20b, meta-llama/llama-4-scout-17b-16e-instruct';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ключ Groq (gsk_...) подхвачен и сохранён!'),
        ),
      );
      await _save();
    } else if (!silentIfNotFound && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'В буфере обмена пока нет ключа Groq (должен начинаться с gsk_)',
          ),
        ),
      );
    }
  }

  Future<void> _checkOfflineModel() async {
    final ready = await OfflineTranslatorService.instance.isPairDownloaded(
      targetLanguage: _langController.text.trim().isEmpty
          ? 'Russian'
          : _langController.text.trim(),
    );
    if (mounted) {
      setState(() => _offlineModelReady = ready);
    }
  }

  Future<void> _downloadOfflineModel() async {
    setState(() {
      _downloadingOfflineModel = true;
      _offlineStatusStep = 'Подготовка загрузки...';
    });
    try {
      await OfflineTranslatorService.instance.downloadLanguagePair(
        targetLanguage: _langController.text.trim().isEmpty
            ? 'Russian'
            : _langController.text.trim(),
        onProgress: (step) {
          if (mounted) setState(() => _offlineStatusStep = step);
        },
      );
      if (!mounted) return;
      setState(() {
        _offlineModelReady = true;
        _offlineStatusStep = null;
        _engineMode = TranslationEngineMode.offlineLocal;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Офлайн-модель скачана! Теперь можно переводить без интернета.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _offlineStatusStep = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _downloadingOfflineModel = false);
      }
    }
  }

  Future<void> _handleExportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final path = await BookDatabase.instance.exportBackup();
      if (!mounted) return;
      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Резервная копия книг и словаря успешно сохранена!'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка экспорта: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _handleImportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final restored = await BookDatabase.instance.importBackup();
      if (!mounted) return;
      if (restored) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Библиотека и словарь успешно восстановлены!'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка восстановления: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _endpointController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _fallbacksController.dispose();
    _langController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final fallbacks = _fallbacksController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final updated = TranslatorSettings(
      engineMode: _engineMode,
      endpointUrl: _endpointController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      fallbackModels: fallbacks,
      targetLanguage: _langController.text.trim().isEmpty
          ? 'Russian'
          : _langController.text.trim(),
    );
    await _settingsService.saveSettings(updated);
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final hasKey = _apiKeyController.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки переводчика'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Сохранить',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bolt, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Подключение Groq (основной режим)',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (hasKey &&
                          _engineMode == TranslationEngineMode.groqCloud)
                        const Icon(
                          Icons.check_circle,
                          color: Colors.greenAccent,
                          size: 20,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Нажмите кнопку ниже, создайте и скопируйте ключ (gsk_...).\n2. Нажмите крестик «✕» в левом верхнем углу вкладки — ключ подхватится сам.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openGroqKeysPage,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('1. Получить ключ на Groq'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _tryPasteGroqKeyFromClipboard(silentIfNotFound: false),
                      icon: const Icon(Icons.content_paste_go),
                      label: const Text('2. Вставить ключ из буфера и включить'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: _obscureKey,
                    onChanged: (val) {
                      if (val.trim().startsWith('gsk_')) {
                        _engineMode = TranslationEngineMode.groqCloud;
                        _endpointController.text =
                            'https://api.groq.com/openai/v1/chat/completions';
                      }
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: 'Ключ Groq (gsk_...)',
                      hintText: 'gsk_...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.offline_pin_outlined, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Встроенный офлайн-переводчик',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Switch(
                        activeColor: accent,
                        value:
                            _engineMode == TranslationEngineMode.offlineLocal,
                        onChanged: (val) async {
                          if (val) {
                            setState(() {
                              _engineMode = TranslationEngineMode.offlineLocal;
                            });
                            if (!_offlineModelReady) {
                              await _downloadOfflineModel();
                            }
                          } else {
                            setState(() {
                              _engineMode = TranslationEngineMode.groqCloud;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Работает вообще без интернета и ключей. Скачивает языковую модель (~30 МБ) один раз прямо в телефон.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _offlineStatusStep ??
                              (_offlineModelReady
                                  ? 'Статус: языковая модель загружена'
                                  : 'Статус: модель ещё не загружена'),
                          style: TextStyle(
                            fontSize: 12,
                            color: _offlineStatusStep != null
                                ? accent
                                : _offlineModelReady
                                    ? Colors.greenAccent
                                    : const Color(0xFFA89E93),
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _downloadingOfflineModel
                            ? null
                            : _downloadOfflineModel,
                        icon: _downloadingOfflineModel
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download, size: 18),
                        label: Text(
                          _offlineModelReady ? 'Проверить' : 'Скачать модель',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.backup_outlined, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Резервная копия книг и словаря',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Сохраняет все книги, готовые переводы и личный словарь в один файл .db, чтобы не потерять их при переустановке.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupBusy ? null : _handleExportBackup,
                          icon: const Icon(Icons.upload_file, size: 18),
                          label: const Text('Сохранить копию'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupBusy ? null : _handleImportBackup,
                          icon: const Icon(Icons.restore_page, size: 18),
                          label: const Text('Восстановить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _langController,
                onChanged: (_) => _checkOfflineModel(),
                decoration: const InputDecoration(
                  labelText: 'Язык перевода',
                  hintText: 'Russian',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          Card(
            child: ExpansionTile(
              initiallyExpanded: _advancedExpanded,
              onExpansionChanged: (v) => setState(() => _advancedExpanded = v),
              leading: Icon(Icons.tune, color: accent),
              title: const Text(
                'Для продвинутых пользователей',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Настройка Endpoint URL и пула моделей (Groq, OpenRouter, Gemini)',
                style: TextStyle(fontSize: 12, color: Color(0xFFA89E93)),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          ActionChip(
                            label: const Text('Groq Free (Рекомендуемый)'),
                            onPressed: () {
                              setState(() {
                                _engineMode = TranslationEngineMode.groqCloud;
                                _endpointController.text =
                                    'https://api.groq.com/openai/v1/chat/completions';
                                _modelController.text =
                                    'llama-3.3-70b-versatile';
                                _fallbacksController.text =
                                    'openai/gpt-oss-120b, openai/gpt-oss-20b, meta-llama/llama-4-scout-17b-16e-instruct';
                              });
                            },
                          ),
                          ActionChip(
                            label: const Text('OpenRouter Free'),
                            onPressed: () {
                              setState(() {
                                _engineMode = TranslationEngineMode.customApi;
                                _endpointController.text =
                                    'https://openrouter.ai/api/v1/chat/completions';
                                _modelController.text =
                                    'meta-llama/llama-3.3-70b-instruct:free';
                                _fallbacksController.text =
                                    'google/gemma-3-27b-it:free, mistralai/mistral-small-3.1-24b-instruct:free';
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _endpointController,
                        onChanged: (_) =>
                            _engineMode = TranslationEngineMode.customApi,
                        decoration: const InputDecoration(
                          labelText: 'API Endpoint URL',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _modelController,
                        decoration: const InputDecoration(
                          labelText: 'Основная модель',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _fallbacksController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Резервные модели (через запятую)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Сохранить настройки'),
          ),
        ],
      ),
    );
  }
}
