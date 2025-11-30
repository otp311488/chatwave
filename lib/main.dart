import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_29/DashboardScreen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'chat_list.dart';
import 'chat_screen.dart';
import 'new_chat.dart';
import 'privacy.dart';

// Global navigator key for context access
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Initialize notifications
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// Battery optimization MethodChannel
const MethodChannel _batteryChannel = MethodChannel('com.chatwave/battery');

// Global flag to prevent duplicate navigation
bool _isNavigating = false;

// HttpService
class HttpService {
  static const String baseUrl = 'http://147.93.177.26';

  static Future<http.Response> get(String endpoint, {Map<String, String>? query, int retryCount = 1}) async {
    final uri = Uri.parse('$baseUrl/${endpoint.trim().replaceAll(RegExp(r'^/+|/+$'), '')}').replace(queryParameters: query);
    final headers = await _getHeaders();
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: GET $uri, headers: $headers');
    try {
      final response = await http.get(uri, headers: headers);
      if (await handleSessionError(response, retryCount, endpoint)) {
        return get(endpoint, query: query, retryCount: retryCount - 1);
      }
      _logResponse(response);
      return response;
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Connection error: $e\nStackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<http.Response> post(String endpoint, {Map<String, dynamic>? body, int retryCount = 1}) async {
    final uri = Uri.parse('$baseUrl/${endpoint.trim().replaceAll(RegExp(r'^/+|/+$'), '')}');
    final headers = await _getHeaders(endpoint: endpoint);
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: POST $uri, headers: $headers, body: $body');
    try {
      final response = await http.post(uri, headers: headers, body: jsonEncode(body));
      if (await handleSessionError(response, retryCount, endpoint)) {
        return post(endpoint, body: body, retryCount: retryCount - 1);
      }
      _logResponse(response);
      return response;
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Connection error: $e\nStackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<http.Response> getDashboardMetrics() async {
    return get('dashboard.php', query: {'action': 'get_metrics'}, retryCount: 1);
  }

  static Future<bool> handleSessionError(http.Response response, int retryCount, String endpoint) async {
    if (retryCount <= 0) return false;
    if (response.statusCode == 401 || (response.statusCode == 200 && response.body.contains('Invalid session'))) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session error detected: ${response.body}');
      if (endpoint.contains('action=refresh_session')) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Refresh session failed, redirecting to login');
        NotificationService.stopPolling();
        await Workmanager().cancelAll();
        final context = navigatorKey.currentContext;
        if (context != null && context.mounted && !_isNavigating) {
          _isNavigating = true;
          try {
            await Navigator.pushReplacementNamed(context, '/auth');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Session expired. Please log in again.',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          } finally {
            _isNavigating = false;
          }
        }
        return false;
      }
      if (await AuthState.refreshSession()) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session refreshed, retrying request');
        return true;
      }
      return false;
    }
    return false;
  }

  static Future<String?> uploadFile(File file, String type, {Function(double)? onProgress}) async {
    try {
      if (!await file.exists()) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: File does not exist: ${file.path}');
        return null;
      }
      final fileSize = await file.length();
      if (fileSize == 0) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: File is empty: ${file.path}');
        return null;
      }
      if (fileSize > 50 * 1024 * 1024) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: File too large: ${fileSize / 1024 / 1024}MB');
        return null;
      }

      final uri = Uri.parse('$baseUrl/chat.php?action=upload_media');
      final request = http.MultipartRequest('POST', uri);
      final sessionId = AuthState.sessionId ?? '';
      if (sessionId.isEmpty) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: No session ID available');
        throw Exception('No session ID');
      }
      request.headers['Session-ID'] = sessionId;
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Preparing upload: file=${file.path}, type=$type, size=${fileSize / 1024 / 1024}MB');

      String mimeType;
      switch (type) {
        case 'voice':
          mimeType = 'audio/mp4';
          break;
        case 'image':
          mimeType = lookupMimeType(file.path) ?? 'image/jpeg';
          break;
        case 'video':
          mimeType = lookupMimeType(file.path) ?? 'video/mp4';
          break;
        case 'document':
          mimeType = 'application/pdf';
          break;
        default:
          mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
      }

      final multipartFile = await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: http_parser.MediaType.parse(mimeType),
      );
      request.files.add(multipartFile);
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Added file to request: field=file, path=${file.path}, mime=$mimeType');

      int bytesTransferred = 0;
      final totalBytes = fileSize;
      if (onProgress != null) {
        Timer.periodic(const Duration(milliseconds: 100), (timer) {
          bytesTransferred += (totalBytes ~/ 10).clamp(0, totalBytes - bytesTransferred);
          final progress = bytesTransferred / totalBytes;
          onProgress(progress.clamp(0.0, 1.0));
          if (bytesTransferred >= totalBytes) timer.cancel();
        });
      }

      final response = await request.send().timeout(const Duration(seconds: 60));
      final responseBody = await response.stream.bytesToString();
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Upload response: status=${response.statusCode}, body=$responseBody');

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        if (data['status'] == 'success' && data['url'] != null) {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Upload successful: url=${data['url']}');
          return data['url'];
        } else {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Upload failed: ${data['message']}');
          throw Exception(data['message'] ?? 'Upload failed');
        }
      } else {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Upload failed with status: ${response.statusCode}');
        throw Exception('Server error: $responseBody');
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Upload file error: $e\nStackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<Map<String, String>> _getHeaders({String? endpoint}) async {
    final sessionId = AuthState.sessionId;
    if (endpoint != null && (endpoint.contains('action=signup') || endpoint.contains('action=login'))) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: No session ID for $endpoint');
      return {'Content-Type': 'application/json'};
    }
    if (sessionId == null || sessionId.isEmpty) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: No session ID available');
      return {'Content-Type': 'application/json'};
    }
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Including Session-ID in headers: $sessionId');
    return {
      'Content-Type': 'application/json',
      'Session-ID': sessionId,
    };
  }

  static void _logResponse(http.Response response) {
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Response ${response.request?.url}: status=${response.statusCode}, body=${response.body}');
  }
}

