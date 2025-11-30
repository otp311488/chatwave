import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:animate_do/animate_do.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'main.dart'; // Import main.dart for HttpService and AuthState

class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => VerificationScreenState();
}

class VerificationScreenState extends State<VerificationScreen> {
  File? _selfieImage;
  File? _idCardImage;
  bool _isVerifying = false;
  String _verificationStatus = '';

  Future<void> _pickImage({required bool isSelfie}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
      );
      if (result != null && result.files.single.path != null && mounted) {
        final file = File(result.files.single.path!);
        setState(() {
          if (isSelfie) {
            _selfieImage = file;
          } else {
            _idCardImage = file;
          }
        });
        debugPrint('Image picked: ${isSelfie ? "Selfie" : "ID Card"} at ${file.path}');
      } else {
        debugPrint('Image picking cancelled or failed');
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (mounted) {
        setState(() {
          _verificationStatus = 'Error picking image';
        });
      }
    }
  }

  Future<img.Image?> _cropFace(File imageFile, Face face) async {
    final bytes = await imageFile.readAsBytes();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) {
      debugPrint('Failed to decode image: ${imageFile.path}');
      return null;
    }

    image = img.adjustColor(image, brightness: 1.1, contrast: 1.2);

    final rect = face.boundingBox;
    final x = rect.left.toInt();
    final y = rect.top.toInt();
    final width = rect.width.toInt();
    final height = rect.height.toInt();

    final cropX = x.clamp(0, image.width);
    final cropY = y.clamp(0, image.height);
    final cropWidth = width.clamp(0, image.width - cropX);
    final cropHeight = height.clamp(0, image.height - cropY);

    img.Image cropped = img.copyCrop(image, x: cropX, y: cropY, width: cropWidth, height: cropHeight);
    img.Image resized = img.copyResize(cropped, width: 112, height: 112);
    return resized;
  }

  double _calculateLandmarkSimilarity(Face face1, Face face2) {
    final angleDiff = (face1.headEulerAngleY! - face2.headEulerAngleY!).abs();
    if (angleDiff > 15.0) {
      debugPrint('Head pose difference too large: $angleDiff degrees');
      return 0.0;
    }

    final landmarks1 = {
      FaceLandmarkType.leftEye: face1.landmarks[FaceLandmarkType.leftEye]?.position,
      FaceLandmarkType.rightEye: face1.landmarks[FaceLandmarkType.rightEye]?.position,
      FaceLandmarkType.noseBase: face1.landmarks[FaceLandmarkType.noseBase]?.position,
      FaceLandmarkType.bottomMouth: face1.landmarks[FaceLandmarkType.bottomMouth]?.position,
      FaceLandmarkType.leftCheek: face1.landmarks[FaceLandmarkType.leftCheek]?.position,
      FaceLandmarkType.rightCheek: face1.landmarks[FaceLandmarkType.rightCheek]?.position,
    };
    final landmarks2 = {
      FaceLandmarkType.leftEye: face2.landmarks[FaceLandmarkType.leftEye]?.position,
      FaceLandmarkType.rightEye: face2.landmarks[FaceLandmarkType.rightEye]?.position,
      FaceLandmarkType.noseBase: face2.landmarks[FaceLandmarkType.noseBase]?.position,
      FaceLandmarkType.bottomMouth: face2.landmarks[FaceLandmarkType.bottomMouth]?.position,
      FaceLandmarkType.leftCheek: face2.landmarks[FaceLandmarkType.leftCheek]?.position,
      FaceLandmarkType.rightCheek: face2.landmarks[FaceLandmarkType.rightCheek]?.position,
    };

    if (landmarks1.values.any((pos) => pos == null) || landmarks2.values.any((pos) => pos == null)) {
      debugPrint('Missing landmarks in one or both faces');
      return 0.0;
    }

    double totalDistance = 0.0;
    int count = 0;

    final eyeDist1 = _distance(
      Point<double>(landmarks1[FaceLandmarkType.leftEye]!.x.toDouble(), landmarks1[FaceLandmarkType.leftEye]!.y.toDouble()),
      Point<double>(landmarks1[FaceLandmarkType.rightEye]!.x.toDouble(), landmarks1[FaceLandmarkType.rightEye]!.y.toDouble()),
    );
    final eyeDist2 = _distance(
      Point<double>(landmarks2[FaceLandmarkType.leftEye]!.x.toDouble(), landmarks2[FaceLandmarkType.leftEye]!.y.toDouble()),
      Point<double>(landmarks2[FaceLandmarkType.rightEye]!.x.toDouble(), landmarks2[FaceLandmarkType.rightEye]!.y.toDouble()),
    );
    if (eyeDist1 == 0 || eyeDist2 == 0) {
      debugPrint('Invalid eye distance');
      return 0.0;
    }

    final pairs = [
      [FaceLandmarkType.leftEye, FaceLandmarkType.noseBase],
      [FaceLandmarkType.rightEye, FaceLandmarkType.noseBase],
      [FaceLandmarkType.noseBase, FaceLandmarkType.bottomMouth],
      [FaceLandmarkType.leftEye, FaceLandmarkType.bottomMouth],
      [FaceLandmarkType.leftCheek, FaceLandmarkType.rightCheek],
      [FaceLandmarkType.leftEye, FaceLandmarkType.leftCheek],
      [FaceLandmarkType.rightEye, FaceLandmarkType.rightCheek],
    ];

    for (final pair in pairs) {
      final dist1 = _distance(
        Point<double>(landmarks1[pair[0]]!.x.toDouble(), landmarks1[pair[0]]!.y.toDouble()),
        Point<double>(landmarks1[pair[1]]!.x.toDouble(), landmarks1[pair[1]]!.y.toDouble()),
      ) / eyeDist1;
      final dist2 = _distance(
        Point<double>(landmarks2[pair[0]]!.x.toDouble(), landmarks2[pair[0]]!.y.toDouble()),
        Point<double>(landmarks2[pair[1]]!.x.toDouble(), landmarks2[pair[1]]!.y.toDouble()),
      ) / eyeDist2;
      totalDistance += (dist1 - dist2).abs();
      count++;
    }

    final avgDistance = totalDistance / count;
    final similarity = max(0.0, 1.0 - avgDistance * 1.5);
    debugPrint('Landmark similarity: $similarity');
    return similarity;
  }

  double _distance(Point<double> p1, Point<double> p2) {
    return sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2));
  }

  Future<void> _verifyImages() async {
    if (_selfieImage == null || _idCardImage == null) {
      setState(() {
        _verificationStatus = 'Please upload both selfie and ID card images';
      });
      debugPrint('Verification attempted without both images');
      return;
    }

    setState(() {
      _isVerifying = true;
      _verificationStatus = 'Our team is verifying, please be patient';
    });

    try {
      final faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableLandmarks: true,
          enableContours: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );

      final selfieInputImage = InputImage.fromFilePath(_selfieImage!.path);
      final idCardInputImage = InputImage.fromFilePath(_idCardImage!.path);

      final List<Face> selfieFaces = await faceDetector.processImage(selfieInputImage);
      final List<Face> idCardFaces = await faceDetector.processImage(idCardInputImage);

      if (selfieFaces.isEmpty || idCardFaces.isEmpty) {
        if (mounted) {
          setState(() {
            _isVerifying = false;
            _verificationStatus = 'Verification Denied: No face detected in one or both images';
          });
        }
        debugPrint('No faces detected: selfieFaces=${selfieFaces.length}, idCardFaces=${idCardFaces.length}');
        return;
      }

      if (selfieFaces.length > 1 || idCardFaces.length > 1) {
        if (mounted) {
          setState(() {
            _isVerifying = false;
            _verificationStatus = 'Verification Denied: Multiple faces detected';
          });
        }
        debugPrint('Multiple faces detected: selfieFaces=${selfieFaces.length}, idCardFaces=${idCardFaces.length}');
        return;
      }

      final selfieFaceImage = await _cropFace(_selfieImage!, selfieFaces.first);
      final idCardFaceImage = await _cropFace(_idCardImage!, idCardFaces.first);

      if (selfieFaceImage == null || idCardFaceImage == null) {
        if (mounted) {
          setState(() {
            _isVerifying = false;
            _verificationStatus = 'Verification Denied: Failed to process images';
          });
        }
        debugPrint('Failed to crop face images');
        return;
      }

      final similarity = _calculateLandmarkSimilarity(selfieFaces.first, idCardFaces.first);
      const threshold = 0.75;
      debugPrint('Landmark similarity: $similarity, threshold: $threshold');

      if (mounted) {
        setState(() {
          _isVerifying = false;
          _verificationStatus = similarity >= threshold ? 'You are Verified' : 'Verification Denied';
        });
      }

      if (similarity >= threshold && AuthState.userId != null) {
        try {
          final response = await HttpService.post(
            '/user.php?action=set_verification_status',
            body: {
              'user_id': AuthState.userId.toString(),
              'is_verified': true,
            }, 
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['status'] == 'success') {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Verification status saved successfully',
                      style: GoogleFonts.poppins(color: Colors.white),
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Failed to save verification status: ${data['message']}',
                      style: GoogleFonts.poppins(color: Colors.white),
                    ),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
            }
          } else {
            if (mounted) {
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
          }
        } catch (e) {
          debugPrint('Error saving verification status: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Error saving verification status: $e',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
        }
      }

      faceDetector.close();
    } catch (e) {
      debugPrint('Error during verification: $e');
      if (mounted) {
        setState(() {
          _isVerifying = false;
          _verificationStatus = 'Verification Failed: $e';
        });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          'Verification',
          style: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        backgroundColor: Colors.black.withOpacity(0.7),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFFF6200)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
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
                        'Upload Images for Verification',
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
                        onTap: () => _pickImage(isSelfie: true),
                        child: Center(
                          child: Text(
                            'Upload Selfie',
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
                  if (_selfieImage != null) ...[
                    const SizedBox(height: 8),
                    FadeInUp(
                      duration: const Duration(milliseconds: 500),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          _selfieImage!,
                          height: 150,
                          width: 150,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FadeInUp(
                    duration: const Duration(milliseconds: 600),
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
                        onTap: () => _pickImage(isSelfie: false),
                        child: Center(
                          child: Text(
                            'Upload ID Card',
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
                  if (_idCardImage != null) ...[
                    const SizedBox(height: 8),
                    FadeInUp(
                      duration: const Duration(milliseconds: 700),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          _idCardImage!,
                          height: 150,
                          width: 150,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FadeInUp(
                    duration: const Duration(milliseconds: 800),
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
                        onTap: _isVerifying ? null : _verifyImages,
                        child: Center(
                          child: Text(
                            'Verify',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _isVerifying ? Colors.white70 : Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isVerifying)
                    FadeInUp(
                      duration: const Duration(milliseconds: 900),
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
                              'Processing...',
                              style: GoogleFonts.poppins(
                                fontSize: 16,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                      child: Text(
                        _verificationStatus,
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: _verificationStatus.contains('Verified') ? Colors.green : Colors.redAccent,
                        ),
                        textAlign: TextAlign.center,
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