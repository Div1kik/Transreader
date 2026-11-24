import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
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

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settingsService = SettingsService();
  late TranslationEngineMode _engineMode;
  late TextEditingController _endpointController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late TextEditingController _fallbacksController;
  late TextEditingController _langController;

  bool _obscureKey = true;
  bool _advancedExpanded = false;
  bool _authInProgress = false;
  bool _downloadingOfflineModel = false;
  bool _offlineModelReady = false;
  bool _backupBusy = false;

  static const String _callbackUrl = 'https://transreader.app/callback';

  @override
  void initState() {
    super.initState();
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

  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(64, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  Future<void> _startOpenRouterOneClickAuth() async {
    setState(() => _authInProgress = true);
    try {
      final verifier = _generateCodeVerifier();
      final challenge = _generateCodeChallenge(verifier);

      final authUri = Uri.https('openrouter.ai', '/auth', {
        'callback_url': _callbackUrl,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });

      if (!mounted) return;
      final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => _OpenRouterWebViewAuthScreen(
            authUri: authUri,
            callbackPrefix: _callbackUrl,
          ),
        ),
      );

      if (code != null && code.isNotEmpty) {
        await _exchangeOpenRouterCode(code, verifier);
      } else if (mounted) {
        setState(() => _authInProgress = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _authInProgress = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка запуска авторизации: $e')),
      );
    }
  }

  Future<void> _exchangeOpenRouterCode(String code, String verifier) async {
    try {
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/auth/keys'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'code_verifier': verifier,
          'code_challenge_method': 'S256',
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Ошибка получения ключа (${response.statusCode})');
      }

      final data = jsonDecode(response.body);
      final receivedKey = data['key']?.toString() ?? '';
      if (receivedKey.isEmpty) {
        throw Exception('Сервер не вернул ключ');
      }

      if (!mounted) return;
      setState(() {
        _engineMode = TranslationEngineMode.oneClickOpenRouter;
        _apiKeyController.text = receivedKey;
        _endpointController.text =
            'https://openrouter.ai/api/v1/chat/completions';
        _modelController.text = 'meta-llama/llama-3.3-70b-instruct:free';
        _fallbacksController.text =
            'google/gemma-3-27b-it:free, mistralai/mistral-small-3.1-24b-instruct:free, qwen/qwen-2.5-72b-instruct:free';
        _authInProgress = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Готово! Ключ автоматически подключён и сохранён.'),
        ),
      );
      await _save();
    } catch (e) {
      if (!mounted) return;
      setState(() => _authInProgress = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка обмена ключа: $e')),
      );
    }
  }

  Future<void> _downloadOfflineModel() async {
    setState(() => _downloadingOfflineModel = true);
    try {
      await OfflineTranslatorService.instance.downloadLanguagePair(
        targetLanguage: _langController.text.trim().isEmpty
            ? 'Russian'
            : _langController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _offlineModelReady = true;
        _engineMode = TranslationEngineMode.offlineLocal;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Офлайн-модель скачана! Теперь можно переводить без интернета.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки офлайн-модели: $e')),
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
            content: Text('Резервная копия книг и переводов успешно сохранена!'),
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
            content: Text('Библиотека и все переводы успешно восстановлены!'),
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
          // БЛОК 1: Вход в 1 клик (OpenRouter OAuth)
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
                          'Быстрое подключение в 1 клик',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (hasKey &&
                          _engineMode ==
                              TranslationEngineMode.oneClickOpenRouter)
                        const Icon(
                          Icons.check_circle,
                          color: Colors.greenAccent,
                          size: 20,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Откроется окно входа OpenRouter. Если у вас ещё нет аккаунта — войдите через Google, ключ создастся автоматически. Если аккаунт уже есть и ключ ранее создавался — просто подтвердите доступ, ключ подтянется сам.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          _authInProgress ? null : _startOpenRouterOneClickAuth,
                      icon: _authInProgress
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(
                        hasKey
                            ? 'Переподключить / Обновить ключ (1 клик)'
                            : 'Подключить в 1 клик (OpenRouter)',
                      ),
                    ),
                  ),
                  if (hasKey) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Ключ активен: ${_apiKeyController.text.substring(0, _apiKeyController.text.length.clamp(0, 10))}...',
                      style: TextStyle(fontSize: 12, color: accent),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // БЛОК 2: Встроенный офлайн-переводчик (Google ML Kit)
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
                              _engineMode =
                                  TranslationEngineMode.oneClickOpenRouter;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Работает вообще без интернета, ключей и VPN. Скачивает языковую модель (~30 МБ) один раз прямо в телефон.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _offlineModelReady
                              ? 'Статус: языковая модель загружена'
                              : 'Статус: модель ещё не загружена',
                          style: TextStyle(
                            fontSize: 12,
                            color: _offlineModelReady
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

          // БЛОК 3: Резервное копирование библиотеки книг и переводов
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
                          'Резервная копия книг и переводов',
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
                    'Сохраняйте все загруженные книги и готовые переводы в файл .db, чтобы не потерять их при переустановке или смене телефона.',
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

          // БЛОК 4: Язык перевода
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

          // БЛОК 5: Для продвинутых пользователей (ручной ввод API)
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
                'Ручной ввод API Key, Endpoint и списка моделей (Groq, OpenRouter, Gemini)',
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
                            label: const Text('Groq Free'),
                            onPressed: () {
                              setState(() {
                                _engineMode = TranslationEngineMode.customApi;
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
                        controller: _apiKeyController,
                        obscureText: _obscureKey,
                        onChanged: (_) =>
                            _engineMode = TranslationEngineMode.customApi,
                        decoration: InputDecoration(
                          labelText: 'API Key',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureKey
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () =>
                                setState(() => _obscureKey = !_obscureKey),
                          ),
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

class _OpenRouterWebViewAuthScreen extends StatefulWidget {
  final Uri authUri;
  final String callbackPrefix;

  const _OpenRouterWebViewAuthScreen({
    required this.authUri,
    required this.callbackPrefix,
  });

  @override
  State<_OpenRouterWebViewAuthScreen> createState() =>
      _OpenRouterWebViewAuthScreenState();
}

class _OpenRouterWebViewAuthScreenState
    extends State<_OpenRouterWebViewAuthScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _codeHandled = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (mounted) setState(() => _isLoading = true);
            _tryExtractCode(url);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
          onNavigationRequest: (request) {
            if (_tryExtractCode(request.url)) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(widget.authUri);
  }

  bool _tryExtractCode(String url) {
    if (_codeHandled) return true;
    if (url.startsWith(widget.callbackPrefix)) {
      final uri = Uri.tryParse(url);
      final code = uri?.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        _codeHandled = true;
        if (mounted) {
          Navigator.of(context).pop(code);
        }
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Подключение OpenRouter'),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const LinearProgressIndicator(minHeight: 3),
        ],
      ),
    );
  }
}