// NotificationService
class NotificationService {
  static const String _baseUrl = 'http://147.93.177.26';
  static Timer? _pollTimer;
  static const String _messageBoxName = 'messageBox';
  static Box? _messageBox;
  static bool _isHiveInitialized = false;

  static Future<void> initialize() async {
    try {
      final androidPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final iosPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
      await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);

      const androidChannel = AndroidNotificationChannel(
        'message_notifications',
        'Message Notifications',
        description: 'Notifications for new messages',
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('notification_sound'),
      );
      await androidPlugin?.createNotificationChannel(androidChannel);

      if (!_isHiveInitialized) {
        final dir = await getApplicationDocumentsDirectory();
        await Hive.initFlutter(dir.path);
        _isHiveInitialized = true;
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Hive initialized in NotificationService with path: ${dir.path}');
      }

      if (!Hive.isBoxOpen(_messageBoxName)) {
        _messageBox = await Hive.openBox(_messageBoxName);
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Opened Hive box: $_messageBoxName');
      } else {
        _messageBox = Hive.box(_messageBoxName);
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Hive box $_messageBoxName already open');
      }

      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: NotificationService initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: NotificationService initialization error: $e\nStackTrace: $stackTrace');
      rethrow;
    }
  }

  static Set<String> get activeMessageIds {
    if (_messageBox == null) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Message box not initialized, returning empty activeMessageIds');
      return <String>{};
    }
    return Set<String>.from(_messageBox!.get('activeMessageIds', defaultValue: <String>[]));
  }

  static Future<void> saveActiveMessageIds() async {
    if (_messageBox == null) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Message box not initialized, cannot save activeMessageIds');
      return;
    }
    await _messageBox!.put('activeMessageIds', activeMessageIds.toList());
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Saved activeMessageIds: ${activeMessageIds}');
  }

  static Future<void> startPolling(BuildContext context) async {
    if (_pollTimer != null && _pollTimer!.isActive) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Polling already active, skipping');
      return;
    }
    if (!AuthState.isAuthenticated || AuthState.userId == null) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Cannot start polling, user not authenticated');
      return;
    }
    final localContext = context;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!localContext.mounted) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Context is not mounted, stopping polling');
        timer.cancel();
        return;
      }
      try {
        final response = await HttpService.get('chat.php', query: {'action': 'poll_notifications'});
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Polling response: ${response.body}');
          if (data['status'] == 'success' && data['notifications'] != null) {
            for (var notification in data['notifications']) {
              if (localContext.mounted) {
                await _handleNotification(notification, localContext);
              } else {
                debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Context is not mounted, skipping notification handling');
              }
            }
          }
        } else {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Polling failed with status: ${response.statusCode}, body: ${response.body}');
        }
      } catch (e, stackTrace) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Polling error: $e\nStackTrace: $stackTrace');
      }
    });
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Started polling for notifications');
  }

  static Future<void> _handleNotification(Map<String, dynamic> notification, BuildContext context) async {
    final chatId = int.tryParse(notification['chat_id'].toString()) ?? 0;
    final notificationType = notification['type']?.toString() ?? '';
    final senderName = notification['sender_name']?.toString() ?? 'Unknown';
    final messageId = notification['message_id']?.toString() ?? '';
    final messageContent = notification['message']?.toString() ?? 'New message received';
    final chatName = notification['chat_name']?.toString() ?? 'Chat';
    final isGroup = notification['is_group']?.toString() == '1';

    if (notificationType != 'message' || chatId == 0 || messageId.isEmpty) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Invalid notification data: type=$notificationType, chatId=$chatId, messageId=$messageId');
      return;
    }

    if (activeMessageIds.contains(messageId)) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Message notification already shown for messageId=$messageId');
      return;
    }
    activeMessageIds.add(messageId);
    await saveActiveMessageIds();

    try {
      final payload = jsonEncode({
        'chatId': chatId.toString(),
        'chatName': chatName,
        'isGroup': isGroup,
        'userId': AuthState.userId?.toString() ?? '',
        'type': 'message',
        'messageId': messageId,
      });

      await flutterLocalNotificationsPlugin.show(
        chatId,
        'New Message from $senderName',
        messageContent,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'message_notifications',
            'Message Notifications',
            channelDescription: 'Notifications for new messages',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: const RawResourceAndroidNotificationSound('notification_sound'),
            color: const Color(0xFFFF6200),
            autoCancel: true,
            ongoing: false,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            sound: 'notification_sound.mp3',
          ),
        ),
        payload: payload,
      );
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Showed message notification: chatId=$chatId, messageId=$messageId, sender=$senderName');
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Error showing message notification: $e\nStackTrace: $stackTrace');
      activeMessageIds.remove(messageId);
      await saveActiveMessageIds();
    }
  }

  static Future<void> stopPolling() async {
    _pollTimer?.cancel();
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Stopped polling for notifications');
  }

  static Future<void> handleNotificationResponse(NotificationResponse response) async {
    if (response.payload == null) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Notification response with null payload');
      return;
    }

    try {
      final payload = jsonDecode(response.payload!);
      final context = navigatorKey.currentContext;
      if (context == null || !context.mounted || _isNavigating) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Cannot handle notification response: context=$context, mounted=${context?.mounted}, isNavigating=$_isNavigating');
        return;
      }

      if (payload['type'] == 'message') {
        final chatId = int.tryParse(payload['chatId']?.toString() ?? '0') ?? 0;
        final messageId = payload['messageId']?.toString() ?? '';
        if (chatId == 0 || !activeMessageIds.contains(messageId)) {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Invalid chatId=$chatId or inactive messageId=$messageId');
          await flutterLocalNotificationsPlugin.cancel(chatId);
          return;
        }

        _isNavigating = true;
        try {
          final response = await HttpService.get('user.php', query: {'action': 'verify_session'});
          if (response.statusCode != 200 || jsonDecode(response.body)['status'] != 'success') {
            debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Invalid session for notification, redirecting to login');
            activeMessageIds.remove(messageId);
            await saveActiveMessageIds();
            await flutterLocalNotificationsPlugin.cancel(chatId);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Session expired. Please log in again.',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
            await Navigator.pushReplacementNamed(context, '/auth');
            return;
          }

          await Navigator.pushNamed(
            context,
            '/chat',
            arguments: {
              'chatId': chatId,
              'chatName': payload['chatName'] ?? 'Chat',
              'isGroup': payload['isGroup'] ?? false,
              'userId': int.tryParse(payload['userId']?.toString() ?? '0') ?? 0,
            },
          );
          activeMessageIds.remove(messageId);
          await saveActiveMessageIds();
          await flutterLocalNotificationsPlugin.cancel(chatId);
        } catch (e, stackTrace) {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Error navigating to ChatScreen: $e\nStackTrace: $stackTrace');
        } finally {
          _isNavigating = false;
        }
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Error handling notification response: $e\nStackTrace: $stackTrace');
    }
  }
}

