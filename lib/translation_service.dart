import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class TranslationService {
  static const String _apiUrl = 'https://api-free.deepl.com/v2/translate';
  static const String _deepLApiKey = '23faef47-7173-4d29-b5be-64fe54165ef8:fx'; // Your DeepL API key
  static List<String> _supportedLanguages = [
    'AR', // Arabic
    'BG', // Bulgarian
    'CS', // Czech
    'DA', // Danish
    'DE', // German
    'EL', // Greek
    'EN-GB', // English (British)
    'EN-US', // English (American)
    'ES', // Spanish
    'ET', // Estonian
    'FI', // Finnish
    'FR', // French
    'HU', // Hungarian
    'ID', // Indonesian
    'IT', // Italian
    'JA', // Japanese
    'KO', // Korean
    'LT', // Lithuanian
    'LV', // Latvian
    'NB', // Norwegian Bokmål
    'NL', // Dutch
    'PL', // Polish
    'PT-BR', // Portuguese (Brazilian)
    'PT-PT', // Portuguese (European)
    'RO', // Romanian
    'RU', // Russian
    'SK', // Slovak
    'SL', // Slovenian
    'SV', // Swedish
    'TR', // Turkish
    'UK', // Ukrainian
    'ZH', // Chinese
    'ZH-HANS', // Chinese (Simplified)
    'ZH-HANT', // Chinese (Traditional)
  ];
  static const int _maxRetries = 3;
  static const Duration _cacheExpiration = Duration(days: 7);

  TranslationService() {
    // Fetch supported languages on initialization
    _updateSupportedLanguages();
  }

  Future<String> translate(String text, String targetLanguage) async {
    if (text.isEmpty || !_supportedLanguages.contains(targetLanguage.toUpperCase())) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Invalid translation request: text="$text", targetLanguage="$targetLanguage"');
      throw Exception('Invalid input: Empty text or unsupported language ($targetLanguage)');
    }

    final cacheKey = '$text-$targetLanguage';
    final translationsBox = await Hive.openBox('translations');
    final cachedTranslation = translationsBox.get(cacheKey);
    if (cachedTranslation != null) {
      // Check cache expiration
      final timestamp = translationsBox.get('$cacheKey-timestamp', defaultValue: DateTime(2000));
      if (DateTime.now().difference(timestamp).inDays < _cacheExpiration.inDays) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Returning cached translation for $cacheKey: $cachedTranslation');
        return cachedTranslation;
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Cached translation expired for $cacheKey');
        await translationsBox.delete(cacheKey);
        await translationsBox.delete('$cacheKey-timestamp');
      }
    }

    int retryCount = 0;
    while (retryCount < _maxRetries) {
      try {
        final clientTraceId = const Uuid().v4();
        final response = await http.post(
          Uri.parse(_apiUrl),
          headers: {
            'Authorization': 'DeepL-Auth-Key $_deepLApiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'text': [text],
            'target_lang': targetLanguage.toUpperCase(),
          }),
        ).timeout(const Duration(seconds: 5));

        print('DEBUG [${DateTime.now().toIso8601String()}]: Translation API response: ${response.statusCode}, body: ${response.body}');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final translatedText = data['translations'][0]['text'] as String? ?? text;
          await translationsBox.put(cacheKey, translatedText);
          await translationsBox.put('$cacheKey-timestamp', DateTime.now());
          print('DEBUG [${DateTime.now().toIso8601String()}]: Translation successful: $translatedText');
          return translatedText;
        } else {
          final error = jsonDecode(response.body)['message'] ?? 'Unknown error';
          print('DEBUG [${DateTime.now().toIso8601String()}]: Translation API error: ${response.statusCode} - $error');
          throw Exception('Translation failed: ${response.statusCode} - $error');
        }
      } catch (e, stackTrace) {
        retryCount++;
        if (retryCount >= _maxRetries) {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Translation failed after $retryCount attempts: $e\nStackTrace: $stackTrace');
          throw Exception('Translation failed after $_maxRetries attempts: $e');
        }
        print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying translation, attempt: ${retryCount + 1}, error: $e');
        await Future.delayed(Duration(seconds: 2 * retryCount));
      }
    }
    throw Exception('Translation failed after $_maxRetries attempts');
  }

  Future<Map<String, String>> translateToAllLanguages(String text) async {
    final translations = <String, String>{};
    for (final lang in _supportedLanguages) {
      try {
        translations[lang] = await translate(text, lang);
      } catch (e) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to translate to $lang: $e');
        translations[lang] = text; // Fallback to original text
      }
    }
    return translations;
  }

  Future<void> clearCache() async {
    final translationsBox = await Hive.openBox('translations');
    await translationsBox.clear();
    print('DEBUG [${DateTime.now().toIso8601String()}]: Translation cache cleared');
  }

  static List<String> getSupportedLanguages() => _supportedLanguages;

  Future<List<String>> fetchSupportedLanguages() async {
    int retryCount = 0;
    while (retryCount < _maxRetries) {
      try {
        final response = await http.get(
          Uri.parse('https://api-free.deepl.com/v2/languages?type=target'),
          headers: {
            'Authorization': 'DeepL-Auth-Key $_deepLApiKey',
          },
        ).timeout(const Duration(seconds: 5));

        print('DEBUG [${DateTime.now().toIso8601String()}]: Fetch supported languages response: ${response.statusCode}, body: ${response.body}');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final languages = List<String>.from(data.map((lang) => lang['language']));
          print('DEBUG [${DateTime.now().toIso8601String()}]: Fetched ${languages.length} supported languages');
          return languages;
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch supported languages: ${response.statusCode} - ${response.body}');
          throw Exception('Failed to fetch supported languages: ${response.statusCode}');
        }
      } catch (e, stackTrace) {
        retryCount++;
        if (retryCount >= _maxRetries) {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch supported languages after $retryCount attempts: $e\nStackTrace: $stackTrace');
          return _supportedLanguages;
        }
        print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying fetchSupportedLanguages, attempt: ${retryCount + 1}, error: $e');
        await Future.delayed(Duration(seconds: 2 * retryCount));
      }
    }
    return _supportedLanguages;
  }

  Future<void> _updateSupportedLanguages() async {
    try {
      final languages = await fetchSupportedLanguages();
      _supportedLanguages = languages;
      print('DEBUG [${DateTime.now().toIso8601String()}]: Updated supported languages: $_supportedLanguages');
    } catch (e) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to update supported languages: $e');
    }
  }
}