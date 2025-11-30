import 'dart:async';
import 'dart:convert';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:synchronized/synchronized.dart';
import 'package:video_player/video_player.dart';

import 'main.dart'; // Contains AuthState and HttpService

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _filteredChats = [];
  bool _isLoading = false;
  bool _isSearching = false;
  String? _errorMessage;
  bool _isVerified = false;
  Map<int, String> _nicknames = {};
  Map<int, String> _profilePhotos = {};
  Map<int, dynamic> _statusMedia = {};
  Map<int, bool> _hasUnreadStatus = {};
  Map<int, bool> _verifiedUsers = {};
  Timer? _chatTimer;
  bool _isActive = true;
  final _searchController = TextEditingController();
  final _lock = Lock();

  @override
  void initState() {
    super.initState();
    print('DEBUG: initState called, AuthState.userId: ${AuthState.userId} at ${DateTime.now()}');
    if (AuthState.userId == null || AuthState.userId == 0) {
      print('DEBUG: Invalid userId, redirecting to auth');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/auth');
      });
    } else {
      WidgetsBinding.instance.addObserver(this);
      _fetchUserVerification();
      _initializeHive().then((_) {
        _loadNickUsers().then((_) {
          _fetchChatsAndStatuses();
          _startChatPolling();
        }).catchError((e, stackTrace) {
          print('DEBUG: Load nicknames and photos failed: $e\n$stackTrace');
          _fetchChatsAndStatuses();
          _startChatPolling();
        });
      }).catchError((e, stackTrace) {
        print('DEBUG: Hive initialization failed: $e\n$stackTrace');
      });
      _searchController.addListener(_onSearchChanged);
    }
  }

  Future<void> _initializeHive() async {
    if (!Hive.isBoxOpen('nicknames')) {
      await Hive.openBox('nicknames');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    print('DEBUG: AppLifecycleState changed to: $state at ${DateTime.now()}');
    setState(() {
      _isActive = state == AppLifecycleState.resumed;
    });
    if (_isActive) {
      _loadNickUsers();
      _fetchChatsAndStatuses();
    }
  }

  @override
  void dispose() {
    print('DEBUG: dispose called at ${DateTime.now()}');
    WidgetsBinding.instance.removeObserver(this);
    _chatTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _statusMedia.forEach((_, media) {
      if (media is VideoPlayerController) media.dispose();
    });
    if (Hive.isBoxOpen('nicknames')) {
      Hive.box('nicknames').close();
    }
    super.dispose();
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return false;
  }

  Future<void> _loadNickUsers() async {
    if (!mounted) return;
    print('DEBUG: Loading nicknames, photos, and verification at ${DateTime.now()}');
    return _lock.synchronized(() async {
      try {
        final nicknameBox = Hive.box('nicknames');
        final response = await HttpService.get('/user.php', query: {'action': 'get_users'});
        print('DEBUG: get_users response status: ${response.statusCode}, body: ${response.body}');
        if (await HttpService.handleSessionError(response, 1, 'api/user.php')) {
          return;
        }
        final data = jsonDecode(response.body);
        if (response.statusCode == 200 && data['status'] == 'success') {
          final users = (data['users'] as List<dynamic>? ?? [])
              .where((user) => user is Map<String, dynamic>)
              .map((user) => Map<String, dynamic>.from(user))
              .toList();

          for (var user in users) {
            final userId = int.tryParse(user['id'].toString()) ?? 0;
            if (userId != 0) {
              final nickname = user['username']?.toString() ?? '';
              if (nickname.isNotEmpty) {
                await nicknameBox.put(userId, nickname);
              }
              final profilePhotoUrl = user['profile_photo_url']?.toString() ?? '';
              if (profilePhotoUrl.isNotEmpty) {
                _profilePhotos[userId] = profilePhotoUrl;
              }
              final statusPhotoUrl = user['status_photo_url']?.toString() ?? '';
              final statusVideoUrl = user['status_video_url']?.toString() ?? '';
              if (statusPhotoUrl.isNotEmpty || statusVideoUrl.isNotEmpty) {
                _statusMedia[userId] = statusPhotoUrl.isNotEmpty ? statusPhotoUrl : statusVideoUrl;
                _hasUnreadStatus[userId] = true;
              }
              final verified = _toBool(user['is_verified'] ?? false);
              _verifiedUsers[userId] = verified;
            }
          }

          if (mounted) {
            setState(() {
              _nicknames = Map<int, String>.from(nicknameBox.toMap().map(
                    (k, v) => MapEntry(int.parse(k.toString()), v.toString()),
                  ));
              print('DEBUG: Updated _nicknames: $_nicknames');
              print('DEBUG: Updated _profilePhotos: $_profilePhotos');
              print('DEBUG: Updated _statusMedia: $_statusMedia');
              print('DEBUG: Updated _verifiedUsers: $_verifiedUsers');
            });
          }
        } else {
          print('DEBUG: get_users failed: ${data['message']}');
        }
      } catch (e, stackTrace) {
        print('DEBUG: Load nicknames and photos error: $e\nStackTrace: $stackTrace');
        if (mounted) {
          setState(() => _errorMessage = 'Error loading user data');
        }
      }
    });
  }

  Future<void> _fetchUserVerification() async {
    if (!mounted) return;
    print('DEBUG: Fetching user verification at ${DateTime.now()}');
    return _lock.synchronized(() async {
      try {
        final response = await HttpService.get('/user.php', query: {'action': 'verify_session'});
        print('DEBUG: verify_session response status: ${response.statusCode}, body: ${response.body}');
        if (await HttpService.handleSessionError(response, 1, 'api/user.php')) {
          return;
        }
        final data = jsonDecode(response.body);
        if (response.statusCode == 200 && data['status'] == 'success' && mounted) {
          setState(() {
            _isVerified = _toBool(data['is_verified'] ?? false);
            print('DEBUG: Current user verified: $_isVerified');
          });
        } else if (mounted) {
          setState(() => _errorMessage = data['message'] ?? 'Failed to verify user');
          print('DEBUG: Failed to verify user: $_errorMessage');
        }
      } catch (e, stackTrace) {
        print('DEBUG: Fetch user verification error: $e\nStackTrace: $stackTrace');
        if (mounted) {
          setState(() => _errorMessage = 'Error fetching user verification');
        }
      }
    });
  }

  Future<void> _fetchChatsAndStatuses({int retryCount = 0}) async {
    if (!mounted) return;
    const maxRetries = 3;
    print('DEBUG: _fetchChatsAndStatuses started, retryCount: $retryCount at ${DateTime.now()}');
    return _lock.synchronized(() async {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      try {
        final chatResponse = await HttpService.get('/chat.php', query: {'action': 'get_chats'});
        print('DEBUG: get_chats status: ${chatResponse.statusCode}');

        if (chatResponse.statusCode == 429 && retryCount < maxRetries) {
          print('DEBUG: Rate limit hit, retrying after 5 seconds');
          await Future.delayed(const Duration(seconds: 5));
          return _fetchChatsAndStatuses(retryCount: retryCount + 1);
        }

        if (chatResponse.statusCode == 200) {
          final chatData = jsonDecode(chatResponse.body.trim());
          print('DEBUG: Parsed get_chats data: ${chatData['status']}');

          if (chatData['status'] == 'success' && chatData['chats'] != null) {
            final currentUserId = AuthState.userId ?? 0;
            final chats = (chatData['chats'] as List<dynamic>)
                .map((c) => Map<String, dynamic>.from(c))
                .toList();

            final chatList = chats.where((chat) {
              final participants = (chat['participants'] as List<dynamic>?)?.cast<int>() ?? [];
              return participants.contains(currentUserId);
            }).map((chat) {
              final participants = (chat['participants'] as List<dynamic>?)?.cast<int>() ?? [];
              final otherUserId = participants.firstWhere(
                (id) => id != currentUserId,
                orElse: () => 0,
              );

              return {
                'id': chat['id'],
                'is_group': _toBool(chat['is_group']),
                'username': chat['name'] ?? 'Unknown',
                'other_user_id': otherUserId,
                'last_message': chat['last_message']?.toString() ?? 'No recent activity',
                'last_message_time': chat['last_message_time'] ?? DateTime.now().toIso8601String(),
                'unread_count': chat['unread_count'] ?? 0,
                'verified': _verifiedUsers[otherUserId] ?? false,
                'profile_photo_url': _profilePhotos[otherUserId] ?? '',
                'status_photo_url': _statusMedia[otherUserId] is String ? _statusMedia[otherUserId] : '',
                'status_video_url': _statusMedia[otherUserId] is String && _statusMedia[otherUserId].toString().endsWith('.mp4') ? _statusMedia[otherUserId] : '',
              };
            }).toList();

            if (mounted) {
              setState(() {
                _chats = chatList;
                _onSearchChanged();
                _isLoading = false;
              });
              print('DEBUG: Updated _chats: ${_chats.map((c) => {'id': c['id'], 'name': c['username'], 'verified': c['verified']}).toList()}');
            }
          } else if (mounted) {
            setState(() {
              _errorMessage = chatData['message'] ?? 'Failed to load chats';
              _isLoading = false;
            });
            print('DEBUG: Data fetch failed: $_errorMessage');
          }
        } else if (await HttpService.handleSessionError(chatResponse, retryCount, '/chat.php') && retryCount < maxRetries) {
          print('DEBUG: Session error, retrying');
          return _fetchChatsAndStatuses(retryCount: retryCount + 1);
        } else if (mounted) {
          setState(() {
            _errorMessage = 'Server error: ${chatResponse.statusCode}';
            _isLoading = false;
          });
          print('DEBUG: Server error: $_errorMessage');
        }
      } catch (e, stackTrace) {
        print('DEBUG: Fetch data error: $e\nStackTrace: $stackTrace');
        if (mounted) {
          setState(() {
            _errorMessage = 'Error fetching data: $e';
            _isLoading = false;
          });
        }
      }
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    print('DEBUG: Search query: "$query" at ${DateTime.now()}');
    if (mounted) {
      setState(() {
        if (query.isEmpty) {
          _filteredChats = List.from(_chats);
          _isSearching = false;
        } else {
          _filteredChats = _chats.where((chat) {
            final displayName = _nicknames[chat['other_user_id']] ?? chat['username'] ?? '';
            return displayName.toLowerCase().contains(query);
          }).toList();
          _isSearching = true;
        }
        print('DEBUG: Filtered chats: ${_filteredChats.map((c) => c['id']).toList()}');
      });
    }
  }

  Future<void> _startChatPolling() async {
    _chatTimer?.cancel();
    print('DEBUG: Starting chat polling at ${DateTime.now()}');
    _chatTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (_isActive && mounted) {
        await _loadNickUsers();
        await _fetchChatsAndStatuses();
      } else {
        timer.cancel();
        print('DEBUG: Stopped chat polling at ${DateTime.now()}');
      }
    });
  }

  Future<void> _createNewChat() async {
    if (!mounted) return;
    print('DEBUG: Navigating to new chat at ${DateTime.now()}');
    final created = await Navigator.pushNamed(context, '/new_chat');
    if (created == true && mounted) {
      await _loadNickUsers();
      await _fetchChatsAndStatuses();
      print('DEBUG: Refreshed chats after new chat at ${DateTime.now()}');
    }
  }

  Future<void> _setNickname(int userId, String currentName, int chatId) async {
    if (!mounted) return;
    print('DEBUG: Setting nickname for userId: $userId, chatId: $chatId at ${DateTime.now()}');
    final controller = TextEditingController(text: _nicknames[userId] ?? currentName);
    final formKey = GlobalKey<FormState>();
    String? errorMessage;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Colors.transparent,
          child: GlassmorphicContainer(
            width: double.infinity,
            height: 250,
            borderRadius: 16,
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
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FadeInUp(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        'Set Nickname',
                        style: GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FadeInUp(
                      duration: const Duration(milliseconds: 400),
                      child: TextFormField(
                        controller: controller,
                        style: GoogleFonts.poppins(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Enter nickname (3-30 characters)',
                          hintStyle: GoogleFonts.poppins(color: Colors.white70),
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.4),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                          errorStyle: GoogleFonts.poppins(color: Colors.red),
                        ),
                        maxLength: 30,
                        validator: (value) {
                          final trimmed = value?.trim() ?? '';
                          if (trimmed.isEmpty) return 'Nickname cannot be empty';
                          if (trimmed.length < 3) return 'Nickname must be at least 3 characters';
                          if (trimmed.length > 30) return 'Nickname must be 30 characters or less';
                          return null;
                        },
                        onChanged: (value) => setDialogState(() => errorMessage = null),
                      ),
                    ),
                    if (errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          errorMessage!,
                          style: GoogleFonts.poppins(color: Colors.red, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FadeInUp(
                      duration: const Duration(milliseconds: 500),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(
                              'Cancel',
                              style: GoogleFonts.poppins(
                                color: Colors.white70,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () async {
                              if (formKey.currentState!.validate()) {
                                try {
                                  final nickname = controller.text.trim();
                                  final response = await HttpService.post(
                                    '/chat.php?action=set_nickname',
                                    body: {
                                      'target_id': userId.toString(),
                                      'is_group': '0',
                                      'nickname': nickname,
                                    }, 
                                  );
                                  print('DEBUG: set_nickname response: ${response.statusCode}, ${response.body}');
                                  if (await HttpService.handleSessionError(response, 1, 'api/chat.php')) {
                                    return;
                                  }
                                  final data = jsonDecode(response.body);
                                  if (response.statusCode == 200 && data['status'] == 'success') {
                                    final nicknameBox = Hive.box('nicknames');
                                    await nicknameBox.put(userId, nickname);
                                    Navigator.pop(context, true);
                                  } else {
                                    setDialogState(() => errorMessage = data['message'] ?? 'Failed to save nickname');
                                  }
                                } catch (e, stackTrace) {
                                  setDialogState(() => errorMessage = 'Error saving nickname: $e');
                                  print('DEBUG: Set nickname error: $e\nStackTrace: $stackTrace');
                                }
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFF6200),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                            child: Text(
                              'Save',
                              style: GoogleFonts.poppins(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (result == true && mounted) {
      setState(() {
        _nicknames[userId] = controller.text.trim();
        _onSearchChanged();
        print('DEBUG: Updated nickname for user $userId: ${_nicknames[userId]}');
      });
      await _fetchChatsAndStatuses();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nickname saved successfully',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _deleteChat(int chatId) async {
    if (!mounted) return;
    print('DEBUG: Deleting chat: $chatId at ${DateTime.now()}');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.transparent,
        child: GlassmorphicContainer(
          width: double.infinity,
          height: 200,
          borderRadius: 16,
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
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FadeInUp(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    'Delete Chat',
                    style: GoogleFonts.poppins(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FadeInUp(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    'Are you sure you want to delete this chat?',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      color: Colors.white70,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                FadeInUp(
                  duration: const Duration(milliseconds: 500),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.poppins(
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        child: Text(
                          'Delete',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final response = await HttpService.post(
        '/chat.php?action=delete_chat',
        body: {'chat_id': chatId.toString()},
      );
      print('DEBUG: delete_chat response: ${response.statusCode}, ${response.body}');
      if (await HttpService.handleSessionError(response, 1, 'api/chat.php')) {
        return;
      }
      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['status'] == 'success' && mounted) {
        setState(() {
          _chats.removeWhere((chat) => chat['id'] == chatId);
          _onSearchChanged();
          print('DEBUG: Deleted chat $chatId, chats remaining: ${_chats.length}');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Chat deleted successfully',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              data['message'] ?? 'Failed to delete chat',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e, stackTrace) {
      print('DEBUG: Delete chat error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error deleting chat: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  String _formatTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      if (dateTime.day == now.day && dateTime.month == now.month && dateTime.year == now.year) {
        return '${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
      }
      return '${dateTime.day}/${dateTime.month}/${dateTime.year.toString().substring(2)}';
    } catch (e) {
      print('DEBUG: Format time error: $e');
      return '';
    }
  }

  void _viewStatus(int userId) {
    if (!mounted || _statusMedia[userId] == null) return;
    print('DEBUG: Viewing status for user $userId, media: ${_statusMedia[userId]} at ${DateTime.now()}');
    setState(() {
      _hasUnreadStatus[userId] = false;
    });
    Navigator.pushNamed(
      context,
      '/status',
      arguments: {'userId': userId, 'media': _statusMedia[userId]},
    );
  }

  Widget _buildVerifiedBadge() {
    return ZoomIn(
      duration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(left: 8.0),
        child: Image.network(
          'https://static.vecteezy.com/system/resources/previews/010/926/944/non_2x/3d-verification-badge-icon-element-for-verified-account-white-check-with-blue-badge-illustration-interface-design-vector.jpg',
          width: 16,
          height: 16,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9, // Constrain to 90% of screen width
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFFFF6200).withOpacity(0.3),
              width: 2,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.dashboard, color: Colors.white),
                    onPressed: () {
                      if (mounted) {
                        Navigator.pushNamed(context, '/dashboard');
                      }
                    },
                    tooltip: 'Dashboard',
                  ),
                  Text(
                    'Dashboard',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chat, color: Colors.grey),
                    onPressed: null, // Disabled since we're on ChatListScreen
                    tooltip: 'Chats',
                  ),
                  Text(
                    'Chats',
                    style: GoogleFonts.poppins(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.message, color: Colors.white),
                    onPressed: _createNewChat,
                    tooltip: 'New Chat',
                  ),
                  Text(
                    'New Chat',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    print('DEBUG: Building UI, chats: ${_chats.length}, filtered: ${_filteredChats.length}, loading: $_isLoading');

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                FadeInDown(
                  duration: const Duration(milliseconds: 300),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: GlassmorphicContainer(
                      width: double.infinity,
                      height: 50,
                      borderRadius: 16,
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
                      child: TextField(
                        controller: _searchController,
                        style: GoogleFonts.poppins(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search chats...',
                          hintStyle: GoogleFonts.poppins(color: Colors.white70),
                          prefixIcon: ZoomIn(
                            duration: const Duration(milliseconds: 300),
                            child: const Icon(Icons.search, color: Color(0xFFFF6200)),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? Center(child: SpinKitPulse(color: const Color(0xFFFF6200), size: 50))
                      : RefreshIndicator(
                          onRefresh: () async {
                            await _loadNickUsers();
                            await _fetchChatsAndStatuses();
                          },
                          color: const Color(0xFFFF6200),
                          child: _errorMessage != null
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        FadeInUp(
                                          duration: const Duration(milliseconds: 300),
                                          child: Text(
                                            _errorMessage!,
                                            style: GoogleFonts.poppins(
                                              color: Colors.redAccent,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        FadeInUp(
                                          duration: const Duration(milliseconds: 400),
                                          child: ElevatedButton(
                                            onPressed: () async {
                                              await _loadNickUsers();
                                              await _fetchChatsAndStatuses();
                                            },
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFFFF6200),
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                                              elevation: 6,
                                            ),
                                            child: Text(
                                              'Retry',
                                              style: GoogleFonts.poppins(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : _filteredChats.isEmpty
                                  ? Center(
                                      child: FadeInUp(
                                        duration: const Duration(milliseconds: 500),
                                        child: Text(
                                          _isSearching
                                              ? 'No chats match your search'
                                              : 'No chats yet. Start a new one!',
                                          style: GoogleFonts.poppins(
                                            color: Colors.white70,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      physics: const BouncingScrollPhysics(),
                                      itemCount: _filteredChats.length,
                                      itemBuilder: (context, index) {
                                        final chat = _filteredChats[index];
                                        final isGroup = chat['is_group'] as bool;
                                        final otherUserId = chat['other_user_id'] as int? ?? 0;
                                        final displayName = _nicknames[otherUserId] ?? chat['username'] ?? 'Unknown';
                                        final lastMessage = chat['last_message']?.toString() ?? 'No messages';
                                        final lastMessageTime = _formatTime(chat['last_message_time']);
                                        final unreadCount = chat['unread_count'] ?? 0;
                                        final profilePhotoUrl = _profilePhotos[otherUserId] ?? '';
                                        final hasStatus = _statusMedia[otherUserId] != null && (_statusMedia[otherUserId].toString().isNotEmpty);
                                        final hasUnreadStatus = _hasUnreadStatus[otherUserId] ?? false;
                                        final isVerified = _verifiedUsers[otherUserId] ?? false;

                                        return FadeInUp(
                                          duration: Duration(milliseconds: 300 + (index * 100)),
                                          child: GestureDetector(
                                            onTap: () async {
                                              print('DEBUG: Navigating to chat ID: ${chat['id']} at ${DateTime.now()}');
                                              final result = await Navigator.pushNamed(
                                                context,
                                                '/chat',
                                                arguments: {
                                                  'chatId': chat['id'] as int,
                                                  'chatName': displayName,
                                                  'isGroup': isGroup,
                                                  'userId': AuthState.userId ?? 0,
                                                },
                                              );
                                              if (result == true && mounted) {
                                                await _loadNickUsers();
                                                await _fetchChatsAndStatuses();
                                                print('DEBUG: Refreshed chats after chat screen');
                                              }
                                            },
                                            onLongPress: !isGroup
                                                ? () {
                                                    showModalBottomSheet(
                                                      context: context,
                                                      backgroundColor: Colors.transparent,
                                                      builder: (context) => GlassmorphicContainer(
                                                        width: double.infinity,
                                                        height: 140,
                                                        borderRadius: 16,
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
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            ListTile(
                                                              leading: ZoomIn(
                                                                duration: const Duration(milliseconds: 300),
                                                                child: const Icon(Icons.edit, color: Color(0xFFFF6200)),
                                                              ),
                                                              title: Text(
                                                                'Set Nickname',
                                                                style: GoogleFonts.poppins(
                                                                  fontSize: 16,
                                                                  color: Colors.white,
                                                                ),
                                                              ),
                                                              onTap: () {
                                                                Navigator.pop(context);
                                                                _setNickname(otherUserId, chat['username'] ?? 'Unknown', chat['id']);
                                                              },
                                                            ),
                                                            ListTile(
                                                              leading: ZoomIn(
                                                                duration: const Duration(milliseconds: 300),
                                                                child: const Icon(Icons.delete, color: Colors.redAccent),
                                                              ),
                                                              title: Text(
                                                                'Delete Chat',
                                                                style: GoogleFonts.poppins(
                                                                  color: Colors.redAccent,
                                                                  fontSize: 16,
                                                                ),
                                                              ),
                                                              onTap: () {
                                                                Navigator.pop(context);
                                                                _deleteChat(chat['id']);
                                                              },
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                : null,
                                            child: GlassmorphicContainer(
                                              width: double.infinity,
                                              height: 80,
                                              borderRadius: 12,
                                              blur: 15,
                                              alignment: Alignment.center,
                                              border: 1,
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
                                                  const Color(0xFFFF6200).withOpacity(0.2),
                                                  Colors.transparent,
                                                ],
                                              ),
                                              child: ListTile(
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                                leading: GestureDetector(
                                                  onTap: !isGroup && hasStatus
                                                      ? () => _viewStatus(otherUserId)
                                                      : null,
                                                  child: Stack(
                                                    alignment: Alignment.center,
                                                    children: [
                                                      CircleAvatar(
                                                        radius: 24,
                                                        backgroundColor: profilePhotoUrl.isEmpty
                                                            ? const Color(0xFFFF6200)
                                                            : Colors.transparent,
                                                        backgroundImage: profilePhotoUrl.isNotEmpty
                                                            ? NetworkImage(profilePhotoUrl)
                                                            : null,
                                                        child: profilePhotoUrl.isEmpty
                                                            ? Text(
                                                                displayName.isNotEmpty ? displayName[0].toUpperCase() : 'C',
                                                                style: GoogleFonts.poppins(
                                                                  color: Colors.white,
                                                                  fontWeight: FontWeight.w600,
                                                                  fontSize: 18,
                                                                ),
                                                              )
                                                            : null,
                                                      ),
                                                      if (hasStatus && !isGroup)
                                                        Container(
                                                          width: 52,
                                                          height: 52,
                                                          decoration: BoxDecoration(
                                                            shape: BoxShape.circle,
                                                            border: Border.all(
                                                              color: hasUnreadStatus ? Colors.green : Colors.white70,
                                                              width: 2,
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                title: Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        displayName,
                                                        style: GoogleFonts.poppins(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w600,
                                                          color: Colors.white,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    if (!isGroup && isVerified)
                                                      _buildVerifiedBadge(),
                                                  ],
                                                ),
                                                subtitle: Text(
                                                  lastMessage,
                                                  style: GoogleFonts.poppins(
                                                    fontSize: 12,
                                                    color: Colors.white70,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                trailing: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      lastMessageTime,
                                                      style: GoogleFonts.poppins(
                                                        fontSize: 12,
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                    if (unreadCount > 0)
                                                      ZoomIn(
                                                        duration: const Duration(milliseconds: 300),
                                                        child: Container(
                                                          padding: const EdgeInsets.all(8),
                                                          decoration: const BoxDecoration(
                                                            color: Color(0xFFFF6200),
                                                            shape: BoxShape.circle,
                                                          ),
                                                          child: Text(
                                                            unreadCount.toString(),
                                                            style: GoogleFonts.poppins(
                                                              color: Colors.white,
                                                              fontSize: 12,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                ),
                ),
              ],
            ),
          ),
          _buildBottomNavigationBar(),
        ],
      ),
    );
  }
}

class StatusScreen extends StatefulWidget {
  final int userId;
  final dynamic media;

  const StatusScreen({super.key, required this.userId, required this.media});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  VideoPlayerController? _videoController;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    print('DEBUG: Initializing StatusScreen for user ${widget.userId}, media: ${widget.media} at ${DateTime.now()}');
    _initializeMedia();
  }

  void _initializeMedia() {
    if (widget.media is String && widget.media.toString().endsWith('.mp4')) {
      _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.media))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _videoController?.play();
              _isPlaying = true;
              print('DEBUG: Video initialized and playing for ${widget.userId}');
            });
          }
        }).catchError((e) {
          print('DEBUG: Video initialization error: $e');
        });
    } else {
      _videoController = null;
      print('DEBUG: No video, assuming photo or null media');
    }
  }

  @override
  void dispose() {
    print('DEBUG: Disposing StatusScreen for user ${widget.userId} at ${DateTime.now()}');
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: widget.media != null && widget.media.toString().isNotEmpty
                ? _videoController != null && _videoController!.value.isInitialized
                    ? GestureDetector(
                        onTap: () {
                          setState(() {
                            _isPlaying ? _videoController!.pause() : _videoController!.play();
                            _isPlaying = !_isPlaying;
                            print('DEBUG: Video ${_isPlaying ? 'playing' : 'paused'} for user ${widget.userId}');
                          });
                        },
                        child: SizedBox.expand(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: _videoController!.value.size.width,
                              height: _videoController!.value.size.height,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  VideoPlayer(_videoController!),
                                  if (!_isPlaying)
                                    const Icon(
                                      Icons.play_circle_fill,
                                      color: Colors.white70,
                                      size: 50,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: ClipRect(
                          child: Image.network(
                            widget.media.toString(),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              print('DEBUG: Image load error: $error');
                              return Center(
                                child: Text(
                                  'Failed to load image',
                                  style: GoogleFonts.poppins(color: Colors.white, fontSize: 16),
                                ),
                              );
                            },
                          ),
                        ),
                      )
                : Center(
                    child: Text(
                      'No status media available',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 16),
                    ),
                  ),
          ),
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () {
                print('DEBUG: Closing StatusScreen for user ${widget.userId} at ${DateTime.now()}');
                Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}