// AuthState
class AuthState {
  static bool _isAuthenticated = false;
  static String? _sessionId;
  static int? _userId;
  static String? _username;
  static String? _email;
  static String? _phoneNumber;
  static bool _twoStepEnabled = false;

  static Future<void> initialize() async {
    try {
      final authBox = await Hive.openBox('authBox');
      _sessionId = authBox.get('session_id') as String?;
      _userId = authBox.get('user_id') as int?;
      _username = authBox.get('username') as String?;
      _email = authBox.get('email') as String?;
      _phoneNumber = authBox.get('phone_number') as String?;
      _twoStepEnabled = authBox.get('two_step_enabled') as bool? ?? false;
      _isAuthenticated = _sessionId != null && _sessionId!.isNotEmpty && _userId != null;
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState initialized - isAuthenticated: $_isAuthenticated, sessionId: $_sessionId, userId: $_userId, username: $_username, email: $_email, phoneNumber: $_phoneNumber, twoStepEnabled: $_twoStepEnabled');
      if (_isAuthenticated) {
        final response = await HttpService.get('user.php', query: {'action': 'verify_session'});
        if (response.statusCode != 200 || jsonDecode(response.body)['status'] != 'success') {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session verification failed, logging out. Response: ${response.body}');
          await logout();
        }
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState initialization error: $e\nStackTrace: $stackTrace');
      await logout();
    }
  }

  static Future<void> login({
    required String sessionId,
    required int userId,
    required String username,
    required String email,
    String? phoneNumber,
    bool twoStepEnabled = false,
  }) async {
    try {
      final authBox = await Hive.openBox('authBox');
      final secureStorage = const FlutterSecureStorage();
      await authBox.putAll({
        'session_id': sessionId,
        'user_id': userId,
        'username': username,
        'email': email,
        'phone_number': phoneNumber,
        'two_step_enabled': twoStepEnabled,
      });
      await secureStorage.write(key: 'session_id', value: sessionId);
      await secureStorage.write(key: 'user_id', value: userId.toString());
      await secureStorage.write(key: 'email', value: email);
      await secureStorage.write(key: 'phone_number', value: phoneNumber);
      _sessionId = sessionId;
      _userId = userId;
      _username = username;
      _email = email;
      _phoneNumber = phoneNumber;
      _twoStepEnabled = twoStepEnabled;
      _isAuthenticated = true;
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState login - sessionId: $_sessionId, userId: $_userId, username: $_username, email: $_email, phoneNumber: $_phoneNumber, twoStepEnabled: $_twoStepEnabled');
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState login error: $e\nStackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<bool> refreshSession() async {
    try {
      final response = await HttpService.post('auth.php?action=refresh_session', body: {
        'session_id': _sessionId,
        'email': _email,
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && data['session_id'] != null) {
          await login(
            sessionId: data['session_id'],
            userId: data['user_id'] is String ? int.parse(data['user_id']) : data['user_id'],
            username: data['username'] ?? _username ?? '',
            email: _email ?? '',
            phoneNumber: _phoneNumber,
            twoStepEnabled: data['two_step_enabled'] ?? _twoStepEnabled,
          );
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session refreshed successfully');
          return true;
        }
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session refresh failed: ${data['message']}');
        await logout();
        return false;
      }
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session refresh failed with status: ${response.statusCode}');
      await logout();
      return false;
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Session refresh error: $e\nStackTrace: $stackTrace');
      await logout();
      return false;
    }
  }

  static Future<void> logout() async {
    try {
      final authBox = await Hive.openBox('authBox');
      await authBox.clear();
      _sessionId = null;
      _userId = null;
      _username = null;
      _email = null;
      _phoneNumber = null;
      _twoStepEnabled = false;
      _isAuthenticated = false;
      await NotificationService.stopPolling();
      await Workmanager().cancelAll();
      await flutterLocalNotificationsPlugin.cancelAll();
      final secureBox = await Hive.openBox('secure');
      await secureBox.clear();
      final messageBox = await Hive.openBox('messageBox');
      await messageBox.clear();
      await FlutterSecureStorage().deleteAll();
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Logged out, cleared authBox, secureBox, messageBox, secureStorage');
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Logout error: $e\nStackTrace: $stackTrace');
    }
  }

  static bool get isAuthenticated => _isAuthenticated;
  static String? get sessionId => _sessionId;
  static int? get userId => _userId;
  static String? get username => _username;
  static String? get email => _email;
  static String? get phoneNumber => _phoneNumber;
  static bool get twoStepEnabled => _twoStepEnabled;
}

// AuthService
class AuthService {
  static final _secureStorage = const FlutterSecureStorage();

  static Future<bool> signup({
    required String email,
    required String password,
    required String username,
    required String phoneNumber,
    required BuildContext context,
  }) async {
    try {
      final response = await HttpService.post(
        'auth.php?action=signup',
        body: {
          'email': email,
          'password': password,
          'username': username,
          'mobile_number': phoneNumber,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          await AuthState.login(
            sessionId: data['session_id'],
            userId: int.parse(data['user_id']),
            username: username,
            email: email,
            phoneNumber: phoneNumber,
            twoStepEnabled: data['two_step_enabled'] ?? false,
          );
          await _secureStorage.write(key: 'user_id', value: data['user_id']);
          await _secureStorage.write(key: 'email', value: email);
          await _secureStorage.write(key: 'phone_number', value: phoneNumber);
          await _secureStorage.write(key: 'session_id', value: data['session_id']);
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Server registration successful, session_id: ${data['session_id']}, phone_number: $phoneNumber');
          return true;
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  data['message'] ?? 'Registration failed',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Registration failed: ${data['message']}');
          return false;
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Server error: ${response.statusCode} - ${response.body}',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Server error: ${response.statusCode}, body: ${response.body}');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Signup error: $e\nStackTrace: $stackTrace');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Signup failed: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return false;
    }
  }

  static Future<bool> login({
    required String email,
    required String password,
    required BuildContext context,
  }) async {
    try {
      final response = await HttpService.post(
        'auth.php?action=login',
        body: {
          'email': email,
          'password': password,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          int userId;
          if (data['user_id'] is String) {
            userId = int.parse(data['user_id']);
          } else if (data['user_id'] is int) {
            userId = data['user_id'];
          } else {
            throw Exception('Invalid user_id type: ${data['user_id'].runtimeType}');
          }

          await AuthState.login(
            sessionId: data['session_id'],
            userId: userId,
            username: data['username'] ?? '',
            email: email,
            phoneNumber: data['phone_number'],
            twoStepEnabled: data['two_step_enabled'] ?? false,
          );
          await _secureStorage.write(key: 'user_id', value: data['user_id'].toString());
          await _secureStorage.write(key: 'email', value: email);
          await _secureStorage.write(key: 'phone_number', value: data['phone_number']);
          await _secureStorage.write(key: 'session_id', value: data['session_id']);
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Server login successful, session_id: ${data['session_id']}');
          return true;
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  data['message'] ?? 'Login failed',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Login failed: ${data['message']}');
          return false;
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Server error: ${response.statusCode} - ${response.body}',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Server error: ${response.statusCode}, body: ${response.body}');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Login error: $e\nStackTrace: $stackTrace');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Login failed: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return false;
    }
  }
}

void main() async {
  debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: App starting');
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final dir = await getApplicationDocumentsDirectory();
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Hive storage path: ${dir.path}');
    await Hive.initFlutter(dir.path);
    await Future.wait([
      Hive.openBox('authBox'),
      Hive.openBox('nicknames'),
      Hive.openBox('settings'),
      Hive.openBox('secure'),
      Hive.openBox('messageBox'),
    ]);
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Hive boxes opened');
  } catch (e, stackTrace) {
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Hive initialization error: $e\nStackTrace: $stackTrace');
    return;
  }

  try {
    await NotificationService.initialize();
    const androidInitSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInitSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInitSettings, iOS: iosInitSettings);
    await flutterLocalNotificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: NotificationService.handleNotificationResponse,
    );
  } catch (e, stackTrace) {
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Notification initialization error: $e\nStackTrace: $stackTrace');
  }

  if (Platform.isAndroid) {
    try {
      await _batteryChannel.invokeMethod('requestBatteryOptimizationExemption');
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Requested battery optimization exemption');
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Error requesting battery optimization exemption: $e\nStackTrace: $stackTrace');
    }
  }

  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: true);
    await Workmanager().registerPeriodicTask(
      'notification_polling_task',
      'pollNotifications',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      initialDelay: const Duration(seconds: 10),
    );
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager initialized and notification polling task scheduled');
  } catch (e, stackTrace) {
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager initialization error: $e\nStackTrace: $stackTrace');
  }

