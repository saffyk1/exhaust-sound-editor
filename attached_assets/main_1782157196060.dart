import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_video/return_code.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait — makes the audio controls feel more intentional
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ExhaustStudioApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────────────────────────────────────
class ExhaustStudioApp extends StatelessWidget {
  const ExhaustStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ExhaustStudio 650',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const HomeScreen(),
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF141414),
      colorScheme: ColorScheme.dark(
        primary: const Color(0xFFFF6B00),    // Burnt-orange — exhaust pipe glow
        secondary: const Color(0xFFFFAA00),   // Amber highlight
        surface: const Color(0xFF1E1E1E),
        onSurface: const Color(0xFFE8E8E8),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0D0D0D),
        foregroundColor: Color(0xFFE8E8E8),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: Color(0xFFFF6B00),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFF6B00),
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(56),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          textStyle: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: const Color(0xFFFF6B00),
        inactiveTrackColor: const Color(0xFF3A3A3A),
        thumbColor: const Color(0xFFFFAA00),
        overlayColor: const Color(0x33FF6B00),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Screen
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  File? _videoFile;
  VideoPlayerController? _videoController;
  bool _isLoading = false;
  String _loadingMessage = 'Mastering Engine Audio...';
  String? _statusMessage;
  bool _statusIsError = false;

  // Slider values (0.0 → 1.0, mapped to DSP parameters)
  double _noiseCleanup = 0.5;   // maps highpass 60–180 Hz, lowpass 4000–9000 Hz
  double _exhaustDepth = 0.5;   // maps 200 Hz EQ gain 0–12 dB

  final ImagePicker _picker = ImagePicker();

  // Pulse animation for the loading state
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── DSP parameter mapping ──────────────────────────────────────────────────

  /// Noise cleanup slider → highpass and lowpass cutoff frequencies
  /// Low cleanup (0.0): highpass=60, lowpass=9000 (very open, keeps more sound)
  /// High cleanup (1.0): highpass=180, lowpass=4000 (aggressive wind/hiss cut)
  int get _highpassHz => (60 + (_noiseCleanup * 120)).round();
  int get _lowpassHz  => (9000 - (_noiseCleanup * 5000)).round();

  /// Exhaust depth slider → 200 Hz EQ gain in dB (0 → 12 dB)
  double get _bassGainDb => _exhaustDepth * 12.0;

  /// Builds the complete FFmpeg -af filter chain with live slider values
  String get _filterChain =>
      'highpass=f=$_highpassHz, '
      'lowpass=f=$_lowpassHz, '
      'equalizer=f=200:width_type=h:width=50:g=${_bassGainDb.toStringAsFixed(1)}, '
      'equalizer=f=2500:width_type=h:width=200:g=3, '
      'acompressor=threshold=-12dB:ratio=4:attack=5:release=50, '
      'volume=volume=2dB, '
      'alimiter=limit=-1dB';

  // ── Permissions ────────────────────────────────────────────────────────────

  Future<bool> _ensurePermissions() async {
    // Android 13+ uses READ_MEDIA_VIDEO instead of READ_EXTERNAL_STORAGE
    PermissionStatus status;
    if (Platform.isAndroid) {
      status = await Permission.videos.request();
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
    } else {
      status = await Permission.photos.request();
    }
    return status.isGranted;
  }

  // ── Video picking ──────────────────────────────────────────────────────────

  Future<void> _pickVideo() async {
    if (_isLoading) return;

    final granted = await _ensurePermissions();
    if (!granted) {
      _showStatus('Storage permission denied. Please allow access in Settings.', isError: true);
      return;
    }

    final XFile? picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;

    final file = File(picked.path);
    await _initVideoController(file);
    setState(() {
      _videoFile = file;
      _statusMessage = null;
    });
  }

  Future<void> _initVideoController(File file) async {
    await _videoController?.dispose();
    final ctrl = VideoPlayerController.file(file);
    await ctrl.initialize();
    ctrl.setLooping(true);
    setState(() => _videoController = ctrl);
  }

  // ── FFmpeg processing ──────────────────────────────────────────────────────

  Future<void> _processVideo() async {
    if (_videoFile == null || _isLoading) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Mastering Engine Audio…';
      _statusMessage = null;
    });

    try {
      // Build a temp output path in app cache
      final cacheDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempOutput = p.join(cacheDir.path, 'exhaust_studio_$timestamp.mp4');

      final inputPath = _videoFile!.path;
      final filter = _filterChain;

      // FFmpeg command:
      //  -c:v copy  → pass video stream untouched (no re-encode = fast)
      //  -af "..."  → full psychoacoustic pipeline on audio track only
      //  -y         → overwrite output without prompting
      final command =
          '-y -i "$inputPath" -c:v copy -af "$filter" "$tempOutput"';

      debugPrint('[ExhaustStudio] Running FFmpeg: $command');

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        debugPrint('[ExhaustStudio] FFmpeg failed:\n$logs');
        throw Exception('FFmpeg processing failed (code: $returnCode)');
      }

      // Move finished file to public gallery via MediaStore
      setState(() => _loadingMessage = 'Saving to Gallery…');
      final savedPath = await _saveToGallery(tempOutput, timestamp);

      // Clean up temp file
      try { File(tempOutput).deleteSync(); } catch (_) {}

      setState(() {
        _isLoading = false;
        _statusMessage = 'Saved → $savedPath';
        _statusIsError = false;
      });

      if (mounted) {
        _showSuccessSheet(savedPath);
      }
    } catch (e) {
      debugPrint('[ExhaustStudio] Error: $e');
      setState(() {
        _isLoading = false;
        _statusMessage = e.toString();
        _statusIsError = true;
      });
      if (mounted) {
        _showStatus('Processing failed. Check logs.', isError: true);
      }
    }
  }

  /// Saves the processed file to the public Android gallery (MediaStore-safe).
  /// On Android 10+ (API 29+) we use MediaStore via a platform channel approach:
  /// write to Movies/ExhaustStudio using the content resolver.
  Future<String> _saveToGallery(String tempPath, int timestamp) async {
    // On Android we ideally use MediaStore. Since ffmpeg_kit already writes
    // the file to a temp path, we use the gallery_saver-style approach:
    // copy into the public Movies directory using platform scoped path.
    final fileName = 'ExhaustStudio_$timestamp.mp4';

    if (Platform.isAndroid) {
      // Android 10+ scoped storage: write to app-specific external Movies dir
      // which is publicly visible without WRITE_EXTERNAL_STORAGE permission.
      final extDir = await _getAndroidPublicMoviesDir();
      final destDir = Directory(p.join(extDir, 'ExhaustStudio'));
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      final destPath = p.join(destDir.path, fileName);
      File(tempPath).copySync(destPath);

      // Trigger media scanner so it shows in Gallery immediately
      await _triggerMediaScan(destPath);
      return destPath;
    } else {
      // iOS: save to app Documents and open share sheet
      final docsDir = await getApplicationDocumentsDirectory();
      final destPath = p.join(docsDir.path, fileName);
      File(tempPath).copySync(destPath);
      return destPath;
    }
  }

  /// Returns the absolute path to the public Movies folder on Android.
  /// Uses a MethodChannel to call Environment.getExternalStoragePublicDirectory.
  Future<String> _getAndroidPublicMoviesDir() async {
    try {
      const channel = MethodChannel('exhaust_studio/media');
      final path = await channel.invokeMethod<String>('getPublicMoviesDir');
      if (path != null && path.isNotEmpty) return path;
    } catch (_) {
      // Fall back if native channel not wired up (e.g. in simulator)
    }
    // Fallback: use getExternalStorageDirectory and go up to emulated/0/Movies
    final dir = await getExternalStorageDirectory();
    // getExternalStorageDirectory returns .../Android/data/... — walk up 4 levels
    final parts = dir!.path.split('/');
    final idx = parts.indexOf('Android');
    if (idx > 0) {
      return '${parts.sublist(0, idx).join('/')}/Movies';
    }
    return dir.path;
  }

  /// Sends an ACTION_MEDIA_SCANNER_SCAN_FILE intent via MethodChannel
  Future<void> _triggerMediaScan(String filePath) async {
    try {
      const channel = MethodChannel('exhaust_studio/media');
      await channel.invokeMethod('scanFile', {'path': filePath});
    } catch (_) {
      // Non-fatal: file exists, gallery will index it on next scan
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  void _showStatus(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: isError ? Colors.red[800] : const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      ),
    );
  }

  void _showSuccessSheet(String path) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.check_circle, color: Color(0xFF00E676), size: 22),
                SizedBox(width: 10),
                Text(
                  'AUDIO MASTERED',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: 2,
                    color: Color(0xFF00E676),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Your video has been saved to the Gallery under "ExhaustStudio".',
              style: TextStyle(color: Color(0xFFB0B0B0), height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              p.basename(path),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFF606060),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('DONE'),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.graphic_eq, color: Color(0xFFFF6B00), size: 20),
            const SizedBox(width: 10),
            const Text('EXHAUST STUDIO'),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFFF6B00), width: 1),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text(
                '650',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: Color(0xFFFF6B00),
                ),
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.speed, color: Color(0xFF444444), size: 20),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Main scrollable content ──────────────────────────────────────
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildVideoSection(),
                const SizedBox(height: 28),
                _buildDividerLabel('TUNING'),
                const SizedBox(height: 16),
                _buildControlPanel(),
                const SizedBox(height: 28),
                _buildDividerLabel('PIPELINE'),
                const SizedBox(height: 12),
                _buildPipelineReadout(),
                const SizedBox(height: 28),
                _buildEnhanceButton(),
              ],
            ),
          ),
          // ── Loading overlay ──────────────────────────────────────────────
          if (_isLoading) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  // ── Video preview section ────────────────────────────────────────────────

  Widget _buildVideoSection() {
    final hasVideo = _videoController != null && _videoController!.value.isInitialized;

    return GestureDetector(
      onTap: hasVideo ? null : _pickVideo,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: hasVideo ? const Color(0xFF333333) : const Color(0xFF2E2E2E),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: hasVideo ? _buildVideoPlayer() : _buildEmptyVideoPlaceholder(),
        ),
      ),
    );
  }

  Widget _buildEmptyVideoPlaceholder() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF333333), width: 1.5),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.add, color: Color(0xFF555555), size: 28),
        ),
        const SizedBox(height: 14),
        const Text(
          'Upload Ride Video',
          style: TextStyle(
            color: Color(0xFF555555),
            fontFamily: 'monospace',
            fontSize: 13,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'tap to select from gallery',
          style: TextStyle(color: Color(0xFF383838), fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildVideoPlayer() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_videoController!),
          // Play/pause tap target
          GestureDetector(
            onTap: () {
              setState(() {
                _videoController!.value.isPlaying
                    ? _videoController!.pause()
                    : _videoController!.play();
              });
            },
            child: AnimatedOpacity(
              opacity: _videoController!.value.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 30),
              ),
            ),
          ),
          // Replace video button (top-right)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: _pickVideo,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                child: const Text(
                  'REPLACE',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Color(0xFFAAAAAA),
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
          // Video progress bar at bottom
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              _videoController!,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: const Color(0xFFFF6B00),
                bufferedColor: Colors.white.withOpacity(0.2),
                backgroundColor: Colors.black.withOpacity(0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Control panel ─────────────────────────────────────────────────────────

  Widget _buildControlPanel() {
    return Column(
      children: [
        _buildSliderRow(
          icon: Icons.filter_alt_outlined,
          label: 'Noise Cleanup',
          subLabel: 'highpass ${_highpassHz}Hz / lowpass ${_lowpassHz}Hz',
          value: _noiseCleanup,
          onChanged: (v) => setState(() => _noiseCleanup = v),
          leftTick: 'OPEN',
          rightTick: 'TIGHT',
        ),
        const SizedBox(height: 24),
        _buildSliderRow(
          icon: Icons.waves,
          label: 'Exhaust Deepness',
          subLabel: '200Hz bass +${_bassGainDb.toStringAsFixed(1)}dB',
          value: _exhaustDepth,
          onChanged: (v) => setState(() => _exhaustDepth = v),
          leftTick: 'FLAT',
          rightTick: '+12dB',
        ),
      ],
    );
  }

  Widget _buildSliderRow({
    required IconData icon,
    required String label,
    required String subLabel,
    required double value,
    required ValueChanged<double> onChanged,
    required String leftTick,
    required String rightTick,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: const Color(0xFFFF6B00), size: 16),
            const SizedBox(width: 8),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 1.4,
                color: Color(0xFFCCCCCC),
              ),
            ),
            const Spacer(),
            Text(
              subLabel,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFFFF6B00),
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        Slider(value: value, onChanged: onChanged),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(leftTick, style: const TextStyle(fontSize: 9, color: Color(0xFF444444), letterSpacing: 1)),
              Text(rightTick, style: const TextStyle(fontSize: 9, color: Color(0xFF444444), letterSpacing: 1)),
            ],
          ),
        ),
      ],
    );
  }

  // ── Pipeline readout ──────────────────────────────────────────────────────

  Widget _buildPipelineReadout() {
    final stages = [
      ('HPF', '${_highpassHz}Hz cut', 'Removes wind buffet & chassis rumble'),
      ('LPF', '${_lowpassHz}Hz cut', 'Strips tyre hiss & valve tick'),
      ('EQ1', '+${_bassGainDb.toStringAsFixed(1)}dB@200Hz', 'Mid-bass harmonic body'),
      ('EQ2', '+3dB@2500Hz', 'Engine bark & firing snap'),
      ('COMP', '-12dB thr / 4:1', 'Broadcast-density compression'),
      ('LIM', '-1dBFS ceiling', 'Hard limiter — zero clip'),
    ];

    return Column(
      children: stages.asMap().entries.map((entry) {
        final i = entry.key;
        final s = entry.value;
        final isLast = i == stages.length - 1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stage column
            SizedBox(
              width: 44,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      border: Border.all(color: const Color(0xFF2E2E2E)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      s.$1,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF6B00),
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!isLast)
                    Container(width: 1, height: 20, color: const Color(0xFF2A2A2A)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.$2,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFFE0E0E0),
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.$3,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF555555),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }).toList(),
    );
  }

  // ── Enhance button ────────────────────────────────────────────────────────

  Widget _buildEnhanceButton() {
    final canProcess = _videoFile != null && !_isLoading;
    return AnimatedOpacity(
      opacity: canProcess ? 1.0 : 0.35,
      duration: const Duration(milliseconds: 200),
      child: ElevatedButton.icon(
        onPressed: canProcess ? _processVideo : null,
        icon: const Icon(Icons.bolt, size: 20),
        label: const Text('ENHANCE & SAVE TO GALLERY'),
      ),
    );
  }

  // ── Loading overlay ───────────────────────────────────────────────────────

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.82),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, __) => Opacity(
                opacity: _pulseAnimation.value,
                child: const Icon(
                  Icons.graphic_eq,
                  color: Color(0xFFFF6B00),
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Color(0xFFFF6B00),
                backgroundColor: Color(0xFF2A2A2A),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _loadingMessage,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Color(0xFFCCCCCC),
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'please wait',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF444444),
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helper: section divider label ─────────────────────────────────────────

  Widget _buildDividerLabel(String label) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.5,
            color: Color(0xFF444444),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: const Color(0xFF222222))),
      ],
    );
  }
}
