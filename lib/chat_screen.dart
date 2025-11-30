import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:bubble/bubble.dart';
import 'package:camera/camera.dart';
import 'package:chewie/chewie.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:geolocator/geolocator.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:synchronized/synchronized.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import 'TranslationService.dart';
import 'main.dart';

extension NullableExtension<T> on T? {
  R? let<R>(R Function(T) block) => this != null ? block(this!) : null;
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static final List<String> activeCallUUIDs = [];
  static Future<void> saveActiveCallUUIDs() async {
    final box = await Hive.openBox('call_uuids');
    await box.put('active_call_uuids', activeCallUUIDs);
  }

  static Future<void> initialize() async {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Initializing NotificationService');
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);
    await _requestNotificationPermissions();
  }

  static Future<void> _requestNotificationPermissions() async {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Requesting notification permissions');
    if (Platform.isAndroid) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  static Future<void> sendBackgroundNotification({
    required String title,
    required String body,
    required int chatId,
    String? recipientId,
  }) async {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Sending background notification for chatId: $chatId');
    try {
      const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'chat_channel',
        'Chat Notifications',
        channelDescription: 'Notifications for new chat messages',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
      );
      const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
      
      await _notificationsPlugin.show(
        chatId,
        title,
        body,
        platformChannelSpecifics,
        payload: 'chat_$chatId',
      );
      print('DEBUG [${DateTime.now().toIso8601String()}]: Notification sent successfully for chatId: $chatId');
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Notification error: $e\nStackTrace: $stackTrace');
    }
  }
}

