import 'dart:convert';
import 'dart:io';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'main.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  _PrivacyScreenState createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  final ImagePicker _picker = ImagePicker();
  String? _profilePhotoUrl;
  String? _localProfilePhotoPath;
  String? _statusMediaUrl;
  String? _localStatusMediaPath;
  String? _coverPhotoUrl;
  String? _localCoverPhotoPath;
  bool _isPrivate = false;
  bool _isUploading = false;
  bool _isLoading = false;
  VideoPlayerController? _statusVideoController;
  String _profileVisibility = 'Everyone';
  String _statusVisibility = 'My contacts';
  String _coverVisibility = 'Everyone';
  String _lastSeenVisibility = 'Nobody';
  String _aboutVisibility = 'My contacts';
  String _groupsVisibility = 'My contacts';

  @override
  void initState() {
    super.initState();
    _loadPrivacySettings();
  }

  @override
  void dispose() {
    _statusVideoController?.dispose();
    super.dispose();
  }

  Future<void> _loadPrivacySettings() async {
    setState(() => _isLoading = true);
    try {
      final response = await HttpService.get('/user.php', query: {
        'action': 'get_privacy_settings',
        'user_id': AuthState.userId.toString(),
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          const allowedValues = ['Everyone', 'My contacts', 'Nobody'];
          setState(() {
            _isPrivate = data['is_private'] == true || data['is_private'] == '1';
            _profilePhotoUrl = data['profile_photo_url'];
            _statusMediaUrl = data['status_photo_url'] ?? data['status_video_url'];
            if (_statusMediaUrl != null && _statusMediaUrl!.endsWith('.mp4')) {
              _statusVideoController?.dispose();
              _statusVideoController = VideoPlayerController.networkUrl(Uri.parse(_statusMediaUrl!))
                ..initialize().then((_) {
                  if (mounted) setState(() {});
                });
            } else {
              _statusVideoController?.dispose();
              _statusVideoController = null;
            }
            _coverPhotoUrl = data['cover_photo_url'];
            _profileVisibility = allowedValues.contains(data['profile_visibility'])
                ? data['profile_visibility']
                : 'Everyone';
            _statusVisibility = allowedValues.contains(data['status_visibility'])
                ? data['status_visibility']
                : 'My contacts';
            _coverVisibility = allowedValues.contains(data['cover_visibility'])
                ? data['cover_visibility']
                : 'Everyone';
            _lastSeenVisibility = allowedValues.contains(data['last_seen_visibility'])
                ? data['last_seen_visibility']
                : 'Nobody';
            _aboutVisibility = allowedValues.contains(data['about_visibility'])
                ? data['about_visibility']
                : 'My contacts';
            _groupsVisibility = allowedValues.contains(data['groups_visibility'])
                ? data['groups_visibility']
                : 'My contacts';
          });
        } else {
          throw Exception(data['message'] ?? 'Failed to load privacy settings');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load privacy settings: $e', style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickMedia(String type) async {
    XFile? pickedFile;
    if (type == 'status') {
      final mediaType = await _showMediaTypeDialog();
      if (mediaType == null) return; // User cancelled dialog
      if (mediaType == 'photo') {
        pickedFile = await _picker.pickImage(source: ImageSource.gallery);
      } else if (mediaType == 'video') {
        pickedFile = await _picker.pickVideo(source: ImageSource.gallery);
      }
    } else {
      pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    }

    if (pickedFile != null && mounted) {
      setState(() {
        if (type == 'profile') _localProfilePhotoPath = pickedFile!.path;
        if (type == 'status') {
          _localStatusMediaPath = pickedFile!.path;
          if (pickedFile.path.endsWith('.mp4')) {
            _statusVideoController?.dispose();
            _statusVideoController = VideoPlayerController.file(File(pickedFile.path))
              ..initialize().then((_) {
                if (mounted) setState(() {});
              });
          } else {
            _statusVideoController?.dispose();
            _statusVideoController = null;
          }
        }
        if (type == 'cover') _localCoverPhotoPath = pickedFile!.path;
      });
      await _uploadMedia(pickedFile.path, type);
    }
  }

  Future<String?> _showMediaTypeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black.withOpacity(0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Select Media Type',
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              GlassmorphicContainer(
                width: double.infinity,
                height: 50,
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
                child: GestureDetector(
                  onTap: () => Navigator.pop(context, 'photo'),
                  child: Center(
                    child: Text(
                      'Photo',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              GlassmorphicContainer(
                width: double.infinity,
                height: 50,
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
                child: GestureDetector(
                  onTap: () => Navigator.pop(context, 'video'),
                  child: Center(
                    child: Text(
                      'Video',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              GlassmorphicContainer(
                width: double.infinity,
                height: 50,
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
                    Colors.redAccent.withOpacity(0.3),
                    Colors.transparent,
                  ],
                ),
                child: GestureDetector(
                  onTap: () => Navigator.pop(context, null),
                  child: Center(
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _uploadMedia(String path, String type) async {
    setState(() => _isUploading = true);
    try {
      final file = File(path);
      final mediaType = path.endsWith('.mp4') ? 'video' : 'photo';
      final url = await HttpService.uploadFile(file, mediaType, onProgress: (progress) {
        if (mounted) {
          setState(() {}); // Update UI for progress if needed
          print('Upload progress: $progress');
        }
      });
      if (url == null) {
        throw Exception('Upload failed: No URL returned');
      }

      final response = await HttpService.post('/user.php', body: {
        'action': type == 'status' ? 'update_status_media' : 'update_${type}_photo',
        'user_id': AuthState.userId.toString(),
        'media_url': url,
        'media_type': type == 'status' ? mediaType : 'photo',
      });
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          setState(() {
            if (type == 'profile') {
              _profilePhotoUrl = url;
              _localProfilePhotoPath = null;
            }
            if (type == 'status') {
              _statusMediaUrl = url;
              _localStatusMediaPath = null;
              if (url.endsWith('.mp4')) {
                _statusVideoController?.dispose();
                _statusVideoController = VideoPlayerController.networkUrl(Uri.parse(url))
                  ..initialize().then((_) {
                    if (mounted) setState(() {});
                  });
              } else {
                _statusVideoController?.dispose();
                _statusVideoController = null;
              }
            }
            if (type == 'cover') {
              _coverPhotoUrl = url;
              _localCoverPhotoPath = null;
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${type.capitalize()} uploaded successfully', style: GoogleFonts.poppins(color: Colors.white)),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          throw Exception(data['message'] ?? 'Upload failed');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to upload ${type}: $e', style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _togglePrivacy() async {
    setState(() => _isLoading = true);
    try {
      final response = await HttpService.post('/user.php', body: {
        'action': 'toggle_privacy',
        'user_id': AuthState.userId.toString(),
        'is_private': (!_isPrivate).toString(),
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          setState(() => _isPrivate = !_isPrivate);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Privacy updated successfully', style: GoogleFonts.poppins(color: Colors.white)),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          throw Exception(data['message'] ?? 'Failed to update privacy');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update privacy: $e', style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateVisibility(String type, String value) async {
    if (!mounted) return;
    final previousValues = {
      'profile': _profileVisibility,
      'status': _statusVisibility,
      'cover': _coverVisibility,
      'last_seen': _lastSeenVisibility,
      'about': _aboutVisibility,
      'groups': _groupsVisibility,
    };
    setState(() {
      _isLoading = true;
      if (type == 'profile') _profileVisibility = value;
      if (type == 'status') _statusVisibility = value;
      if (type == 'cover') _coverVisibility = value;
      if (type == 'last_seen') _lastSeenVisibility = value;
      if (type == 'about') _aboutVisibility = value;
      if (type == 'groups') _groupsVisibility = value;
    });
    try {
      final response = await HttpService.post('/user.php', body: {
        'action': 'update_visibility',
        'user_id': AuthState.userId.toString(),
        'type': type,
        'value': value,
      });
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${type.capitalize()} visibility updated', style: GoogleFonts.poppins(color: Colors.white)),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          throw Exception(data['message'] ?? 'Failed to update visibility');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (type == 'profile') _profileVisibility = previousValues['profile']!;
          if (type == 'status') _statusVisibility = previousValues['status']!;
          if (type == 'cover') _coverVisibility = previousValues['cover']!;
          if (type == 'last_seen') _lastSeenVisibility = previousValues['last_seen']!;
          if (type == 'about') _aboutVisibility = previousValues['about']!;
          if (type == 'groups') _groupsVisibility = previousValues['groups']!;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update ${type} visibility: $e', style: GoogleFonts.poppins(color: Colors.white)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  ImageProvider _getImageProvider({required String? url, String? localPath}) {
    if (url != null && url.isNotEmpty) {
      return NetworkImage(url);
    } else if (localPath != null && localPath.isNotEmpty) {
      return FileImage(File(localPath));
    }
    return const AssetImage('assets/placeholder.png');
  }

  Widget _buildBottomNavigationBar() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
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
                    icon: const Icon(Icons.message, color: Colors.white),
                    onPressed: () {
                      if (mounted) {
                        Navigator.pushNamed(context, '/new_chat');
                      }
                    },
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

  Widget _buildVisibilityDropdown(String type, String value) {
    return GlassmorphicContainer(
      width: 120,
      height: 40,
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
      child: PopupMenuButton<String>(
        initialValue: value,
        onSelected: (newValue) => _updateVisibility(type, newValue),
        enabled: !_isLoading,
        itemBuilder: (context) => ['Everyone', 'My contacts', 'Nobody'].map((String choice) {
          return PopupMenuItem<String>(
            value: choice,
            child: Text(
              choice,
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: Colors.white,
              ),
            ),
          );
        }).toList(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: _isLoading ? Colors.white70 : Colors.white,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down,
                color: _isLoading ? Colors.white70 : Colors.white,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.7),
        elevation: 0,
        title: Text(
          'Privacy',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFFF6200)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: _isLoading
                ? FadeInUp(
                    duration: const Duration(milliseconds: 300),
                    child: GlassmorphicContainer(
                      width: double.infinity,
                      height: 100,
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SpinKitPulse(color: Color(0xFFFF6200), size: 50),
                          const SizedBox(height: 8),
                          Text(
                            'Loading...',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        FadeInUp(
                          duration: const Duration(milliseconds: 300),
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
                            child: Text(
                              'Privacy Checkup',
                              style: GoogleFonts.poppins(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Account Privacy',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Switch(
                                    value: _isPrivate,
                                    onChanged: _isLoading ? null : (_) => _togglePrivacy(),
                                    activeColor: const Color(0xFFFF6200),
                                    inactiveThumbColor: Colors.white70,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 500),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 20,
                                        backgroundImage: _getImageProvider(
                                          url: _profilePhotoUrl,
                                          localPath: _localProfilePhotoPath,
                                        ),
                                        child: _profilePhotoUrl == null && _localProfilePhotoPath == null
                                            ? const Icon(Icons.error, color: Colors.red)
                                            : null,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Profile Photo',
                                        style: GoogleFonts.poppins(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  _buildVisibilityDropdown('profile', _profileVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 600),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: _statusMediaUrl != null || _localStatusMediaPath != null
                                              ? (_statusVideoController != null &&
                                                      _statusVideoController!.value.isInitialized
                                                  ? VideoPlayer(_statusVideoController!)
                                                  : Image(
                                                      image: _getImageProvider(
                                                        url: _statusMediaUrl,
                                                        localPath: _localStatusMediaPath,
                                                      ),
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (context, error, stackTrace) =>
                                                          const Icon(Icons.error, color: Colors.red),
                                                    ))
                                              : const Icon(Icons.image, color: Color(0xFFFF6200)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Status Media',
                                        style: GoogleFonts.poppins(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  _buildVisibilityDropdown('status', _statusVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 700),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: _coverPhotoUrl != null || _localCoverPhotoPath != null
                                              ? Image(
                                                  image: _getImageProvider(
                                                    url: _coverPhotoUrl,
                                                    localPath: _localCoverPhotoPath,
                                                  ),
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (context, error, stackTrace) =>
                                                      const Icon(Icons.error, color: Colors.red),
                                                )
                                              : const Icon(Icons.image, color: Color(0xFFFF6200)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Cover Photo',
                                        style: GoogleFonts.poppins(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  _buildVisibilityDropdown('cover', _coverVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 800),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Last Seen & Online',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                  _buildVisibilityDropdown('last_seen', _lastSeenVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 900),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'About',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                  _buildVisibilityDropdown('about', _aboutVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 1000),
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
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Groups',
                                    style: GoogleFonts.poppins(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                  _buildVisibilityDropdown('groups', _groupsVisibility),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 1100),
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
                            child: GestureDetector(
                              onTap: () {
                                // Navigate to exclusion management screen
                              },
                              child: Center(
                                child: Text(
                                  'Status Exclusions - Manage',
                                  style: GoogleFonts.poppins(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 1200),
                          child: GlassmorphicContainer(
                            width: double.infinity,
                            height: 50,
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
                            child: GestureDetector(
                              onTap: _isUploading ? null : () => _pickMedia('profile'),
                              child: Center(
                                child: Text(
                                  'Upload Profile Photo',
                                  style: GoogleFonts.poppins(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: _isUploading ? Colors.white70 : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 1300),
                          child: GlassmorphicContainer(
                            width: double.infinity,
                            height: 50,
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
                            child: GestureDetector(
                              onTap: _isUploading ? null : () => _pickMedia('status'),
                              child: Center(
                                child: Text(
                                  'Upload Status Media',
                                  style: GoogleFonts.poppins(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: _isUploading ? Colors.white70 : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FadeInUp(
                          duration: const Duration(milliseconds: 1400),
                          child: GlassmorphicContainer(
                            width: double.infinity,
                            height: 50,
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
                            child: GestureDetector(
                              onTap: _isUploading ? null : () => _pickMedia('cover'),
                              child: Center(
                                child: Text(
                                  'Upload Cover Photo',
                                  style: GoogleFonts.poppins(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: _isUploading ? Colors.white70 : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          _buildBottomNavigationBar(),
        ],
      ),
    );
  }
}

// Extension to capitalize strings for better UI feedback
extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}