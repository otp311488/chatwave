
import 'dart:convert';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';

import 'main.dart'; // Import main.dart for HttpService and AuthState

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _chatNameController = TextEditingController();
  final _searchController = TextEditingController();
  List<dynamic> _allUsers = [];
  List<dynamic> _filteredUsers = [];
  List<dynamic> _selectedUsers = [];
  bool _isGroup = false;
  bool _isLoading = true;
  bool _isSearching = false;
  String? _chatNameError;

  @override
  void initState() {
    super.initState();
    print('DEBUG: initState called, AuthState.userId: ${AuthState.userId}');
    if (AuthState.userId == null || AuthState.userId == 0) {
      print('DEBUG: Invalid userId, redirecting to auth');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/auth');
      });
    } else {
      _fetchUsers();
    }
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    print('DEBUG: dispose called');
    _chatNameController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchUsers({int retryCount = 0}) async {
    if (!mounted) return;
    const maxRetries = 3;
    print('DEBUG: _fetchUsers started, retryCount: $retryCount');
    setState(() => _isLoading = true);

    try {
      final response = await HttpService.get('/user.php', query: {'action': 'get_users'});
      print('DEBUG: get_users response status: ${response.statusCode}, body: ${response.body}');

      if (response.statusCode == 429 && retryCount < maxRetries) {
        print('DEBUG: Rate limit hit, retrying after 5 seconds');
        await Future.delayed(const Duration(seconds: 5));
        return _fetchUsers(retryCount: retryCount + 1);
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body.trim());
        print('DEBUG: Parsed data: $data');
        if (data['status'] == 'success' && data['users'] != null) {
          final currentUserId = AuthState.userId ?? 0;
          print('DEBUG: Current user ID: $currentUserId');
          final usersBeforeFilter = data['users'].map((user) {
            final userId = user['id'] is String ? int.tryParse(user['id']) ?? 0 : user['id'];
            return {
              'id': userId,
              'username': user['username'] ?? user['email'] ?? 'Unknown',
              'email': user['email'] ?? 'No email',
              'verified': user['verified'] == true || user['verified'] == '1',
            };
          }).toList();
          print('DEBUG: Users before filter: $usersBeforeFilter');
          final users = usersBeforeFilter.where((user) => user['id'] != currentUserId && user['id'] != 0).toList();
          print('DEBUG: Filtered users: $users');
          if (mounted) {
            setState(() {
              _allUsers = users;
              _filteredUsers = [];
              _isLoading = false;
            });
            await Future.delayed(Duration.zero);
            print('DEBUG: _allUsers length: ${_allUsers.length}, _filteredUsers length: ${_filteredUsers.length}');
          }
        } else if (mounted) {
          print('DEBUG: Failed to fetch users, message: ${data['message'] ?? 'Invalid response'}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Failed to fetch users',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() => _isLoading = false);
        }
      } else if (await HttpService.handleSessionError(response, retryCount, '/user.php') && retryCount < maxRetries) {
        print('DEBUG: Session error detected, retrying');
        return _fetchUsers(retryCount: retryCount + 1);
      } else if (mounted) {
        print('DEBUG: Failed to fetch users, status: ${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Server error: ${response.statusCode}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isLoading = false);
      }
    } catch (e, stackTrace) {
      print('DEBUG: Fetch users error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error fetching users: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _onSearchChanged() async {
    final query = _searchController.text.trim();
    print('DEBUG: Search query: "$query"');
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _filteredUsers = [];
          _isSearching = false;
        });
        print('DEBUG: Search cleared, _filteredUsers length: ${_filteredUsers.length}');
      }
      return;
    }

    setState(() => _isSearching = true);
    try {
      final response = await HttpService.get(
        '/user.php',
        query: {'action': 'search_users', 'query': query},
      );
      print('DEBUG: search_users response status: ${response.statusCode}, body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body.trim());
        print('DEBUG: Search users data: $data');
        if (data['status'] == 'success' && data['users'] != null) {
          final currentUserId = AuthState.userId ?? 0;
          final users = data['users'].map((user) {
            final userId = user['id'] is String ? int.tryParse(user['id']) ?? 0 : user['id'];
            return {
              'id': userId,
              'username': user['username'] ?? user['email'] ?? 'Unknown',
              'email': user['email'] ?? 'No email',
              'verified': user['verified'] == true || user['verified'] == '1',
            };
          }).where((user) => user['id'] != currentUserId && user['id'] != 0).toList();
          print('DEBUG: Processed search users: $users');
          if (mounted) {
            setState(() {
              _filteredUsers = users;
              _isSearching = false;
            });
            await Future.delayed(Duration.zero);
            print('DEBUG: _filteredUsers length after search: ${_filteredUsers.length}');
          }
        } else if (mounted) {
          print('DEBUG: Failed to search users, message: ${data['message'] ?? 'Invalid response'}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Failed to search users',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() => _isSearching = false);
        }
      } else if (await HttpService.handleSessionError(response, 1, '/user.php') && mounted) {
        print('DEBUG: Session error during search, retrying');
        await _onSearchChanged();
      } else if (mounted) {
        print('DEBUG: Failed to search users, status: ${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Server error: ${response.statusCode}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isSearching = false);
      }
    } catch (e, stackTrace) {
      print('DEBUG: Search users error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error searching users: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _isSearching = false);
      }
    }
  }

  void _addUserToSelected(dynamic user) {
    print('DEBUG: Adding user: ${user['username']} (ID: ${user['id']})');
    if (!_selectedUsers.any((u) => u['id'] == user['id'])) {
      setState(() {
        _selectedUsers.add(user);
        _searchController.clear();
        _filteredUsers = [];
      });
      print('DEBUG: _selectedUsers length: ${_selectedUsers.length}');
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'User already selected',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _createChat() async {
    if (!mounted) return;
    final chatName = _chatNameController.text.trim();
    print('DEBUG: Creating chat, isGroup: $_isGroup, chatName: $chatName, selectedUsers: ${_selectedUsers.length}');
    if (_isGroup && (chatName.isEmpty || chatName.length < 3)) {
      setState(() => _chatNameError = 'Chat name must be at least 3 characters');
      return;
    }
    if (_selectedUsers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please select at least one user',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (_isGroup && _selectedUsers.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'At least two members are required for a group chat',
            style: GoogleFonts.poppins(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final payload = {
        'is_group': _isGroup ? 1 : 0,
        'chat_name': _isGroup ? chatName : null,
        'participant_ids': _selectedUsers.map((u) => u['id']).toList(),
      };
      print('DEBUG: create_chat payload: $payload');
      final response = await HttpService.post(
        'chat.php?action=create_chat',
        body: payload,
      );
      print('DEBUG: create_chat response status: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body.trim());
        if (data['status'] == 'success') {
          final chatId = data['chat_id'] is String ? int.tryParse(data['chat_id']) : data['chat_id'];
          if (chatId == null || chatId <= 0) {
            throw Exception('Invalid chat_id received: $chatId');
          }
          if (!mounted) return;
          Navigator.pop(context, true);
          Navigator.pushNamed(
            context,
            '/chat',
            arguments: {
              'chatId': chatId,
              'chatName': _isGroup ? chatName : _selectedUsers[0]['username'],
              'isGroup': _isGroup,
              'userId': AuthState.userId ?? 0,
            },
          );
        } else if (mounted) {
          print('DEBUG: Failed to create chat, message: ${data['message']}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Failed to create chat',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else if (response.statusCode == 500) {
        print('DEBUG: Internal server error on create_chat');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Server error: Unable to create chat. Please try again later.',
                style: GoogleFonts.poppins(color: Colors.white),
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else if (await HttpService.handleSessionError(response, 1, 'chat.php') && mounted) {
        print('DEBUG: Session error during chat creation, retrying');
        await _createChat();
      } else if (mounted) {
        print('DEBUG: Failed to create chat, status: ${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Server error: ${response.statusCode}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e, stackTrace) {
      print('DEBUG: Create chat error: $e\nStackTrace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error creating chat: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        print('DEBUG: _createChat completed, _isLoading: $_isLoading');
      }
    }
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
                    icon: const Icon(Icons.chat, color: Colors.white),
                    onPressed: () {
                      if (mounted) {
                        Navigator.pushNamed(context, '/chat_list');
                      }
                    },
                    tooltip: 'Chats',
                  ),
                  Text(
                    'Chats',
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
                    icon: const Icon(Icons.message, color: Colors.grey),
                    onPressed: null, // Disabled since we're on NewChatScreen
                    tooltip: 'New Chat',
                  ),
                  Text(
                    'New Chat',
                    style: GoogleFonts.poppins(
                      color: Colors.grey,
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
    print('DEBUG: Building UI, _isLoading: $_isLoading, _isSearching: $_isSearching, '
        '_filteredUsers length: ${_filteredUsers.length}, _selectedUsers length: ${_selectedUsers.length}');

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                FadeInDown(
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      border: Border(bottom: BorderSide(color: const Color(0xFFFF6200).withOpacity(0.3))),
                    ),
                    child: Row(
                      children: [
                        ZoomIn(
                          duration: const Duration(milliseconds: 300),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back, color: Color(0xFFFF6200)),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'New Chat',
                            style: GoogleFonts.poppins(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FadeInUp(
                            duration: const Duration(milliseconds: 400),
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
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: _isGroup,
                                    onChanged: (value) => setState(() {
                                      _isGroup = value ?? false;
                                      _chatNameError = null;
                                      if (!_isGroup && _selectedUsers.length > 1) {
                                        _selectedUsers = _selectedUsers.sublist(0, 1);
                                      }
                                    }),
                                    activeColor: const Color(0xFFFF6200),
                                    checkColor: Colors.white,
                                    side: BorderSide(color: Colors.white.withOpacity(0.5)),
                                  ).animate().scale(duration: 300.ms),
                                  Text(
                                    'Create a group chat',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (_isGroup) ...[
                            const SizedBox(height: 16),
                            FadeInUp(
                              duration: const Duration(milliseconds: 500),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 60,
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
                                  controller: _chatNameController,
                                  style: GoogleFonts.poppins(color: Colors.white),
                                  decoration: InputDecoration(
                                    hintText: 'Group Name (3-30 characters)',
                                    hintStyle: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
                                    prefixIcon: const Icon(Icons.group, color: Color(0xFFFF6200), size: 18),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                                    errorText: _chatNameError,
                                    errorStyle: GoogleFonts.poppins(color: Colors.redAccent, fontSize: 9),
                                  ),
                                  maxLength: 30,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FadeInUp(
                            duration: const Duration(milliseconds: 600),
                            child: GlassmorphicContainer(
                              width: double.infinity,
                              height: 60,
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
                                  hintText: 'Search users by username or email...',
                                  hintStyle: GoogleFonts.poppins(color: Colors.white70, fontSize: 12),
                                  prefixIcon: ZoomIn(
                                    duration: const Duration(milliseconds: 300),
                                    child: const Icon(Icons.search, color: Color(0xFFFF6200), size: 18),
                                  ),
                                  suffixIcon: ZoomIn(
                                    duration: const Duration(milliseconds: 300),
                                    child: IconButton(
                                      icon: const Icon(Icons.send, color: Color(0xFFFF6200), size: 18),
                                      onPressed: _isLoading ? null : _createChat,
                                    ),
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _isLoading || _isSearching
                              ? Center(child: SpinKitPulse(color: const Color(0xFFFF6200), size: 50))
                              : _filteredUsers.isEmpty && _searchController.text.isNotEmpty
                                  ? Center(
                                      child: Text(
                                        'No users found',
                                        style: GoogleFonts.poppins(
                                          fontSize: 16,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    )
                                  : _filteredUsers.isNotEmpty
                                      ? Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (_selectedUsers.isNotEmpty) ...[
                                              Text(
                                                'Selected Users',
                                                style: GoogleFonts.poppins(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              ListView.builder(
                                                shrinkWrap: true,
                                                physics: const NeverScrollableScrollPhysics(),
                                                itemCount: _selectedUsers.length,
                                                itemBuilder: (context, index) {
                                                  final user = _selectedUsers[index];
                                                  return FadeInUp(
                                                    duration: Duration(milliseconds: 300 + (index * 100)),
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
                                                          const Color(0xFFFF6200).withOpacity(0.3),
                                                          Colors.transparent,
                                                        ],
                                                      ),
                                                      child: CheckboxListTile(
                                                        value: true,
                                                        onChanged: (value) {
                                                          setState(() {
                                                            _selectedUsers.removeAt(index);
                                                          });
                                                        },
                                                        activeColor: const Color(0xFFFF6200),
                                                        checkColor: Colors.white,
                                                        title: Row(
                                                          children: [
                                                            CircleAvatar(
                                                              radius: 16,
                                                              backgroundColor: const Color(0xFFFF6200),
                                                              child: Text(
                                                                user['username'].substring(0, 1).toUpperCase(),
                                                                style: GoogleFonts.poppins(
                                                                  color: Colors.white,
                                                                  fontWeight: FontWeight.w600,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 12),
                                                            Expanded(
                                                              child: Text(
                                                                user['username'],
                                                                style: GoogleFonts.poppins(
                                                                  fontSize: 16,
                                                                  fontWeight: FontWeight.w600,
                                                                  color: Colors.white,
                                                                ),
                                                                overflow: TextOverflow.ellipsis,
                                                              ),
                                                            ),
                                                            if (user['verified'])
                                                              ZoomIn(
                                                                duration: const Duration(milliseconds: 300),
                                                                child: Padding(
                                                                  padding: const EdgeInsets.only(left: 8.0),
                                                                  child: Icon(
                                                                    Icons.verified,
                                                                    color: Colors.blue.shade400,
                                                                    size: 20,
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                        subtitle: Text(
                                                          user['email'],
                                                          style: GoogleFonts.poppins(
                                                            fontSize: 12,
                                                            color: Colors.white70,
                                                          ),
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                        controlAffinity: ListTileControlAffinity.trailing,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                              const SizedBox(height: 16),
                                            ],
                                            ListView.builder(
                                              shrinkWrap: true,
                                              physics: const NeverScrollableScrollPhysics(),
                                              itemCount: _filteredUsers.length,
                                              itemBuilder: (context, index) {
                                                final user = _filteredUsers[index];
                                                if (_selectedUsers.any((u) => u['id'] == user['id'])) {
                                                  return const SizedBox.shrink();
                                                }
                                                return FadeInUp(
                                                  duration: Duration(milliseconds: 300 + (index * 100)),
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
                                                        const Color(0xFFFF6200).withOpacity(0.3),
                                                        Colors.transparent,
                                                      ],
                                                    ),
                                                    child: ListTile(
                                                      onTap: () => _addUserToSelected(user),
                                                      leading: CircleAvatar(
                                                        radius: 16,
                                                        backgroundColor: const Color(0xFFFF6200),
                                                        child: Text(
                                                          user['username'].substring(0, 1).toUpperCase(),
                                                          style: GoogleFonts.poppins(
                                                            color: Colors.white,
                                                            fontWeight: FontWeight.w600,
                                                          ),
                                                        ),
                                                      ),
                                                      title: Text(
                                                        user['username'],
                                                        style: GoogleFonts.poppins(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w600,
                                                          color: Colors.white,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                      subtitle: Text(
                                                        user['email'],
                                                        style: GoogleFonts.poppins(
                                                          fontSize: 12,
                                                          color: Colors.white70,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        )
                                      : const SizedBox.shrink(),
                          const SizedBox(height: 16),
                        ],
                      ),
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
