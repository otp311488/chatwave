import 'dart:async';
import 'dart:convert';

import 'package:animate_do/animate_do.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'main.dart';
import 'verification.dart';


class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  Map<String, dynamic> _metrics = {};
  bool _isLoading = false;
  int _screenTimeSeconds = 0;
  Timer? _screenTimeTimer;
  late Box _screenTimeBox;
  String? _profilePhotoUrl;
  bool _isPhotoLoading = false;
  bool _isVerified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initScreenTime();
    _fetchMetrics();
    _fetchProfilePhoto();
  }

  Future<void> _initScreenTime() async {
    if (!Hive.isBoxOpen('screenTime')) {
      _screenTimeBox = await Hive.openBox('screenTime');
    } else {
      _screenTimeBox = Hive.box('screenTime');
    }
    _screenTimeSeconds = _screenTimeBox.get('screenTime', defaultValue: 0) as int;
    if (mounted) {
      setState(() {});
      _startScreenTimer();
    }
  }

  void _startScreenTimer() {
    _screenTimeTimer?.cancel();
    _screenTimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _screenTimeSeconds++;
          _screenTimeBox.put('screenTime', _screenTimeSeconds);
        });
      }
    });
  }

  Future<void> _fetchProfilePhoto() async {
    if (!mounted) return;
    setState(() => _isPhotoLoading = true);
    try {
      final response = await HttpService.get('/user.php', query: {
        'action': 'get_privacy_settings',
        'user_id': AuthState.userId.toString(),
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          setState(() {
            _profilePhotoUrl = data['profile_photo_url']?.toString();
            _isVerified = data['is_verified'] ?? false;
            _isPhotoLoading = false;
          });
          debugPrint('DEBUG: Profile photo URL fetched: $_profilePhotoUrl, Verified: $_isVerified');
        } else {
          throw Exception(data['message'] ?? 'Failed to fetch privacy settings');
        }
      } else {
        throw Exception('HTTP Error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        debugPrint('DEBUG: Error fetching profile photo: $e');
        setState(() => _isPhotoLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to load profile photo',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _screenTimeTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _startScreenTimer();
      _fetchProfilePhoto();
    }
  }

  Future<void> _fetchMetrics() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final response = await HttpService.get('/dashboard.php', query: {'action': 'get_metrics'});
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          if (mounted) {
            setState(() => _metrics = Map<String, dynamic>.from(data['metrics']));
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                data['message'] ?? 'Failed to fetch metrics',
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
              'HTTP Error: ${response.statusCode}',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        debugPrint('Error fetching metrics: $e');
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error fetching metrics: $e',
              style: GoogleFonts.poppins(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatScreenTime(int seconds) {
    final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$secs';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenTimeTimer?.cancel();
    super.dispose();
  }

  Widget _buildVerifiedBadge() {
    return Positioned(
      right: -2,
      bottom: -2,
      child: Container(
        width: 26,
        height: 26,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(
            image: NetworkImage(
              'https://static.vecteezy.com/system/resources/previews/010/926/944/non_2x/3d-verification-badge-icon-element-for-verified-account-white-check-with-blue-badge-illustration-interface-design-vector.jpg',
            ),
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  void _showFullScreenProfilePhoto() {
    if (_profilePhotoUrl == null || _profilePhotoUrl!.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                color: Colors.black87,
                child: Center(
                  child: InteractiveViewer(
                    panEnabled: true,
                    scaleEnabled: true,
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.network(
                      _profilePhotoUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Center(
                        child: Text(
                          'Failed to load image',
                          style: GoogleFonts.poppins(color: Colors.white),
                        ),
                      ),
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(color: Color(0xFFFF6200)),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
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
                    icon: const Icon(Icons.dashboard, color: Colors.grey),
                    onPressed: null,
                    tooltip: 'Dashboard',
                  ),
                  Text(
                    'Dashboard',
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
        backgroundColor: const Color(0xFFFF6200),
        title: Text(
          'Dashboard',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                onTap: _showFullScreenProfilePhoto,
                child: CircleAvatar(
                  radius: 38,
                  backgroundImage: _profilePhotoUrl != null && _profilePhotoUrl!.isNotEmpty
                      ? NetworkImage(_profilePhotoUrl!)
                      : null,
                  backgroundColor: Colors.white,
                  child: _profilePhotoUrl == null || _profilePhotoUrl!.isEmpty
                      ? Text(
                          AuthState.username?.isNotEmpty == true
                              ? AuthState.username![0].toUpperCase()
                              : 'U',
                          style: GoogleFonts.poppins(
                            color: const Color(0xFFFF6200),
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                  onBackgroundImageError: _profilePhotoUrl != null && _profilePhotoUrl!.isNotEmpty
                      ? (error, stackTrace) {
                          debugPrint('DEBUG: Failed to load profile photo from $_profilePhotoUrl');
                        }
                      : null,
                ),
              ),
              if (_isPhotoLoading)
                const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              if (_isVerified) _buildVerifiedBadge(),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _fetchMetrics,
            tooltip: 'Refresh Metrics',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'privacy') {
                if (mounted) {
                  Navigator.pushNamed(context, '/privacy').then((_) {
                    _fetchProfilePhoto();
                  });
                }
              } else if (value == 'verification') {
                if (mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const VerificationScreen()),
                  ).then((_) {
                    _fetchProfilePhoto();
                  });
                }
              } else if (value == 'logout') {
                if (mounted) {
                  await AuthState.logout();
                  Navigator.pushReplacementNamed(context, '/auth');
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'privacy',
                child: Text(
                  'Privacy Settings',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
              ),
              PopupMenuItem(
                value: 'verification',
                child: Text(
                  'Verification',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: Text(
                  'Logout',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
              ),
            ],
            color: Colors.black.withOpacity(0.7),
          ),
        ],
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: SpinKitPulse(color: Color(0xFFFF6200), size: 50))
              : _metrics.isEmpty
                  ? Center(
                      child: FadeInUp(
                        duration: const Duration(milliseconds: 500),
                        child: Text(
                          'No data available',
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _fetchMetrics,
                      color: const Color(0xFFFF6200),
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FadeInUp(
                              duration: const Duration(milliseconds: 600),
                              child: Text(
                                'Your Activity',
                                style: GoogleFonts.poppins(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            FadeInUp(
                              duration: const Duration(milliseconds: 800),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 300,
                                borderRadius: 15,
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
                                    children: [
                                      Text(
                                        'Communication Metrics',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(child: _buildBarChart()),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            FadeInUp(
                              duration: const Duration(milliseconds: 1000),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 200,
                                borderRadius: 15,
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
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Communication Summary',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _buildMetricRow('Messages Sent', _metrics['messages_sent']?.toString() ?? '0'),
                                      _buildMetricRow('Messages Received', _metrics['messages_received']?.toString() ?? '0'),
                                      _buildMetricRow('Calls Sent', _metrics['calls_sent']?.toString() ?? '0'),
                                      _buildMetricRow('Calls Received', _metrics['calls_received']?.toString() ?? '0'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            FadeInUp(
                              duration: const Duration(milliseconds: 1200),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 150,
                                borderRadius: 15,
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
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Connections',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _buildMetricRow('Friends', _metrics['friends']?.toString() ?? '0'),
                                      _buildMetricRow('Groups', _metrics['groups']?.toString() ?? '0'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            FadeInUp(
                              duration: const Duration(milliseconds: 1400),
                              child: GlassmorphicContainer(
                                width: double.infinity,
                                height: 100,
                                borderRadius: 15,
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
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Screen Time',
                                        style: GoogleFonts.poppins(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _buildMetricRow('Total', _formatScreenTime(_screenTimeSeconds)),
                                    ],
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

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 16,
              color: Colors.white70,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarChart() {
    final now = DateTime.now();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;

    List<FlSpot> sentSpots = [];
    List<FlSpot> receivedSpots = [];

    final sentData = _metrics['messages_sent'] is Map ? _metrics['messages_sent'] as Map<String, dynamic> : {};
    final receivedData = _metrics['messages_received'] is Map ? _metrics['messages_received'] as Map<String, dynamic> : {};

    for (int day = 1; day <= daysInMonth; day++) {
      double sentValue = (sentData[day.toString()]?.toDouble() ?? 0.0);
      double receivedValue = (receivedData[day.toString()]?.toDouble() ?? 0.0);
      sentSpots.add(FlSpot(day.toDouble(), sentValue));
      receivedSpots.add(FlSpot(day.toDouble(), receivedValue));
    }

    final allValues = [...sentSpots, ...receivedSpots].map((spot) => spot.y).toList();
    final maxY = allValues.isNotEmpty ? allValues.reduce((a, b) => a > b ? a : b) + 5 : 10.0;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: maxY / 5,
          verticalInterval: 5,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.white.withOpacity(0.2),
            strokeWidth: 1,
          ),
          getDrawingVerticalLine: (value) => FlLine(
            color: Colors.white.withOpacity(0.2),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: maxY / 5,
              getTitlesWidget: (value, meta) => Text(
                value.toInt().toString(),
                style: GoogleFonts.poppins(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
              reservedSize: 40,
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 5,
              getTitlesWidget: (value, meta) {
                if (value.toInt() % 5 == 0 && value.toInt() <= daysInMonth) {
                  return Text(
                    value.toInt().toString(),
                    style: GoogleFonts.poppins(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 30,
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: const Color(0xFFFF6200).withOpacity(0.3)),
        ),
        minX: 1,
        maxX: daysInMonth.toDouble(),
        minY: 0,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: sentSpots,
            isCurved: true,
            color: const Color(0xFFFF6200),
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: const Color(0xFFFF6200).withOpacity(0.2),
            ),
          ),
          LineChartBarData(
            spots: receivedSpots,
            isCurved: true,
            color: Colors.blueAccent,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blueAccent.withOpacity(0.2),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            tooltipBorder: BorderSide(color: Colors.black.withOpacity(0.8), width: 1),
            getTooltipItems: (List<LineBarSpot> touchedSpots) {
              return touchedSpots.map((spot) {
                final day = spot.x.toInt();
                final value = spot.y.toInt();
                final type = spot.barIndex == 0 ? 'Sent' : 'Received';
                return LineTooltipItem(
                  'Day $day: $value $type\n',
                  GoogleFonts.poppins(
                    color: spot.barIndex == 0 ? const Color(0xFFFF6200) : Colors.blueAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                );
              }).toList();
            },
            getTooltipColor: (LineBarSpot spot) => Colors.black.withOpacity(0.8),
          ),
          handleBuiltInTouches: true,
        ),
      ),
    );
  }
}