  try {
    await AuthState.initialize();
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState initialized');
  } catch (e, stackTrace) {
    debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: AuthState initialization error: $e\nStackTrace: $stackTrace');
  }

  runApp(const MyApp());
}

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == 'sendScheduledMessage') {
      try {
        final response = await HttpService.post('chat.php?action=send_message', body: inputData);
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task executed, response: ${response.body}');
        return response.statusCode == 200;
      } catch (e, stackTrace) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task error: $e\nStackTrace: $stackTrace');
        return false;
      }
    } else if (task == 'pollNotifications') {
      try {
        final authBox = await Hive.openBox('authBox');
        final sessionId = authBox.get('session_id') as String?;
        final userId = authBox.get('user_id') as int?;
        if (sessionId == null || userId == null) {
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task: No session or user ID, skipping');
          return false;
        }
        final response = await HttpService.get('chat.php', query: {'action': 'poll_notifications'});
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task: Polling response: ${response.body}');
          if (data['status'] == 'success' && data['notifications'] != null) {
            final messageBox = await Hive.openBox('messageBox');
            final activeMessageIds = Set<String>.from(messageBox.get('activeMessageIds', defaultValue: <String>[]));
            for (var notification in data['notifications']) {
              final messageId = notification['message_id']?.toString() ?? '';
              if (notification['type'] != 'message' || messageId.isEmpty || activeMessageIds.contains(messageId)) {
                continue;
              }
              activeMessageIds.add(messageId);
              final chatId = int.tryParse(notification['chat_id'].toString()) ?? 0;
              final senderName = notification['sender_name']?.toString() ?? 'Unknown';
              final messageContent = notification['message']?.toString() ?? 'New message received';
              final chatName = notification['chat_name']?.toString() ?? 'Chat';
              final isGroup = notification['is_group']?.toString() == '1';
              final payload = jsonEncode({
                'chatId': chatId.toString(),
                'chatName': chatName,
                'isGroup': isGroup,
                'userId': userId.toString(),
                'type': 'message',
                'messageId': messageId,
              });
              await flutterLocalNotificationsPlugin.show(
                chatId,
                'New Message from $senderName',
                messageContent,
                NotificationDetails(
                  android: AndroidNotificationDetails(
                    'message_notifications',
                    'Message Notifications',
                    channelDescription: 'Notifications for new messages',
                    importance: Importance.high,
                    priority: Priority.high,
                    playSound: true,
                    sound: const RawResourceAndroidNotificationSound('notification_sound'),
                    color: const Color(0xFFFF6200),
                    autoCancel: true,
                    ongoing: false,
                  ),
                  iOS: const DarwinNotificationDetails(
                    presentAlert: true,
                    presentSound: true,
                    sound: 'notification_sound.mp3',
                  ),
                ),
                payload: payload,
              );
              debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task: Showed notification for messageId=$messageId');
            }
            await messageBox.put('activeMessageIds', activeMessageIds.toList());
          }
          return true;
        }
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task: Polling failed with status: ${response.statusCode}');
        return false;
      } catch (e, stackTrace) {
        debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Workmanager task $task error: $e\nStackTrace: $stackTrace');
        return false;
      }
    }
    return true;
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'ChatWave',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        textTheme: GoogleFonts.poppinsTextTheme(),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      initialRoute: AuthState.isAuthenticated ? '/dashboard' : '/auth',
      routes: {
        '/auth': (context) => const AuthScreen(),
        '/chat_list': (context) => const ChatListScreen(),
        '/new_chat': (context) => const NewChatScreen(),
        '/chat': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
          if (args == null ||
              args['chatId'] == null ||
              args['chatName'] == null ||
              args['isGroup'] == null ||
              args['userId'] == null) {
            debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Missing required arguments for ChatScreen');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Error: Invalid chat data',
                      style: GoogleFonts.poppins(color: Colors.white),
                    ),
                    backgroundColor: Colors.redAccent,
                  ),
                );
                Navigator.pushReplacementNamed(context, '/dashboard');
              }
            });
            return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFFFF6200))));
          }
          return ChatScreen(
            chatId: args['chatId'] as int,
            chatName: args['chatName'] as String,
            isGroup: args['isGroup'] as bool,
            userId: args['userId'] as int,
          );
        },
        '/two_step': (context) => const TwoStepVerificationScreen(),
        '/dashboard': (context) => const DashboardScreen(),
        '/privacy': (context) => const PrivacyScreen(),
      },
      debugShowCheckedModeBanner: false,
    );
  }
}