class ChatScreen extends StatefulWidget {
  final int chatId;
  final String chatName;
  final bool isGroup;
  final int userId;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.chatName,
    required this.isGroup,
    required this.userId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _messageTimer;
  Timer? _typingTimer;
  bool _isTyping = false;
  List<dynamic> _typingUsers = [];
  File? _selectedMedia;
  String? _recordedAudioPath;
  String? _recordedVideoPath;
  int? _otherUserId;
  String? _otherUserName;
  final _record = AudioRecorder();
  bool _isRecording = false;
  bool _isRecordingVideo = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  final _audioPlayer = AudioPlayer();
  String? _playingMessageId;
  Duration _voiceDuration = Duration.zero;
  bool _isActive = true;
  bool _isBlocked = false;
  final Map<String, ChewieController> _videoControllers = {};
  double _uploadProgress = 0.0;
  final Map<String, Duration> _voiceNoteDurations = {};
  String _chatName = '';
  String? _nickname;
  final TranslationService _translationService = TranslationService();
  final Map<String, String> _translatedMessages = {};
  int _retryCount = 0;
  static const int _maxRetries = 3;
  final Map<String, String> _messageIdMapping = {};
  bool _isRenderingMessages = false;
  final Queue<Future<void> Function()> _pendingOperations = Queue();
  Timer? _debounceTimer;
  final _lock = Lock();
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];

  @override
  void initState() {
    super.initState();
    print('DEBUG [${DateTime.now().toIso8601String()}]: ChatScreen initState, chatId: ${widget.chatId}, userId: ${widget.userId}');
    _chatName = widget.chatName;
    if (widget.userId == 0) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Invalid userId, redirecting to auth');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/auth');
      });
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _initMessages();
    _checkBlockStatus();
    _fetchParticipants();
    _addPendingOperation(_fetchNickname);
    _addPendingOperation(() async {
      _startMessagePolling();
      _startTypingPolling();
    });
    _messageController.addListener(_onTyping);
  }

  Future<void> _requestPermissions() async {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Requesting permissions sequentially');
    try {
      final permissions = [
        Permission.microphone,
        Permission.camera,
        Permission.storage,
        Permission.location,
        Permission.notification,
      ];

      bool allGranted = true;
      for (var permission in permissions) {
        var status = await permission.status;
        print('DEBUG [${DateTime.now().toIso8601String()}]: Checking $permission, status: $status');
        if (!status.isGranted) {
          status = await permission.request();
          print('DEBUG [${DateTime.now().toIso8601String()}]: Requested $permission, result: $status');
          if (!status.isGranted) {
            allGranted = false;
            if (permission == Permission.camera && status.isPermanentlyDenied && mounted) {
              await openAppSettings();
              if (mounted) {
                final newStatus = await Permission.camera.status;
                print('DEBUG [${DateTime.now().toIso8601String()}]: Camera permission after settings: $newStatus');
              }
            }
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (!allGranted && mounted) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Some permissions were denied');
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: All permissions granted or already granted');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Permission request error: $e\nStackTrace: $stackTrace');
    }
  }
  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? const Color(0xFF121212) : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black;
    final iconColor = isDarkMode ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.grey[300],
              child: Text(
                _chatName.isNotEmpty ? _chatName[0].toUpperCase() : 'C',
                style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _chatName,
                    style: GoogleFonts.poppins(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_typingUsers.isNotEmpty)
                    Text(
                      widget.isGroup
                          ? '${_typingUsers.length} typing...'
                          : '${_typingUsers.isNotEmpty ? _typingUsers[0]['username'] ?? 'Someone' : 'Someone'} is typing...',
                      style: GoogleFonts.poppins(
                        color: const Color(0xFFFF6200),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: iconColor),
            onSelected: (value) async {
              if (value == 'block' && !widget.isGroup && mounted) {
                try {
                  final response = await HttpService.post(
                    'chat.php?action=block_user',
                    body: {'chat_id': widget.chatId.toString()},
                  ).timeout(const Duration(seconds: 5));
                  print('DEBUG [${DateTime.now().toIso8601String()}]: block_user response: ${response.statusCode}, body: ${response.body}');
                  if (response.statusCode == 200 && mounted) {
                    setState(() => _isBlocked = true);
                  }
                } catch (e, stackTrace) {
                  print('DEBUG [${DateTime.now().toIso8601String()}]: Block user error: $e\nStackTrace: $stackTrace');
                }
              }
            },
            itemBuilder: (context) => [
              if (!widget.isGroup)
                PopupMenuItem<String>(
                  value: 'block',
                  child: Text(
                    _isBlocked ? 'Unblock User' : 'Block User',
                    style: GoogleFonts.poppins(color: textColor),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && _isLoading
                ? Center(
                    child: SpinKitFadingCircle(
                      color: const Color.fromARGB(255, 85, 73, 66),
                      size: 50.0,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8.0),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message['sender_id'] == widget.userId;
                      final messageId = message['id'].toString();
                      final content = _translatedMessages.containsKey(messageId)
                          ? _translatedMessages[messageId]!
                          : message['content']?.toString() ?? '';
                      final mediaUrl = message['media_url']?.toString() ?? '';
                      final isVoice = message['type'] == 'voice';
                      final isImage = message['type'] == 'image' || message['type'] == 'gif';
                      final isVideo = message['type'] == 'video';
                      final isLocation = message['type'] == 'location';
                      final isDocument = message['type'] == 'document';

                      if (!_videoControllers.containsKey(messageId) && isVideo && mediaUrl.isNotEmpty) {
                        try {
                          final videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(mediaUrl));
                          _videoControllers[messageId] = ChewieController(
                            videoPlayerController: videoPlayerController,
                            autoInitialize: true,
                            looping: false,
                            aspectRatio: 16 / 9,
                            errorBuilder: (context, errorMessage) => Center(
                              child: Text(
                                'Error loading video',
                                style: GoogleFonts.poppins(color: Colors.redAccent),
                              ),
                            ),
                          );
                          videoPlayerController.initialize().then((_) {
                            if (mounted) {
                              setState(() {
                                final videoAspectRatio = videoPlayerController.value.aspectRatio;
                                _videoControllers[messageId] = ChewieController(
                                  videoPlayerController: _videoControllers[messageId]!.videoPlayerController,
                                  autoInitialize: true,
                                  looping: false,
                                  aspectRatio: videoAspectRatio ?? 16 / 9,
                                  errorBuilder: (context, errorMessage) => Center(
                                    child: Text(
                                      'Error loading video',
                                      style: GoogleFonts.poppins(color: Colors.redAccent),
                                    ),
                                  ),
                                );
                              });
                            }
                          }).catchError((e, stackTrace) {
                            print('DEBUG [${DateTime.now().toIso8601String()}]: Error initializing video controller for $messageId: $e\nStackTrace: $stackTrace');
                          });
                        } catch (e, stackTrace) {
                          print('DEBUG [${DateTime.now().toIso8601String()}]: Error creating video controller for $messageId: $e\nStackTrace: $stackTrace');
                        }
                      }

                      return GestureDetector(
                        onLongPress: () {
                          if (isMe) {
                            _showMessageOptions(context, messageId, message);
                          }
                        },
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Bubble(
                              margin: BubbleEdges.only(
                                top: 10,
                                left: isMe ? 50 : 8,
                                right: isMe ? 8 : 50,
                              ),
                              alignment: isMe ? Alignment.topRight : Alignment.topLeft,
                              nip: isMe ? BubbleNip.rightTop : BubbleNip.leftTop,
                              color: isMe
                                  ? isDarkMode
                                      ? const Color(0xFF1E1E1E)
                                      : const Color(0xFFFF6200)
                                  : isDarkMode
                                      ? const Color(0xFF2A2A2A)
                                      : Colors.grey[200],
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.65,
                                ),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    if (widget.isGroup)
                                      Text(
                                        message['username']?.toString() ?? 'Unknown',
                                        style: GoogleFonts.poppins(
                                          fontSize: 12,
                                          color: isMe ? Colors.white70 : textColor,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    if (isImage && mediaUrl.isNotEmpty)
                                      GestureDetector(
                                        onTap: () {
                                          print('DEBUG [${DateTime.now().toIso8601String()}]: Viewing image: $mediaUrl');
                                          if (mounted) {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => Scaffold(
                                                  backgroundColor: Colors.black,
                                                  body: Center(
                                                    child: Image.network(
                                                      mediaUrl,
                                                      fit: BoxFit.contain,
                                                      errorBuilder: (context, error, stackTrace) => Text(
                                                        'Error loading image',
                                                        style: GoogleFonts.poppins(color: Colors.redAccent),
                                                      ),
                                                    ),
                                                  ),
                                                  appBar: AppBar(
                                                    backgroundColor: Colors.black,
                                                    leading: IconButton(
                                                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                                                      onPressed: () => Navigator.pop(context),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: MediaQuery.of(context).size.width * 0.5,
                                            maxHeight: 200,
                                          ),
                                          child: Image.network(
                                            mediaUrl,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) => Text(
                                              'Error loading image',
                                              style: GoogleFonts.poppins(color: Colors.redAccent),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (isVideo && mediaUrl.isNotEmpty && _videoControllers.containsKey(messageId))
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: MediaQuery.of(context).size.width * 0.6,
                                          maxHeight: 200,
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Chewie(
                                            controller: _videoControllers[messageId]!,
                                          ),
                                        ),
                                      ),
                                    if (isVoice && mediaUrl.isNotEmpty)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                              _playingMessageId == messageId ? Icons.pause : Icons.play_arrow,
                                              color: isMe ? Colors.white : iconColor,
                                            ),
                                            onPressed: () => _playVoiceNote(mediaUrl, messageId),
                                          ),
                                          Text(
                                            _voiceNoteDurations[messageId]?.inSeconds.toString() ?? '0',
                                            style: GoogleFonts.poppins(
                                              color: isMe ? Colors.white : textColor,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (_playingMessageId == messageId)
                                            Text(
                                              '${_voiceDuration.inSeconds}s',
                                              style: GoogleFonts.poppins(
                                                color: isMe ? Colors.white : textColor,
                                                fontSize: 12,
                                              ),
                                            ),
                                        ],
                                      ),
                                    if (isLocation && mediaUrl.isNotEmpty)
                                      GestureDetector(
                                        onTap: () => _viewLocation(mediaUrl),
                                        child: Text(
                                          'View Location',
                                          style: GoogleFonts.poppins(
                                            color: isMe ? Colors.white : const Color(0xFF1E90FF),
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ),
                                    if (isDocument && mediaUrl.isNotEmpty)
                                      GestureDetector(
                                        onTap: () async {
                                          print('DEBUG [${DateTime.now().toIso8601String()}]: Opening document: $mediaUrl');
                                          try {
                                            final uri = Uri.parse(mediaUrl);
                                            if (!await canLaunchUrl(uri)) {
                                              print('Cannot open document');
                                              return;
                                            }
                                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                                          } catch (e, stackTrace) {
                                            print('DEBUG [${DateTime.now().toIso8601String()}]: Open document error: $e\nStackTrace: $stackTrace');
                                          }
                                        },
                                        child: Text(
                                          'Open Document',
                                          style: GoogleFonts.poppins(
                                            color: isMe ? Colors.white : const Color(0xFF1E90FF),
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ),
                                    if (!isVoice && !isImage && !isVideo && !isLocation && !isDocument && content.isNotEmpty)
                                      Text(
                                        content,
                                        style: GoogleFonts.poppins(
                                          color: isMe ? Colors.white : textColor,
                                          fontSize: 14,
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      DateTime.parse(message['created_at']).toLocal().toString().substring(0, 16),
                                      style: GoogleFonts.poppins(
                                        color: isMe ? Colors.white70 : Colors.grey,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ).animate().fadeIn(duration: const Duration(milliseconds: 300)),
                            if (_translatedMessages.containsKey(messageId))
                              Padding(
                                padding: EdgeInsets.only(
                                  top: 4,
                                  left: isMe ? 50 : 8,
                                  right: isMe ? 8 : 50,
                                ),
                                child: Text(
                                  'Translated: ${_translatedMessages[messageId]}',
                                  style: GoogleFonts.poppins(
                                    color: isMe ? Colors.grey[400] : Colors.grey[600],
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            if (message['type'] == 'text' && content.isNotEmpty)
                              Align(
                                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                child: PopupMenuButton<String>(
                                  icon: Icon(Icons.translate, color: isMe ? Colors.white70 : iconColor, size: 16),
                                  onSelected: (languageCode) => _translateMessage(content, messageId, languageCode),
                                  itemBuilder: (context) => TranslationService.getSupportedLanguages()
                                      .map((lang) => PopupMenuItem<String>(
                                            value: lang,
                                            child: Text(
                                              _getLanguageName(lang),
                                              style: GoogleFonts.poppins(color: textColor),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _errorMessage!,
                style: GoogleFonts.poppins(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          GlassmorphicContainer(
            width: double.infinity,
            height: _isRecording || _isRecordingVideo ? 120 : 60,
            borderRadius: 0,
            blur: 20,
            alignment: Alignment.bottomCenter,
            border: 0,
            linearGradient: LinearGradient(
              colors: [
                isDarkMode ? Colors.black.withOpacity(0.3) : Colors.white.withOpacity(0.3),
                isDarkMode ? Colors.black.withOpacity(0.2) : Colors.white.withOpacity(0.2),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderGradient: LinearGradient(colors: [Colors.transparent, Colors.transparent]),
            child: Column(
              children: [
                if (_isRecording || _isRecordingVideo)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isRecording
                              ? 'Recording Audio: ${_recordingDuration.inSeconds}s'
                              : 'Recording Video: ${_recordingDuration.inSeconds}s',
                          style: GoogleFonts.poppins(color: textColor, fontSize: 14),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: () => _isRecording ? _stopRecording(false) : _stopVideoRecording(false),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6200)),
                          child: Text('Stop', style: GoogleFonts.poppins(color: Colors.white)),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: () => _isRecording ? _stopRecording(true) : _stopVideoRecording(true),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                          child: Text('Cancel', style: GoogleFonts.poppins(color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                if (!_isRecording && !_isRecordingVideo)
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.attach_file, color: iconColor),
                        onPressed: _isBlocked
                            ? null
                            : () => showModalBottomSheet(
                                  context: context,
                                  backgroundColor: backgroundColor,
                                  builder: (context) => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: Icon(Icons.image, color: iconColor),
                                        title: Text('Image', style: GoogleFonts.poppins(color: textColor)),
                                        onTap: () {
                                          Navigator.pop(context);
                                          _pickMedia('image');
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.videocam, color: iconColor),
                                        title: Text('Video', style: GoogleFonts.poppins(color: textColor)),
                                        onTap: () {
                                          Navigator.pop(context);
                                          _pickMedia('video');
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.video_call, color: iconColor),
                                        title: Text('Record Video', style: GoogleFonts.poppins(color: textColor)),
                                        onTap: () {
                                          Navigator.pop(context);
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.description, color: iconColor),
                                        title: Text('Document', style: GoogleFonts.poppins(color: textColor)),
                                        onTap: () {
                                          Navigator.pop(context);
                                          _pickMedia('document');
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.location_on, color: iconColor),
                                        title: Text('Location', style: GoogleFonts.poppins(color: textColor)),
                                        onTap: () {
                                          Navigator.pop(context);
                                          _sendLiveLocation();
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                      ),
                      IconButton(
                        icon: Icon(Icons.mic, color: _isBlocked ? Colors.grey : iconColor),
                        onPressed: _isBlocked ? null : _startRecording,
                      ),
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          enabled: !_isBlocked,
                          style: GoogleFonts.poppins(color: textColor),
                          decoration: InputDecoration(
                            hintText: _isBlocked ? 'Chat is blocked' : 'Type a message...',
                            hintStyle: GoogleFonts.poppins(color: isDarkMode ? Colors.white54 : Colors.black54),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _messageController.text.trim().isNotEmpty || _recordedAudioPath != null || _recordedVideoPath != null
                              ? Icons.send
                              : Icons.send,
                          color: _isBlocked
                              ? Colors.grey
                              : (_messageController.text.trim().isNotEmpty || _recordedAudioPath != null || _recordedVideoPath != null)
                                  ? const Color(0xFFFF6200)
                                  : iconColor,
                        ),
                        onPressed: _isBlocked
                            ? null
                            : () {
                                if (_recordedAudioPath != null || _recordedVideoPath != null) {
                                  _sendMessage();
                                } else if (_messageController.text.trim().isNotEmpty) {
                                  _sendMessage();
                                }
                              },
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getLanguageName(String languageCode) {
    // Map language codes to full names for display
    const languageNames = {
      'AR': 'Arabic',
      'BG': 'Bulgarian',
      'CS': 'Czech',
      'DA': 'Danish',
      'DE': 'German',
      'EL': 'Greek',
      'EN-GB': 'English (British)',
      'EN-US': 'English (American)',
      'ES': 'Spanish',
      'ET': 'Estonian',
      'FI': 'Finnish',
      'FR': 'French',
      'HU': 'Hungarian',
      'ID': 'Indonesian',
      'IT': 'Italian',
      'JA': 'Japanese',
      'KO': 'Korean',
      'LT': 'Lithuanian',
      'LV': 'Latvian',
      'NB': 'Norwegian Bokmål',
      'NL': 'Dutch',
      'PL': 'Polish',
      'PT-BR': 'Portuguese (Brazilian)',
      'PT-PT': 'Portuguese (European)',
      'RO': 'Romanian',
      'RU': 'Russian',
      'SK': 'Slovak',
      'SL': 'Slovenian',
      'SV': 'Swedish',
      'TR': 'Turkish',
      'UK': 'Ukrainian',
      'ZH': 'Chinese',
      'ZH-HANS': 'Chinese (Simplified)',
      'ZH-HANT': 'Chinese (Traditional)',
    };
    return languageNames[languageCode] ?? languageCode;
  }
  void _showMessageOptions(BuildContext context, String messageId, Map<String, dynamic> message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.redAccent),
            title: Text('Delete', style: GoogleFonts.poppins(color: Colors.redAccent)),
            onTap: () {
              Navigator.pop(context);
              _deleteMessage(messageId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.forward, color: Color(0xFFFF6200)),
            title: Text('Forward', style: GoogleFonts.poppins(color: const Color(0xFFFF6200))),
            onTap: () {
              Navigator.pop(context);
              _forwardMessage(message);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(String messageId) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot delete message, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Deleting message: $messageId');
    try {
      final response = await HttpService.post(
        'chat.php?action=delete_message',
        body: {'message_id': messageId},
      ).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: delete_message response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          setState(() {
            _messages.removeWhere((m) => m['id'] == messageId);
          });
          final messagesBox = await Hive.openBox('messages_${widget.chatId}');
          await messagesBox.put('messages', _messages.sublist(0, _messages.length > 100 ? 100 : _messages.length));
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to delete message: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error deleting message: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Delete message error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _forwardMessage(Map<String, dynamic> message) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot forward message, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Forwarding message: ${message['id']}');
    try {
      final response = await HttpService.get(
        'chat.php',
        query: {'action': 'get_chats'},
      ).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: get_chats response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          final chats = List<Map<String, dynamic>>.from(data['chats'] ?? []);
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatSelectionScreen(
                chats: chats,
                onChatSelected: (selectedChatId, selectedChatName) async {
                  await _sendForwardedMessage(
                    message,
                    selectedChatId,
                    selectedChatName,
                  );
                },
              ),
            ),
          );
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch chats: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error fetching chats: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Forward message error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _sendForwardedMessage(Map<String, dynamic> message, int targetChatId, String targetChatName) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot send forwarded message, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Sending forwarded message to chatId: $targetChatId');
    try {
      final response = await HttpService.post(
        'chat.php?action=send_message',
        body: {
          'chat_id': targetChatId.toString(),
          'type': message['type'],
          'content': message['content'] ?? '',
          if (message['media_url'] != null && message['media_url'].isNotEmpty) 'media_url': message['media_url'],
        },
      ).timeout(const Duration(seconds: 10));
      print('DEBUG [${DateTime.now().toIso8601String()}]: send_message response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          await NotificationService.sendBackgroundNotification(
            title: targetChatName,
            body: message['type'] == 'text' ? message['content'] : 'Forwarded ${message['type']} message',
            chatId: targetChatId,
            recipientId: null,
          );
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to forward message: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error forwarding message: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Send forwarded message error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _stopVideoRecording(bool cancel) async {
    if (!mounted || !_isRecordingVideo || _cameraController == null) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot stop video recording, not recording or not mounted');
      return;
    }

    try {
      setState(() {
        _isRecordingVideo = false;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer?.cancel();

      if (cancel) {
        await _cameraController!.stopVideoRecording();
        if (_recordedVideoPath != null && await File(_recordedVideoPath!).exists()) {
          await File(_recordedVideoPath!).delete();
        }
        if (mounted) {
          setState(() => _recordedVideoPath = null);
        }
        return;
      }

      final XFile videoFile = await _cameraController!.stopVideoRecording();
      final file = File(videoFile.path);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Stopped recording, file path: ${videoFile.path}');
      
      await Future.delayed(const Duration(milliseconds: 500));

      final fileSize = await file.length();
      if (fileSize == 0) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Video file is empty');
        await file.delete();
        if (mounted) {
          setState(() => _recordedVideoPath = null);
        }
        return;
      }

      if (fileSize > 50 * 1024 * 1024) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Video too large (>50MB): ${fileSize / 1024 / 1024}MB');
        await file.delete();
        if (mounted) {
          setState(() => _recordedVideoPath = null);
        }
        return;
      }

      try {
        final videoCompress = VideoCompress;
        print('DEBUG [${DateTime.now().toIso8601String()}]: Starting video compression for ${file.path}');
        
        final compressedVideo = await videoCompress.compressVideo(
          file.path,
          quality: VideoQuality.MediumQuality,
          deleteOrigin: true,
          includeAudio: true,
          frameRate: 30,
        );

        if (compressedVideo != null && compressedVideo.file != null && await compressedVideo.file!.exists()) {
          final compressedFile = compressedVideo.file!;
          final compressedFileSize = await compressedFile.length();
          print('DEBUG [${DateTime.now().toIso8601String()}]: Video compressed successfully to ${compressedFile.path}, size: ${compressedFileSize / 1024 / 1024}MB');
          
          try {
            final videoPlayerController = VideoPlayerController.file(compressedFile);
            await videoPlayerController.initialize().timeout(const Duration(seconds: 10));
            await videoPlayerController.dispose();
            print('DEBUG [${DateTime.now().toIso8601String()}]: Compressed video file verified successfully');
            if (mounted) {
              setState(() => _recordedVideoPath = compressedFile.path);
              _showUploadingAnimation();
              await _uploadAndSendVideo(compressedFile);
            }
          } catch (e, stackTrace) {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Compressed video verification failed: $e\nStackTrace: $stackTrace');
            await compressedFile.delete();
            if (mounted) {
              setState(() => _recordedVideoPath = null);
            }
          }
        } else {
          throw Exception('Video compression failed or produced an invalid file');
        }
      } catch (e, stackTrace) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Video compression error: $e\nStackTrace: $stackTrace');
        await file.delete();
        if (mounted) {
          setState(() => _recordedVideoPath = null);
        }
        return;
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Stop video error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        setState(() => _recordedVideoPath = null);
      }
    }
  }

  @override
  void dispose() {
    print('DEBUG [${DateTime.now().toIso8601String()}]: ChatScreen dispose called, _messages length: ${_messages.length}');
    WidgetsBinding.instance.removeObserver(this);
    _messageController.removeListener(_onTyping);
    _messageController.dispose();
    _scrollController.dispose();
    _messageTimer?.cancel();
    _typingTimer?.cancel();
    _recordingTimer?.cancel();
    _debounceTimer?.cancel();
    _stopTyping();
    _record.stop();
    _record.dispose();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    _cameraController?.dispose();
    _videoControllers.forEach((key, controller) {
      controller.videoPlayerController.pause();
      controller.videoPlayerController.dispose();
      controller.dispose();
    });
    _videoControllers.clear();
    super.dispose();
  }

  Future<void> _initMessages() async {
    final messagesBox = await Hive.openBox('messages_${widget.chatId}');
    final cachedMessages = messagesBox.get('messages', defaultValue: <Map<String, dynamic>>[]);
    if (mounted) {
      setState(() {
        _messages.addAll(cachedMessages);
        print('DEBUG [${DateTime.now().toIso8601String()}]: Loaded ${cachedMessages.length} cached messages');
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    await _pollMessages();
  }

  void _setError(String message) {
    if (mounted) {
      setState(() => _errorMessage = message);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Error logged: $message');
    }
  }

  void _addPendingOperation(Future<void> Function() operation) {
    _pendingOperations.add(operation);
    _processPendingOperations();
  }

  Future<void> _processPendingOperations() async {
    if (_isRenderingMessages || _pendingOperations.isEmpty) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Skipping pending operations, rendering: $_isRenderingMessages, operations: ${_pendingOperations.length}');
      return;
    }
    final operation = _pendingOperations.removeFirst();
    print('DEBUG [${DateTime.now().toIso8601String()}]: Processing pending operation');
    await operation();
    if (_pendingOperations.isNotEmpty && mounted) {
      await _processPendingOperations();
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients && _messages.isNotEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        print('DEBUG [${DateTime.now().toIso8601String()}]: Scrolled to bottom of ListView');
      });
    }
  }

  Future<void> _checkBlockStatus() async {
    if (widget.isGroup || !mounted) return;
    print('DEBUG [${DateTime.now().toIso8601String()}]: Checking block status for chatId: ${widget.chatId}');
    try {
      final response = await HttpService.get(
        'chat.php',
        query: {'action': 'check_block', 'chat_id': widget.chatId.toString()},
      ).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: check_block response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          setState(() => _isBlocked = data['is_blocked'] == true || data['is_blocked'] == '1');
          print('DEBUG [${DateTime.now().toIso8601String()}]: Block status: $_isBlocked');
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to check block status: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error checking block status: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Check block status error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _fetchParticipants() async {
    if (widget.isGroup || !mounted) return;
    print('DEBUG [${DateTime.now().toIso8601String()}]: Fetching participants for chatId: ${widget.chatId}');
    try {
      final response = await HttpService.get('chat.php', query: {'action': 'get_chats'}).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: get_chats response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          final chat = (data['chats'] as List<dynamic>).firstWhere(
            (c) => (int.tryParse(c['id'].toString()) ?? 0) == widget.chatId,
            orElse: () => null,
          );
          if (chat != null) {
            final participants = List<dynamic>.from(chat['participants'] ?? [])
                .map((p) => int.tryParse(p.toString()) ?? 0)
                .where((id) => id != 0)
                .toList();
            if (participants.isNotEmpty) {
              final otherUserId = participants.firstWhere(
                (id) => id != widget.userId,
                orElse: () => -1,
              );
              if (otherUserId != -1 && mounted) {
                setState(() {
                  _otherUserId = otherUserId;
                  _otherUserName = chat['name']?.toString() ?? 'Unknown';
                });
                print('DEBUG [${DateTime.now().toIso8601String()}]: Other userId: $_otherUserId, name: $_otherUserName');
              }
            } else {
              print('DEBUG [${DateTime.now().toIso8601String()}]: No participants found');
            }
          } else {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Chat not found');
          }
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch participants: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error fetching participants: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Fetch participants error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _fetchNickname() async {
    if (!mounted) return;
    print('DEBUG [${DateTime.now().toIso8601String()}]: Fetching nickname for chatId: ${widget.chatId}, isGroup: ${widget.isGroup}');
    try {
      final response = await HttpService.get('chat.php', query: {'action': 'get_nicknames'}).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: get_nicknames response: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          final nicknameList = data['entities'] ?? data['nicknames'] ?? [];
          final nickname = (nicknameList as List<dynamic>).firstWhere(
            (n) {
              final targetId = int.tryParse(n['target_id'].toString()) ?? 0;
              final isGroup = n['is_group'] == 1 || n['is_group'] == '1';
              return targetId == (widget.isGroup ? widget.chatId : _otherUserId) && isGroup == widget.isGroup;
            },
            orElse: () => null,
          );
          if (nickname != null && mounted) {
            setState(() {
              _nickname = nickname['nickname']?.toString();
              _chatName = _nickname ?? widget.chatName;
            });
            print('DEBUG [${DateTime.now().toIso8601String()}]: Nickname fetched: $_nickname');
            if (!widget.isGroup && _otherUserId != null) {
              final nicknameBox = Hive.box('nicknames');
              await nicknameBox.put(_otherUserId, _nickname);
            }
          } else {
            if (!widget.isGroup && _otherUserId != null) {
              final nicknameBox = Hive.box('nicknames');
              final localNickname = nicknameBox.get(_otherUserId);
              setState(() {
                _nickname = localNickname;
                _chatName = _nickname ?? widget.chatName;
              });
              print('DEBUG [${DateTime.now().toIso8601String()}]: Loaded local nickname: $_nickname');
            } else {
              setState(() => _chatName = widget.chatName);
              print('DEBUG [${DateTime.now().toIso8601String()}]: No nickname, using chatName: $_chatName');
            }
          }
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch nickname: ${data['message'] ?? 'Unknown error'}');
        }
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Server error fetching nickname: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Fetch nickname error: $e\nStackTrace: $stackTrace');
      if (!widget.isGroup && _otherUserId != null && mounted) {
        final nicknameBox = Hive.box('nicknames');
        final localNickname = nicknameBox.get(_otherUserId);
        setState(() {
          _nickname = localNickname;
          _chatName = _nickname ?? widget.chatName;
        });
        print('DEBUG [${DateTime.now().toIso8601String()}]: Fallback to local nickname: $_nickname');
      }
    }
  }

  Future<void> _pollMessages() async {
    if (!mounted || !_isActive) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Skipping pollMessages, mounted: $mounted, active: $_isActive');
      return;
    }
    return _lock.synchronized(() async {
      if (_isRenderingMessages) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Skipping pollMessages, already rendering');
        return;
      }
      setState(() => _isRenderingMessages = true);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Polling messages for chatId: ${widget.chatId}, retryCount: $_retryCount');

      try {
        setState(() => _isLoading = true);

        final response = await HttpService.get(
          'chat.php',
          query: {
            'action': 'get_messages',
            'chat_id': widget.chatId.toString(),
            'limit': '50',
            'offset': '0',
            'last_message_id': _messages.isNotEmpty ? _messages.last['id'].toString() : '0',
          },
        ).timeout(const Duration(seconds: 8));
        print('DEBUG [${DateTime.now().toIso8601String()}]: get_messages response: ${response.statusCode}, body: ${response.body}');

        if (response.statusCode == 429 && _retryCount < _maxRetries) {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Rate limit hit, retrying after ${5 * _retryCount}s');
          _retryCount++;
          await Future.delayed(Duration(seconds: 5 * _retryCount));
          return _pollMessages();
        }

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['status'] == 'success' && mounted) {
            final messages = (data['messages'] as List<dynamic>?) ?? [];
            print('DEBUG [${DateTime.now().toIso8601String()}]: Fetched ${messages.length} messages from API');

            final newMessages = <Map<String, dynamic>>[];
            for (var message in messages) {
              try {
                final content = message['content']?.toString() ?? '';
                final mediaUrl = message['media_url']?.toString() ?? '';
                final processedMessage = {
                  'id': message['id']?.toString() ?? 'unknown_${DateTime.now().millisecondsSinceEpoch}',
                  'chat_id': int.tryParse(message['chat_id']?.toString() ?? '0') ?? 0,
                  'sender_id': int.tryParse(message['sender_id']?.toString() ?? '0') ?? 0,
                  'type': message['type']?.toString() ?? 'text',
                  'content': content,
                  'media_url': mediaUrl,
                  'read_count': int.tryParse(message['read_count']?.toString() ?? '0') ?? 0,
                  'created_at': message['created_at']?.toString() ?? DateTime.now().toIso8601String(),
                  'username': message['username']?.toString() ?? 'Unknown',
                  'verified': message['verified'] == true || message['verified'] == '1',
                };

                if (processedMessage['type'] == 'voice' && mediaUrl.isNotEmpty) {
                  final messageId = processedMessage['id'].toString();
                  if (!_voiceNoteDurations.containsKey(messageId)) {
                    _voiceNoteDurations[messageId] = Duration.zero;
                    _fetchVoiceDuration(mediaUrl, messageId);
                  }
                }

                final existingIndex = _messages.indexWhere((m) => m['id'] == processedMessage['id']);
                if (existingIndex == -1) {
                  newMessages.add(processedMessage);
                } else {
                  _messages[existingIndex] = processedMessage;
                }
              } catch (e, stackTrace) {
                print('DEBUG [${DateTime.now().toIso8601String()}]: Error processing message ID: ${message['id']}, error: $e\nStackTrace: $stackTrace');
                newMessages.add({
                  'id': message['id']?.toString() ?? 'error_${DateTime.now().millisecondsSinceEpoch}',
                  'chat_id': int.tryParse(message['chat_id']?.toString() ?? '0') ?? 0,
                  'sender_id': int.tryParse(message['sender_id']?.toString() ?? '0') ?? 0,
                  'type': message['type']?.toString() ?? 'text',
                  'content': '[Error: Failed to process message: $e]',
                  'media_url': message['media_url']?.toString() ?? '',
                  'read_count': int.tryParse(message['read_count']?.toString() ?? '0') ?? 0,
                  'created_at': message['created_at']?.toString() ?? DateTime.now().toIso8601String(),
                  'username': message['username']?.toString() ?? 'Unknown',
                  'verified': message['verified'] == true || message['verified'] == '1',
                });
              }
            }

            if (mounted) {
              setState(() {
                _messages.addAll(newMessages);
                _messageIdMapping.forEach((tempId, finalId) {
                  final index = _messages.indexWhere((m) => m['id'] == tempId);
                  if (index != -1) {
                    _messages[index]['id'] = finalId;
                  }
                });
                _messageIdMapping.clear();
                _messages.sort((a, b) => DateTime.parse(a['created_at']).compareTo(DateTime.parse(b['created_at'])));
                _isLoading = false;
                _retryCount = 0;
                print('DEBUG [${DateTime.now().toIso8601String()}]: Added ${newMessages.length} new messages, total: ${_messages.length}');
              });

              final messagesBox = await Hive.openBox('messages_${widget.chatId}');
              await messagesBox.put('messages', _messages.sublist(0, _messages.length > 100 ? 100 : _messages.length));
              print('DEBUG [${DateTime.now().toIso8601String()}]: Saved ${_messages.length} messages to Hive');

              _scrollToBottom();
            }
          } else {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch messages: ${data['message'] ?? 'Status: ${response.statusCode}'}');
            _handleRetry();
          }
        } else {
          print('DEBUG [${DateTime.now().toIso8601String()}]: Server error fetching messages: ${response.statusCode}');
          _handleRetry();
        }
      } catch (e, stackTrace) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Poll messages error: $e\nStackTrace: $stackTrace');
        _handleRetry();
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isRenderingMessages = false;
          });
          _processPendingOperations();
        }
      }
    });
  }

  void _handleRetry() {
    if (_retryCount < _maxRetries && mounted) {
      _retryCount++;
      print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying pollMessages, attempt: $_retryCount');
      Future.delayed(Duration(seconds: 2 * _retryCount), _pollMessages);
    } else {
      _retryCount = 0;
      print('DEBUG [${DateTime.now().toIso8601String()}]: Max retries reached, stopping retry');
    }
  }

  Future<void> _fetchVoiceDuration(String url, String messageId) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Skipping fetchVoiceDuration, mounted: $mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Fetching voice duration for messageId: $messageId');
    try {
      final audioPlayer = AudioPlayer();
      await audioPlayer.setSourceUrl(url).timeout(const Duration(seconds: 5));
      final duration = await audioPlayer.getDuration();
      if (duration != null && mounted) {
        setState(() {
          _voiceNoteDurations[messageId] = duration;
        });
        print('DEBUG [${DateTime.now().toIso8601String()}]: Set voice duration for $messageId: $duration');
      }
      await audioPlayer.dispose();
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Error fetching voice duration for $messageId: $e\nStackTrace: $stackTrace');
      if (mounted) {
        setState(() {
          _voiceNoteDurations[messageId] = Duration.zero;
        });
      }
      if (_retryCount < _maxRetries) {
        _retryCount++;
        await Future.delayed(Duration(seconds: 2 * _retryCount));
        await _fetchVoiceDuration(url, messageId);
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to load voice note duration after retries');
      }
    }
  }

  void _startMessagePolling() {
    _messageTimer?.cancel();
    print('DEBUG [${DateTime.now().toIso8601String()}]: Starting message polling');
    _messageTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isActive && mounted && !_isRenderingMessages) {
        await _pollMessages();
      } else if (!_isActive || !mounted) {
        timer.cancel();
        print('DEBUG [${DateTime.now().toIso8601String()}]: Stopped message polling');
      }
    });
  }

  Future<void> _sendMessage({String? content, String? type, String? url}) async {
    if (_isBlocked || !mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot send messages: ${_isBlocked ? 'User is blocked' : 'Widget not mounted'}');
      return;
    }

    final message = content ?? _messageController.text.trim();
    if (message.isEmpty && _selectedMedia == null && url == null && _recordedAudioPath == null && _recordedVideoPath == null) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Empty message, aborting send');
      return;
    }

    final tempMessageId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    String finalContent = message;
    String finalType = type ?? 'text';
    String? finalUrl = url;

    if (_recordedAudioPath != null) {
      finalType = 'voice';
      final file = File(_recordedAudioPath!);
      final fileSize = await file.length();
      if (fileSize > 10 * 1024 * 1024) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Voice note too large (>10MB)');
        setState(() => _recordedAudioPath = null);
        await file.delete();
        return;
      }
      finalUrl = await _uploadFile(file, 'voice');
      if (mounted) setState(() => _recordedAudioPath = null);
      if (finalUrl == null) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to upload voice note');
        return;
      }
    } else if (_recordedVideoPath != null) {
      finalType = 'video';
      final file = File(_recordedVideoPath!);
      final fileSize = await file.length();
      if (fileSize > 50 * 1024 * 1024) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Video too large (>50MB)');
        setState(() => _recordedVideoPath = null);
        await file.delete();
        return;
      }
      finalUrl = await _uploadFile(file, 'video');
      if (mounted) setState(() => _recordedVideoPath = null);
      if (finalUrl == null) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to upload video');
        return;
      }
    }

    if (finalContent.isNotEmpty || finalUrl != null) {
      setState(() {
        _messages.add({
          'id': tempMessageId,
          'chat_id': widget.chatId,
          'sender_id': widget.userId,
          'type': finalType,
          'content': finalContent,
          'media_url': finalUrl ?? '',
          'read_count': 0,
          'created_at': DateTime.now().toIso8601String(),
          'username': 'You',
          'verified': false,
        });
      });

      _scrollToBottom();
    }

    int retryCount = 0;
    while (retryCount < _maxRetries && mounted) {
      try {
        if (finalUrl != null && finalType == 'text') {
          finalType = _inferTypeFromContent(message);
        }

        print('DEBUG [${DateTime.now().toIso8601String()}]: Sending message, type: $finalType, url: $finalUrl, content: $finalContent');
        final response = await HttpService.post(
          'chat.php?action=send_message',
          body: {
            'chat_id': widget.chatId.toString(),
            'type': finalType,
            'content': finalContent,
            if (finalUrl != null) 'media_url': finalUrl,
          },
        ).timeout(const Duration(seconds: 10));
        print('DEBUG [${DateTime.now().toIso8601String()}]: send_message response: ${response.statusCode}, body: ${response.body}');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['status'] == 'success' && mounted) {
            setState(() {
              final index = _messages.indexWhere((m) => m['id'] == tempMessageId);
              if (index != -1) {
                _messages[index]['id'] = data['message_id'].toString();
              }
              _messageController.clear();
              _selectedMedia = null;
              _uploadProgress = 0.0;
            });
            final messagesBox = await Hive.openBox('messages_${widget.chatId}');
            await messagesBox.put('messages', _messages.sublist(0, _messages.length > 100 ? 100 : _messages.length));
            print('DEBUG [${DateTime.now().toIso8601String()}]: Message sent successfully, messageId: ${data['message_id']}');

            await NotificationService.sendBackgroundNotification(
              title: _chatName,
              body: finalType == 'text' ? finalContent : 'New ${finalType} message',
              chatId: widget.chatId,
              recipientId: _otherUserId?.toString(),
            );

            return;
          } else {
            throw Exception('Failed to send message: ${data['message'] ?? 'Unknown error'}');
          }
        } else {
          throw Exception('Server error: ${response.statusCode}');
        }
      } catch (e, stackTrace) {
        retryCount++;
        if (retryCount >= _maxRetries) {
          setState(() {
            _messages.removeWhere((m) => m['id'] == tempMessageId);
          });
          print('DEBUG [${DateTime.now().toIso8601String()}]: Send message error after $retryCount attempts: $e\nStackTrace: $stackTrace');
          return;
        }
        print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying sendMessage, attempt: ${retryCount + 1}, error: $e');
        await Future.delayed(Duration(seconds: 2 * retryCount));
      }
    }
  }

  String _inferTypeFromContent(String content) {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Inferring type from content: $content');
    switch (content.toLowerCase()) {
      case 'voice note':
        return 'voice';
      case 'image':
        return 'image';
      case 'video':
        return 'video';
      case 'document':
        return 'document';
      case 'gif':
        return 'gif';
      case 'location':
        return 'location';
      default:
        return 'text';
    }
  }

  Future<String?> _uploadFile(File file, String type) async {
    print('DEBUG [${DateTime.now().toIso8601String()}]: Uploading file of type: $type');
    try {
      final fileSize = await file.length();
      final maxSize = type == 'voice' ? 10 * 1024 * 1024 : 50 * 1024 * 1024;
      if (fileSize > maxSize) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: File too large (>${maxSize / 1024 / 1024}MB)');
        return null;
      }
      if (fileSize == 0) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Selected file is empty');
        return null;
      }

      int retryCount = 0;
      while (retryCount < _maxRetries && mounted) {
        try {
          final url = await HttpService.uploadFile(file, type, onProgress: (progress) {
            if (mounted) setState(() => _uploadProgress = progress);
          }).timeout(const Duration(seconds: 60));
          if (url != null) {
            print('DEBUG [${DateTime.now().toIso8601String()}]: File uploaded successfully: $url');
            await NotificationService.sendBackgroundNotification(
              title: _chatName,
              body: 'New $type uploaded',
              chatId: widget.chatId,
              recipientId: _otherUserId?.toString(),
            );
            return url;
          } else {
            throw Exception('Upload returned null URL');
          }
        } catch (e, stackTrace) {
          retryCount++;
          if (retryCount >= _maxRetries) {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Upload failed after $retryCount attempts: $e\nStackTrace: $stackTrace');
            return null;
          }
          print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying upload, attempt: ${retryCount + 1}, error: $e');
          await Future.delayed(Duration(seconds: 2 * retryCount));
        }
      }
      return null;
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Upload error: $e\nStackTrace: $stackTrace');
      return null;
    }
  }

  Future<void> _pickMedia(String type) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot pick media, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Picking media type: $type');
    try {
      FileType fileType;
      List<String>? allowedExtensions;

      switch (type) {
        case 'image':
          fileType = FileType.custom;
          allowedExtensions = ['jpg', 'jpeg', 'png', 'gif'];
          break;
        case 'video':
          fileType = FileType.custom;
          allowedExtensions = ['mp4', 'mov'];
          break;
        case 'document':
          fileType = FileType.custom;
          allowedExtensions = ['pdf'];
          break;
        default:
          fileType = FileType.any;
          allowedExtensions = null;
      }

      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowedExtensions: allowedExtensions,
        allowCompression: false,
      );

      if (result == null || result.files.single.path == null) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: No $type selected');
        return;
      }

      final file = File(result.files.single.path!);
      if (!await file.exists()) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Selected file does not exist: ${file.path}');
        return;
      }
      final fileSize = await file.length();
      if (fileSize == 0) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Selected file is empty');
        return;
      }
      if (fileSize > 50 * 1024 * 1024) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: File too large (>50MB): ${fileSize / 1024 / 1024}MB');
        return;
      }
      print('DEBUG [${DateTime.now().toIso8601String()}]: Selected file: ${file.path}, Size: ${fileSize / 1024 / 1024}MB');

      if (!mounted) return;
      setState(() => _selectedMedia = file);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: _uploadProgress, color: const Color(0xFFFF6200)),
                const SizedBox(height: 16),
                Text('Uploading $type...', style: GoogleFonts.poppins()),
              ],
            ),
          ),
        ),
      );

      final url = await _uploadFile(file, type == 'image' && file.path.endsWith('.gif') ? 'gif' : type);
      if (mounted) {
        Navigator.pop(context);
        setState(() => _uploadProgress = 0.0);
      }

      if (url != null) {
        await _sendMessage(
          content: '',
          type: type == 'image' && file.path.endsWith('.gif') ? 'gif' : type,
          url: url,
        );
      } else {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to upload $type');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Pick media error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        Navigator.pop(context);
        setState(() => _uploadProgress = 0.0);
      }
    }
  }

  Future<void> _sendLiveLocation() async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot send location, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Sending live location');
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Location permission denied');
        return;
      }

      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high).timeout(const Duration(seconds: 5));
      final locationUrl = 'https://www.google.com/maps?q=${position.latitude},${position.longitude}';
      await _sendMessage(content: 'My current location', type: 'location', url: locationUrl);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Location sent: $locationUrl');
      await NotificationService.sendBackgroundNotification(
        title: _chatName,
        body: 'Shared a location',
        chatId: widget.chatId,
        recipientId: _otherUserId?.toString(),
      );
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Send location error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _viewLocation(String url) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot view location, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Viewing location: $url');
    try {
      final uri = Uri.parse(url);
      if (!await canLaunchUrl(uri)) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot launch URL: $url');
        return;
      }
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('DEBUG [${DateTime.now().toIso8601String()}]: Location URL launched: $url');
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: View location error: $e\nStackTrace: $stackTrace');
    }
  }

  Future<void> _translateMessage(String messageText, String messageId, String languageCode) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot translate message, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Translating message $messageId to $languageCode');
    setState(() => _translatedMessages[messageId] = 'Translating...');
    try {
      final translatedText = await _translationService.translate(messageText, languageCode).timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() => _translatedMessages[messageId] = translatedText);
        print('DEBUG [${DateTime.now().toIso8601String()}]: Message $messageId translated: $translatedText');
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Translate message error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        setState(() => _translatedMessages.remove(messageId));
      }
    }
  }

  Future<void> _uploadAndSendVideo(File videoFile) async {
    try {
      final url = await HttpService.uploadFile(
        videoFile, 
        'video',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _uploadProgress = progress;
            });
          }
        },
      );

      if (url != null) {
        if (mounted) {
          Navigator.pop(context);
          await _sendMessage(
            content: '',
            type: 'video',
            url: url,
          );
        }
      } else {
        throw Exception('Failed to upload video');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordedVideoPath = null;
          _uploadProgress = 0.0;
        });
      }
    }
  }

  void _showUploadingAnimation() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SpinKitThreeBounce(
              color: Theme.of(context).primaryColor,
              size: 30.0,
            ),
            const SizedBox(height: 20),
            Text(
              'Uploading Video...',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 16,
              ),
            ).animate(
              onPlay: (controller) => controller.repeat(),
            ).shimmer(
              duration: const Duration(seconds: 1),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    if (!mounted || _isRecording || _isRecordingVideo) {
      print('Cannot start recording - already recording or not mounted');
      return;
    }

    try {
      final status = await Permission.microphone.status;
      if (!status.isGranted) {
        final result = await Permission.microphone.request();
        if (!result.isGranted) {
          return;
        }
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${const Uuid().v4()}.m4a';
      
      await _record.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      if (mounted) {
        setState(() {
          _isRecording = true;
          _recordingDuration = Duration.zero;
          _recordedAudioPath = path;
        });
        
        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (mounted) {
            setState(() {
              _recordingDuration += const Duration(seconds: 1);
              if (_recordingDuration.inSeconds >= 60) {
                _stopRecording(false);
              }
            });
          } else {
            timer.cancel();
          }
        });
      }
    } catch (e, stackTrace) {
      print('Start recording error: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingDuration = Duration.zero;
          _recordedAudioPath = null;
        });
      }
    }
  }

  Future<void> _stopRecording(bool cancel) async {
    if (!mounted || !_isRecording) return;
    
    try {
      setState(() {
        _isRecording = false;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer?.cancel();
      
      final path = await _record.stop();
      if (cancel || path == null) {
        if (path != null) await File(path).delete();
        setState(() => _recordedAudioPath = null);
        return;
      }
      
      final file = File(path);
      if (await file.length() > 0) {
        setState(() => _recordedAudioPath = path);
      } else {
        await file.delete();
        setState(() => _recordedAudioPath = null);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _recordedAudioPath = null);
      }
    }
  }

  Future<void> _playVoiceNote(String url, String messageId) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot play voice note, widget not mounted');
      return;
    }
    print('DEBUG [${DateTime.now().toIso8601String()}]: Playing voice note for messageId: $messageId');
    try {
      if (_playingMessageId == messageId) {
        await _audioPlayer.pause();
        if (mounted) setState(() => _playingMessageId = null);
        print('DEBUG [${DateTime.now().toIso8601String()}]: Paused voice note for messageId: $messageId');
        return;
      }

      if (!Uri.parse(url).isAbsolute) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Invalid voice note URL: $url');
        return;
      }

      int retryCount = 0;
      while (retryCount < _maxRetries && mounted) {
        try {
          await _audioPlayer.setSourceUrl(url).timeout(const Duration(seconds: 5));
          await _audioPlayer.play(UrlSource(url));
          if (mounted) {
            setState(() => _playingMessageId = messageId);
            _audioPlayer.onPositionChanged.listen((duration) {
              if (mounted) setState(() => _voiceDuration = duration);
            });
            _audioPlayer.onPlayerComplete.listen((event) {
              if (mounted) setState(() => _playingMessageId = null);
            });
            print('DEBUG [${DateTime.now().toIso8601String()}]: Playing voice note: $url');
            return;
          }
        } catch (e, stackTrace) {
          retryCount++;
          if (retryCount >= _maxRetries) {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to play voice note after $retryCount attempts: $e\nStackTrace: $stackTrace');
            if (mounted) {
              setState(() => _playingMessageId = null);
            }
            return;
          }
          print('DEBUG [${DateTime.now().toIso8601String()}]: Retrying playVoiceNote, attempt: ${retryCount + 1}, error: $e');
          await Future.delayed(Duration(seconds: 2 * retryCount));
        }
      }
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Play voice note error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        setState(() => _playingMessageId = null);
      }
    }
  }

  void _startTypingPolling() {
    _typingTimer?.cancel();
    print('DEBUG [${DateTime.now().toIso8601String()}]: Starting typing polling');
    _typingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_isActive || !mounted) {
        timer.cancel();
        print('DEBUG [${DateTime.now().toIso8601String()}]: Stopped typing polling, active: $_isActive, mounted: $mounted');
        return;
      }
      try {
        final response = await HttpService.get(
          'chat.php',
          query: {'action': 'get_typing_status', 'chat_id': widget.chatId.toString()},
        ).timeout(const Duration(seconds: 5));
        print('DEBUG [${DateTime.now().toIso8601String()}]: get_typing_status response: ${response.statusCode}, body: ${response.body}');
        if (response.statusCode == 200 && mounted) {
          final data = jsonDecode(response.body);
          if (data['status'] == 'success') {
            setState(() {
              _typingUsers = (data['typing_users'] as List<dynamic>?)
                      ?.where((user) => int.tryParse(user['user_id'].toString()) != widget.userId)
                      .toList() ??
                  [];
            });
            print('DEBUG [${DateTime.now().toIso8601String()}]: Typing users updated: ${_typingUsers.length}');
          } else {
            print('DEBUG [${DateTime.now().toIso8601String()}]: Failed to fetch typing status: ${data['message'] ?? 'Unknown error'}');
          }
        }
      } catch (e, stackTrace) {
        print('DEBUG [${DateTime.now().toIso8601String()}]: Typing polling error: $e\nStackTrace: $stackTrace');
      }
    });
  }

  void _onTyping() {
    if (_isBlocked) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Typing blocked, isBlocked: $_isBlocked');
      return;
    }
    if (_messageController.text.trim().isNotEmpty && !_isTyping) {
      _isTyping = true;
      _sendTypingStatus(true);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Started typing');
    } else if (_messageController.text.trim().isEmpty && _isTyping) {
      _isTyping = false;
      _sendTypingStatus(false);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Stopped typing');
    }
  }

  Future<void> _sendTypingStatus(bool isTyping) async {
    if (!mounted) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Cannot send typing status, widget not mounted');
      return;
    }
    try {
      final response = await HttpService.post(
        'chat.php?action=update_typing_status',
        body: {
          'chat_id': widget.chatId.toString(),
          'is_typing': isTyping.toString(),
        },
      ).timeout(const Duration(seconds: 5));
      print('DEBUG [${DateTime.now().toIso8601String()}]: update_typing_status response: ${response.statusCode}, isTyping: $isTyping');
    } catch (e, stackTrace) {
      print('DEBUG [${DateTime.now().toIso8601String()}]: Send typing status error: $e\nStackTrace: $stackTrace');
    }
  }

  void _stopTyping() {
    if (_isTyping && mounted) {
      _isTyping = false;
      _sendTypingStatus(false);
      print('DEBUG [${DateTime.now().toIso8601String()}]: Stopped typing via _stopTyping');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('DEBUG [${DateTime.now().toIso8601String()}]: AppLifecycleState changed to: $state');
    if (!mounted) return;
    setState(() {
      _isActive = state == AppLifecycleState.resumed;
    });
    if (_isActive) {
      _addPendingOperation(_pollMessages);
      _addPendingOperation(_fetchNickname);
    } else {
      _messageTimer?.cancel();
      _typingTimer?.cancel();
    }
  }
}

class ChatSelectionScreen extends StatelessWidget {
  final List<Map<String, dynamic>> chats;
  final Function(int, String) onChatSelected;

  const ChatSelectionScreen({
    super.key,
    required this.chats,
    required this.onChatSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? const Color(0xFF121212) : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        title: Text(
          'Select Chat to Forward',
          style: GoogleFonts.poppins(
            color: textColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          final chatId = int.tryParse(chat['id'].toString()) ?? 0;
          final chatName = chat['name']?.toString() ?? 'Unknown';
          final isGroup = chat['is_group'] == true || chat['is_group'] == '1';

          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.grey[300],
              child: Text(
                chatName.isNotEmpty ? chatName[0].toUpperCase() : 'C',
                style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
            title: Text(
              chatName,
              style: GoogleFonts.poppins(color: textColor),
            ),
            subtitle: Text(
              isGroup ? 'Group Chat' : 'Personal Chat',
              style: GoogleFonts.poppins(color: isDarkMode ? Colors.white54 : Colors.black54),
            ),
            onTap: () async {
              await onChatSelected(chatId, chatName);
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
          );
        },
      ),
    );
  }
}