// TwoStepVerificationScreen
class TwoStepVerificationScreen extends StatefulWidget {
  const TwoStepVerificationScreen({super.key});

  @override
  State<TwoStepVerificationScreen> createState() => _TwoStepVerificationScreenState();
}

class _TwoStepVerificationScreenState extends State<TwoStepVerificationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  bool _isLoading = false;
  Timer? _timer;
  int _remainingTime = 60;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    if (!AuthState.isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushReplacementNamed(context, '/auth');
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _remainingTime = 60;
    _canResend = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remainingTime--;
        if (_remainingTime <= 0) {
          _canResend = true;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _resendCode() async {
    if (_isLoading || !_canResend) return;
    setState(() => _isLoading = true);
    try {
      final response = await HttpService.post('auth.php?action=send_verification_code', body: {
        'user_id': AuthState.userId,
        'email': AuthState.email,
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Code resent successfully!',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.green,
            ),
          );
          _startTimer();
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Failed to resend code',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Server error: ${response.statusCode} - ${response.body}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Resend code error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_isLoading || !_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      final response = await HttpService.post('auth.php?action=verify_two_step_code', body: {
        'user_id': AuthState.userId,
        'code': _codeController.text.trim(),
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          await AuthState.login(
            sessionId: data['session_id'] ?? AuthState.sessionId!,
            userId: AuthState.userId!,
            username: AuthState.username ?? '',
            email: AuthState.email ?? '',
            phoneNumber: AuthState.phoneNumber,
            twoStepEnabled: true,
          );
          if (mounted) {
            NotificationService.startPolling(context);
            Navigator.pushReplacementNamed(context, '/dashboard');
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Invalid code',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Server error: ${response.statusCode} - ${response.body}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG [${DateTime.now().toIso8601String()}]: Verify code error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: GlassmorphicContainer(
              width: double.infinity,
              height: double.infinity,
              borderRadius: 0,
              blur: 20,
              alignment: Alignment.center,
              border: 2,
              linearGradient: LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.1),
                  Colors.white.withOpacity(0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderGradient: LinearGradient(
                colors: [
                  const Color(0xFFFF6200).withOpacity(0.3),
                  Colors.transparent,
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 50),
                    FadeInDown(
                      child: Text(
                        'Two-Step Verification',
                        style: GoogleFonts.poppins(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeInUp(
                      child: Text(
                        'Enter the 6-digit code sent to ${AuthState.email ?? 'your email'}',
                        style: GoogleFonts.poppins(fontSize: 16, color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 30),
                    Form(
                      key: _formKey,
                      child: FadeInUp(
                        delay: const Duration(milliseconds: 200),
                        child: GlassmorphicContainer(
                          width: double.infinity,
                          height: 60,
                          borderRadius: 12,
                          blur: 20,
                          alignment: Alignment.center,
                          border: 2,
                          linearGradient: LinearGradient(
                            colors: [
                              Colors.white.withOpacity(0.1),
                              Colors.white.withOpacity(0.05),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderGradient: LinearGradient(
                            colors: [
                              const Color(0xFFFF6200).withOpacity(0.3),
                              Colors.transparent,
                            ],
                          ),
                          child: TextFormField(
                            controller: _codeController,
                            keyboardType: TextInputType.number,
                            style: GoogleFonts.poppins(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Verification Code',
                              labelStyle: GoogleFonts.poppins(color: Colors.white70),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                            ),
                            validator: (value) {
                              if (value == null || value.length != 6 || !RegExp(r'^\d{6}$').hasMatch(value)) {
                                return 'Enter a valid 6-digit code';
                              }
                              return null;
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeInUp(
                      delay: const Duration(milliseconds: 300),
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _verifyCode,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6200),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SpinKitCircle(color: Colors.white, size: 24)
                            : Text(
                                'Verify',
                                style: GoogleFonts.poppins(fontSize: 16, color: Colors.white),
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeInUp(
                      delay: const Duration(milliseconds: 400),
                      child: TextButton(
                        onPressed: _canResend ? _resendCode : null,
                        child: Text(
                          _canResend ? 'Resend Code' : 'Resend in $_remainingTime seconds',
                          style: GoogleFonts.poppins(
                            color: _canResend ? const Color(0xFFFF6200) : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// AuthScreen
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameController = TextEditingController();
  String _phoneNumber = '';
  bool _isLogin = true;
  bool _isLoading = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading || !_formKey.currentState!.validate()) return;

    if (!_isLogin && _phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Phone number is required for registration',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      bool success;
      if (_isLogin) {
        success = await AuthService.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          context: context,
        );
        if (success && mounted) {
          if (AuthState.twoStepEnabled) {
            Navigator.pushNamed(context, '/two_step');
          } else {
            NotificationService.startPolling(context);
            Navigator.pushReplacementNamed(context, '/dashboard');
          }
        }
      } else {
        success = await AuthService.signup(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          username: _usernameController.text.trim(),
          phoneNumber: _phoneNumber,
          context: context,
        );
        if (success && mounted) {
          NotificationService.startPolling(context);
          Navigator.pushReplacementNamed(context, '/dashboard');
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: GlassmorphicContainer(
              width: double.infinity,
              height: double.infinity,
              borderRadius: 0,
              blur: 20,
              alignment: Alignment.center,
              border: 2,
              linearGradient: LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.1),
                  Colors.white.withOpacity(0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderGradient: LinearGradient(
                colors: [
                  const Color(0xFFFF6200).withOpacity(0.3),
                  Colors.transparent,
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 50),
                    FadeInDown(
                      child: Text(
                        _isLogin ? 'Welcome Back!' : 'Create Account',
                        style: GoogleFonts.poppins(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          if (!_isLogin) ...[
                            FadeInUp(
                              delay: const Duration(milliseconds: 200),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 60,
                                borderRadius: 12,
                                blur: 20,
                                alignment: Alignment.center,
                                border: 2,
                                linearGradient: LinearGradient(
                                  colors: [
                                    Colors.white.withOpacity(0.1),
                                    Colors.white.withOpacity(0.05),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderGradient: LinearGradient(
                                  colors: [
                                    const Color(0xFFFF6200).withOpacity(0.3),
                                    Colors.transparent,
                                  ],
                                ),
                                child: TextFormField(
                                  controller: _usernameController,
                                  style: GoogleFonts.poppins(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'Username',
                                    labelStyle: GoogleFonts.poppins(color: Colors.white70),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                                  ),
                                  validator: (value) {
                                    if (value == null || value.isEmpty) {
                                      return 'Enter a username';
                                    }
                                    if (!RegExp(r'^[a-zA-Z0-9]{3,50}$').hasMatch(value)) {
                                      return 'Username must be 3-50 alphanumeric characters';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            FadeInUp(
                              delay: const Duration(milliseconds: 250),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 80,
                                borderRadius: 12,
                                blur: 20,
                                alignment: Alignment.center,
                                border: 2,
                                linearGradient: LinearGradient(
                                  colors: [
                                    Colors.white.withOpacity(0.1),
                                    Colors.white.withOpacity(0.05),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderGradient: LinearGradient(
                                  colors: [
                                    const Color(0xFFFF6200).withOpacity(0.3),
                                    Colors.transparent,
                                  ],
                                ),
                                child: IntlPhoneField(
                                  decoration: InputDecoration(
                                    labelText: 'Phone Number',
                                    labelStyle: GoogleFonts.poppins(color: Colors.white70),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                                  ),
                                  style: GoogleFonts.poppins(color: Colors.white),
                                  initialCountryCode: 'US',
                                  onChanged: (phone) {
                                    setState(() {
                                      _phoneNumber = phone.completeNumber;
                                    });
                                  },
                                  validator: (phone) {
                                    if (phone == null || phone.completeNumber.isEmpty) {
                                      return 'Enter a valid phone number';
                                    }
                                    if (!RegExp(r'^\+[0-9]{1,14}$').hasMatch(phone.completeNumber)) {
                                      return 'Invalid phone number format';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],
                          FadeInUp(
                            delay: const Duration(milliseconds: 300),
                            child: GlassmorphicContainer(
                              width: double.infinity,
                              height: 60,
                              borderRadius: 12,
                              blur: 20,
                              alignment: Alignment.center,
                              border: 2,
                              linearGradient: LinearGradient(
                                colors: [
                                  Colors.white.withOpacity(0.1),
                                  Colors.white.withOpacity(0.05),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderGradient: LinearGradient(
                                colors: [
                                  const Color(0xFFFF6200).withOpacity(0.3),
                                  Colors.transparent,
                                ],
                              ),
                              child: TextFormField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                style: GoogleFonts.poppins(color: Colors.white),
                                decoration: InputDecoration(
                                  labelText: 'Email',
                                  labelStyle: GoogleFonts.poppins(color: Colors.white70),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                                ),
                                validator: (value) {
                                  if (value == null || !RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                                    return 'Enter a valid email';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          FadeInUp(
                            delay: const Duration(milliseconds: 400),
                            child: GlassmorphicContainer(
                              width: double.infinity,
                              height: 60,
                              borderRadius: 12,
                              blur: 20,
                              alignment: Alignment.center,
                              border: 2,
                              linearGradient: LinearGradient(
                                colors: [
                                  Colors.white.withOpacity(0.1),
                                  Colors.white.withOpacity(0.05),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderGradient: LinearGradient(
                                colors: [
                                  const Color(0xFFFF6200).withOpacity(0.3),
                                  Colors.transparent,
                                ],
                              ),
                              child: TextFormField(
                                controller: _passwordController,
                                obscureText: !_showPassword,
                                style: GoogleFonts.poppins(color: Colors.white),
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  labelStyle: GoogleFonts.poppins(color: Colors.white70),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showPassword ? Icons.visibility : Icons.visibility_off,
                                      color: Colors.white70,
                                    ),
                                    onPressed: () {
                                      setState(() => _showPassword = !_showPassword);
                                    },
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.length < 8) {
                                    return 'Password must be at least 8 characters';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          FadeInUp(
                            delay: const Duration(milliseconds: 600),
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF6200),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _isLoading
                                  ? const SpinKitCircle(color: Colors.white, size: 24)
                                  : Text(
                                      _isLogin ? 'Login' : 'Register',
                                      style: GoogleFonts.poppins(fontSize: 16, color: Colors.white),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeInUp(
                      delay: const Duration(milliseconds: 700),
                      child: TextButton(
                        onPressed: () {
                          setState(() {
                            _isLogin = !_isLogin;
                            _emailController.clear();
                            _passwordController.clear();
                            _usernameController.clear();
                            _phoneNumber = '';
                          });
                        },
                        child: Text(
                          _isLogin ? 'Need an account? Register' : 'Have an account? Login',
                          style: GoogleFonts.poppins(color: const Color(0xFFFF6200)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeInUp(
                      delay: const Duration(milliseconds: 800),
                      child: Text.rich(
                        TextSpan(
                          text: 'By continuing, you agree to our ',
                          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
                          children: [
                            TextSpan(
                              text: 'Privacy Policy',
                              style: GoogleFonts.poppins(color: const Color(0xFFFF6200), fontSize: 12),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () async {
                                  const url = 'https://docs.google.com/document/d/1QKyk-9qdeY4m-9Ob_Nnrmq-3_u_NGf5XmicZwV5w0Qg/edit?usp=sharing';
                                  if (await canLaunchUrl(Uri.parse(url))) {
                                    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  } else {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Could not open Privacy Policy',
                                            style: GoogleFonts.poppins(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.redAccent,
                                        ),
                                      );
                                    }
                                  }
                                },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}