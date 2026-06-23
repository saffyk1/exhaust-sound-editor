import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'waveform_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Filter parameter model
// ─────────────────────────────────────────────────────────────────────────────
class FilterParams {
  final int    hpfHz;
  final int    lpfHz;
  final double eq1Gain;
  final double eq2Gain;
  final double compThresh;
  final double compRatio;
  final double volDb;
  final double limDb;

  const FilterParams({
    required this.hpfHz,  required this.lpfHz,
    required this.eq1Gain, required this.eq2Gain,
    required this.compThresh, required this.compRatio,
    required this.volDb, required this.limDb,
  });

  FilterParams copyWith({
    int? hpfHz, int? lpfHz,
    double? eq1Gain, double? eq2Gain,
    double? compThresh, double? compRatio,
    double? volDb, double? limDb,
  }) => FilterParams(
    hpfHz: hpfHz ?? this.hpfHz,
    lpfHz: lpfHz ?? this.lpfHz,
    eq1Gain: eq1Gain ?? this.eq1Gain,
    eq2Gain: eq2Gain ?? this.eq2Gain,
    compThresh: compThresh ?? this.compThresh,
    compRatio: compRatio ?? this.compRatio,
    volDb: volDb ?? this.volDb,
    limDb: limDb ?? this.limDb,
  );

  Map<String, dynamic> toJson() => {
    'hpfHz': hpfHz, 'lpfHz': lpfHz,
    'eq1Gain': eq1Gain, 'eq2Gain': eq2Gain,
    'compThresh': compThresh, 'compRatio': compRatio,
    'volDb': volDb, 'limDb': limDb,
  };

  factory FilterParams.fromJson(Map<String, dynamic> j) => FilterParams(
    hpfHz: (j['hpfHz'] as num).toInt(),
    lpfHz: (j['lpfHz'] as num).toInt(),
    eq1Gain: (j['eq1Gain'] as num).toDouble(),
    eq2Gain: (j['eq2Gain'] as num).toDouble(),
    compThresh: (j['compThresh'] as num).toDouble(),
    compRatio: (j['compRatio'] as num).toDouble(),
    volDb: (j['volDb'] as num).toDouble(),
    limDb: (j['limDb'] as num).toDouble(),
  );

  String get filterChain =>
      'highpass=f=$hpfHz, '
      'lowpass=f=$lpfHz, '
      'equalizer=f=200:width_type=h:width=50:g=${eq1Gain.toStringAsFixed(1)}, '
      'equalizer=f=2500:width_type=h:width=200:g=${eq2Gain.toStringAsFixed(1)}, '
      'acompressor=threshold=${compThresh.toStringAsFixed(0)}dB:ratio=${compRatio.toStringAsFixed(1)}:attack=5:release=50, '
      'volume=volume=${volDb.toStringAsFixed(1)}dB, '
      'alimiter=limit=${limDb.toStringAsFixed(1)}dB';
}

const kDefaultParams = FilterParams(
  hpfHz: 120, lpfHz: 6500,
  eq1Gain: 6.0, eq2Gain: 3.0,
  compThresh: -12, compRatio: 4.0,
  volDb: 2.0, limDb: -1.0,
);

// ─────────────────────────────────────────────────────────────────────────────
// Preset model
// ─────────────────────────────────────────────────────────────────────────────
class ExhaustPreset {
  final String name;
  final String desc;
  final FilterParams params;
  final bool isCustom;

  const ExhaustPreset({ required this.name, required this.desc, required this.params, this.isCustom = false });

  Map<String, dynamic> toJson() => { 'name': name, 'desc': desc, 'params': params.toJson() };
  factory ExhaustPreset.fromJson(Map<String, dynamic> j) => ExhaustPreset(
    name: j['name'] as String,
    desc: j['desc'] as String,
    params: FilterParams.fromJson(j['params'] as Map<String, dynamic>),
    isCustom: true,
  );
}

const kBuiltInPresets = [
  ExhaustPreset(name: 'Default',      desc: 'Balanced for most bikes',          params: kDefaultParams),
  ExhaustPreset(name: 'Track Day',    desc: 'Aggressive bark, tight noise',      params: FilterParams(hpfHz: 180, lpfHz: 5000, eq1Gain: 9.0, eq2Gain: 5.0, compThresh: -10, compRatio: 6.0, volDb: 3.0, limDb: -0.5)),
  ExhaustPreset(name: 'Deep Rumble',  desc: 'Maximum bass, full exhaust tone',   params: FilterParams(hpfHz: 70,  lpfHz: 6000, eq1Gain: 12.0, eq2Gain: 2.0, compThresh: -14, compRatio: 5.0, volDb: 4.0, limDb: -0.5)),
  ExhaustPreset(name: 'Street Cruise',desc: 'Everyday riding, smooth & natural', params: FilterParams(hpfHz: 100, lpfHz: 7500, eq1Gain: 5.0, eq2Gain: 3.0, compThresh: -12, compRatio: 3.5, volDb: 2.0, limDb: -1.5)),
  ExhaustPreset(name: 'Wet Road',     desc: 'Gentle cleanup, natural sound',     params: FilterParams(hpfHz: 80,  lpfHz: 8500, eq1Gain: 3.0, eq2Gain: 1.5, compThresh: -18, compRatio: 2.5, volDb: 1.0, limDb: -2.0)),
  ExhaustPreset(name: 'Race Mode',    desc: 'Maximum presence, competition',     params: FilterParams(hpfHz: 200, lpfHz: 4500, eq1Gain: 10.0, eq2Gain: 6.0, compThresh: -8, compRatio: 8.0, volDb: 4.0, limDb: -0.5)),
];

// ─────────────────────────────────────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ExhaustStudioApp());
}

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

  ThemeData _buildTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF141414),
    colorScheme: ColorScheme.dark(
      primary: const Color(0xFFFF6B00),
      secondary: const Color(0xFFFFAA00),
      surface: const Color(0xFF1E1E1E),
      onSurface: const Color(0xFFE8E8E8),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0D0D0D),
      foregroundColor: Color(0xFFE8E8E8),
      elevation: 0, centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: Color(0xFFFF6B00)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.black,
      minimumSize: const Size.fromHeight(56),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.6),
    )),
    sliderTheme: SliderThemeData(
      activeTrackColor: const Color(0xFFFF6B00), inactiveTrackColor: const Color(0xFF3A3A3A),
      thumbColor: const Color(0xFFFFAA00), overlayColor: const Color(0x33FF6B00),
      trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Screen
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum TuningMode { presets, manual }

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ── Video ──────────────────────────────────────────────────────────────────
  File? _videoFile;
  VideoPlayerController? _videoController;
  bool _isLoading = false;

  // ── Noise cleanup slider (0.0 = open, 1.0 = tight) ────────────────────────
  double _noiseCleanup = 0.5;
  // OPEN (0.0): HPF=60Hz, LPF=9000Hz — keeps more of the sound
  // TIGHT (1.0): HPF=180Hz, LPF=4000Hz — aggressive wind & hiss removal
  int get _noiseHpfHz => (60 + (_noiseCleanup * 120)).round();
  int get _noiseLpfHz => (9000 - (_noiseCleanup * 5000)).round();
  // ON/OFF bypass for noise cancellation
  bool _noiseCancellationEnabled = true;
  // Signal chain position: true = noise cancellation BEFORE tuning, false = AFTER
  bool _noiseBeforePreset = true;

  // ── Enhanced preview state (loaded after processing, before final save) ────
  VideoPlayerController? _enhancedController;
  File? _enhancedFile;
  bool _showingEnhanced = false;
  String? _enhancedTempPath;

  // ── Tuning ─────────────────────────────────────────────────────────────────
  TuningMode _tuningMode  = TuningMode.presets;
  FilterParams _params    = kDefaultParams;
  FilterParams _manualParams = kDefaultParams;
  String _selectedPreset  = 'Default';

  // ── Custom presets ─────────────────────────────────────────────────────────
  List<ExhaustPreset> _customPresets = [];
  static const _prefsKey = 'exhaustStudioPresets';

  // ── Save preset dialog ─────────────────────────────────────────────────────
  bool _showSaveInput = false;
  final _saveNameCtrl = TextEditingController();

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _pulseAnimation  = Tween<double>(begin: 0.7, end: 1.0).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _loadCustomPresets();
    // Request permissions as soon as the first frame renders so the system
    // dialog appears on app open rather than only when the button is tapped.
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestStartupPermissions());
  }

  Future<void> _requestStartupPermissions() async {
    if (!mounted) return;
    if (Platform.isAndroid) {
      // READ_MEDIA_VIDEO exists only on Android 13+ (API 33+).
      // READ_EXTERNAL_STORAGE covers Android 10–12.
      // Requesting both is harmless — the OS ignores whichever doesn't apply.
      await Permission.videos.request();
      await Permission.storage.request();
    } else {
      await Permission.photos.request();
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _enhancedController?.dispose();
    _pulseController.dispose();
    _saveNameCtrl.dispose();
    super.dispose();
  }

  // ── Persist custom presets ─────────────────────────────────────────────────
  Future<void> _loadCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).map((e) => ExhaustPreset.fromJson(e as Map<String, dynamic>)).toList();
      if (mounted) setState(() => _customPresets = list);
    } catch (_) {}
  }

  Future<void> _saveCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_customPresets.map((p) => p.toJson()).toList()));
  }

  // ── Mode switching ─────────────────────────────────────────────────────────
  void _switchToManual() => setState(() {
    _tuningMode   = TuningMode.manual;
    _manualParams = _params;  // carry over the active preset's values
    _selectedPreset = '';
  });

  void _switchToPresets() {
    final all = [...kBuiltInPresets, ..._customPresets];
    final hit = all.firstWhere((p) => p.name == _selectedPreset, orElse: () => kBuiltInPresets[0]);
    setState(() {
      _tuningMode     = TuningMode.presets;
      _selectedPreset = hit.name;
      _params         = hit.params;
    });
  }

  void _applyPreset(ExhaustPreset preset) => setState(() {
    _selectedPreset = preset.name;
    _params         = preset.params;
    _manualParams   = preset.params;
  });

  void _setManualParam(FilterParams p) => setState(() { _manualParams = p; _params = p; });

  // ── Save custom preset ─────────────────────────────────────────────────────
  Future<void> _doSavePreset() async {
    final name = _saveNameCtrl.text.trim();
    if (name.isEmpty) return;
    final allNames = [...kBuiltInPresets, ..._customPresets].map((p) => p.name).toList();
    if (allNames.contains(name)) {
      _showStatus('A preset named "$name" already exists.', isError: true); return;
    }
    final preset = ExhaustPreset(name: name, desc: 'Custom preset', params: _params, isCustom: true);
    setState(() {
      _customPresets.add(preset);
      _selectedPreset  = name;
      _tuningMode      = TuningMode.presets;
      _showSaveInput   = false;
    });
    _saveNameCtrl.clear();
    await _saveCustomPresets();
  }

  Future<void> _deleteCustomPreset(ExhaustPreset preset) async {
    setState(() {
      _customPresets.removeWhere((p) => p.name == preset.name);
      if (_selectedPreset == preset.name) {
        _selectedPreset = 'Default';
        _params = kDefaultParams;
      }
    });
    await _saveCustomPresets();
  }

  // ── Open Settings helper ───────────────────────────────────────────────────
  void _showOpenSettingsDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Permission Required',
            style: TextStyle(color: Color(0xFFE8E8E8), fontFamily: 'monospace', fontSize: 15)),
        content: const Text(
            'Gallery access was denied. Open the app Settings to grant it, then come back.',
            style: TextStyle(color: Color(0xFFB0B0B0), height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: Color(0xFF666666), fontFamily: 'monospace', fontSize: 12)),
          ),
          TextButton(
            onPressed: () { Navigator.pop(context); openAppSettings(); },
            child: const Text('OPEN SETTINGS', style: TextStyle(color: Color(0xFFFF6B00), fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── Video picking ──────────────────────────────────────────────────────────
  // On Android 13+ the OS Photo Picker handles its own access — no permission
  // needed before opening it. On older Android the startup request covers it.
  // We do NOT gate the picker on permission status; we just open it and let
  // the OS decide. If the user has permanently denied access, we direct them
  // to Settings instead.
  Future<void> _pickVideo() async {
    if (_isLoading) return;

    // If already permanently denied, no point trying — send to Settings.
    if (Platform.isAndroid) {
      final videoStatus   = await Permission.videos.status;
      final storageStatus = await Permission.storage.status;
      if (videoStatus.isPermanentlyDenied && storageStatus.isPermanentlyDenied) {
        _showOpenSettingsDialog(); return;
      }
    }

    try {
      final XFile? picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      final file = File(picked.path);
      _discardEnhanced(); // clear any pending comparison before new video
      await _initVideoController(file);
      setState(() => _videoFile = file);
    } catch (e) {
      _showStatus('Could not open video picker: $e', isError: true);
    }
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
    final cacheDir   = await getTemporaryDirectory();
    final timestamp  = DateTime.now().millisecondsSinceEpoch;
    final tempOutput = p.join(cacheDir.path, 'exhaust_studio_$timestamp.mp4');
    final inputPath  = _videoFile!.path;

    final noiseFilter = 'highpass=f=$_noiseHpfHz, lowpass=f=$_noiseLpfHz';
    final String chainStr;
    if (_noiseCancellationEnabled) {
      chainStr = _noiseBeforePreset
          ? '$noiseFilter, ${_params.filterChain}'
          : '${_params.filterChain}, $noiseFilter';
    } else {
      chainStr = _params.filterChain;
    }
    final command = '-y -i "$inputPath" -c:v copy -af "$chainStr" "$tempOutput"';

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => WaveformScreen(
      inputPath: inputPath, outputPath: tempOutput, ffmpegCommand: command,
      onComplete: () async {
        // Load enhanced into main screen for comparison — DON'T save yet
        await _loadEnhanced(tempOutput, timestamp);
        if (mounted) Navigator.pop(context);
      },
      onError: (err) {
        if (mounted) { Navigator.pop(context); _showStatus('Processing failed.', isError: true); }
      },
    )));
  }

  // ── Enhanced video helpers ─────────────────────────────────────────────────

  Future<void> _loadEnhanced(String tempPath, int timestamp) async {
    await _enhancedController?.dispose();
    final ctrl = VideoPlayerController.file(File(tempPath));
    await ctrl.initialize();
    ctrl.setLooping(true);
    // Start muted — _switchToView will unmute when user selects ENHANCED
    ctrl.setVolume(0);
    if (mounted) {
      setState(() {
        _enhancedController = ctrl;
        _enhancedFile       = File(tempPath);
        _enhancedTempPath   = tempPath;
        _showingEnhanced    = false; // start on ORIGINAL so user hears the difference
      });
    }
  }

  Future<void> _switchToView(bool showEnhanced) async {
    final from = showEnhanced ? _videoController    : _enhancedController;
    final to   = showEnhanced ? _enhancedController : _videoController;
    if (to == null) return;
    final pos = from?.value.position ?? Duration.zero;
    final wasPlaying = from?.value.isPlaying ?? false;
    from?.pause();
    from?.setVolume(0);
    to.setVolume(1);
    await to.seekTo(pos);
    if (wasPlaying) to.play();
    setState(() => _showingEnhanced = showEnhanced);
  }

  Future<void> _saveEnhanced() async {
    final path = _enhancedTempPath;
    if (path == null) return;
    setState(() => _isLoading = true);
    try {
      // Ensure original video is playing (not enhanced) so its controller is paused
      _enhancedController?.pause();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final saved = await _saveToGallery(path, timestamp);
      try { File(path).deleteSync(); } catch (_) {}
      _discardEnhanced();
      setState(() => _isLoading = false);
      _showSuccessSheet(saved);
    } catch (e) {
      setState(() => _isLoading = false);
      _showStatus('Gallery save failed: $e', isError: true);
    }
  }

  void _discardEnhanced() {
    final path = _enhancedTempPath;
    if (path != null) { try { File(path).deleteSync(); } catch (_) {} }
    _enhancedController?.dispose();
    setState(() {
      _enhancedController = null;
      _enhancedFile       = null;
      _enhancedTempPath   = null;
      _showingEnhanced    = false;
    });
    // Restore original volume
    _videoController?.setVolume(1);
  }

  Future<String> _saveToGallery(String tempPath, int timestamp) async {
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) throw Exception('Gallery access denied.');
    }
    await Gal.putVideo(tempPath, album: 'ExhaustStudio');
    return 'Gallery › ExhaustStudio › ExhaustStudio_$timestamp.mp4';
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────
  void _showStatus(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
      backgroundColor: isError ? Colors.red[800] : const Color(0xFF2A2A2A),
      behavior: SnackBarBehavior.floating, margin: const EdgeInsets.all(16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ));
  }

  void _showSuccessSheet(String path) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Icons.check_circle, color: Color(0xFF00E676), size: 22),
            SizedBox(width: 10),
            Text('AUDIO MASTERED', style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 2, color: Color(0xFF00E676))),
          ]),
          const SizedBox(height: 14),
          const Text('Saved to Gallery under "ExhaustStudio".', style: TextStyle(color: Color(0xFFB0B0B0), height: 1.5)),
          const SizedBox(height: 8),
          Text(p.basename(path), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF606060))),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('DONE')),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.graphic_eq, color: Color(0xFFFF6B00), size: 20),
          const SizedBox(width: 10),
          const Text('EXHAUST STUDIO'),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFFFF6B00)), borderRadius: BorderRadius.circular(2)),
            child: const Text('650', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1, color: Color(0xFFFF6B00))),
          ),
        ]),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildVideoSection(),
          const SizedBox(height: 28),
          _buildDividerLabel('NOISE CANCELLATION'),
          const SizedBox(height: 14),
          _buildNoiseCleanupSection(),
          const SizedBox(height: 28),
          _buildDividerLabel('TUNING PROFILE'),
          const SizedBox(height: 14),
          _buildModeSwitcher(),
          const SizedBox(height: 16),
          if (_tuningMode == TuningMode.presets) _buildPresetsPanel(),
          if (_tuningMode == TuningMode.manual)  _buildManualPanel(),
          const SizedBox(height: 28),
          _buildDividerLabel('PIPELINE'),
          const SizedBox(height: 12),
          _buildPipelineReadout(),
          const SizedBox(height: 28),
          _buildEnhanceButton(),
        ]),
      ),
    );
  }

  // ── Noise cancellation section ────────────────────────────────────────────
  Widget _buildNoiseCleanupSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        border: Border.all(color: const Color(0xFF1E1E1E)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── OFF toggle + slider ─────────────────────────────────────────────
        Row(children: [
          // OFF button
          GestureDetector(
            onTap: () => setState(() => _noiseCancellationEnabled = !_noiseCancellationEnabled),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: _noiseCancellationEnabled ? const Color(0xFF1A1A1A) : const Color(0xFF333333),
                border: Border.all(color: _noiseCancellationEnabled ? const Color(0xFF2A2A2A) : const Color(0xFF888888)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('OFF', style: TextStyle(
                fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: _noiseCancellationEnabled ? const Color(0xFF444444) : const Color(0xFFCCCCCC),
              )),
            ),
          ),
          const SizedBox(width: 10),
          // Slider
          Expanded(
            child: Opacity(
              opacity: _noiseCancellationEnabled ? 1.0 : 0.3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                ),
                child: Slider(
                  value: _noiseCleanup,
                  onChanged: _noiseCancellationEnabled
                      ? (v) => setState(() => _noiseCleanup = v)
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text('${(_noiseCleanup * 10).round() * 10}%',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF555555))),
        ]),

        const SizedBox(height: 12),

        // ── BEFORE TUNING / AFTER TUNING ────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A),
            border: Border.all(color: const Color(0xFF2A2A2A)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            _chainOrderTab('BEFORE TUNING', isActive: _noiseBeforePreset,  onTap: () => setState(() => _noiseBeforePreset = true)),
            _chainOrderTab('AFTER TUNING',  isActive: !_noiseBeforePreset, onTap: () => setState(() => _noiseBeforePreset = false)),
          ]),
        ),

        const SizedBox(height: 10),

        // ── Description ─────────────────────────────────────────────────────
        Text(
          _noiseCancellationEnabled
              ? 'Targets sub-bass road rumble (<${_noiseHpfHz}Hz) and wind/hiss above exhaust range (>${_noiseLpfHz ~/ 1000}.${(_noiseLpfHz % 1000) ~/ 100}kHz) — independent of HPF/LPF/EQ settings'
              : 'Noise cancellation bypassed — raw audio passes through unchanged',
          style: const TextStyle(fontSize: 10, color: Color(0xFF555555), height: 1.5, letterSpacing: 0.2),
        ),
      ]),
    );
  }

  Widget _chainOrderTab(String label, {required bool isActive, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF2A2A2A) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 10, letterSpacing: 1,
            color: isActive ? const Color(0xFFE0E0E0) : const Color(0xFF555555),
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
          )),
        ),
      ),
    );
  }

  // ── Preview command getter ─────────────────────────────────────────────────
  String get _previewCommand {
    final noiseFilter = 'highpass=f=$_noiseHpfHz, lowpass=f=$_noiseLpfHz';
    final String chain;
    if (_noiseCancellationEnabled) {
      chain = _noiseBeforePreset
          ? '$noiseFilter, ${_params.filterChain}'
          : '${_params.filterChain}, $noiseFilter';
    } else {
      chain = _params.filterChain;
    }
    return '-y -i input.mp4 -c:v copy -af "$chain" output.mp4';
  }

  // ── Mode switcher ─────────────────────────────────────────────────────────
  Widget _buildModeSwitcher() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        _modeTab('PRESETS',       TuningMode.presets, _switchToPresets),
        _modeTab('MANUAL TUNING', TuningMode.manual,  _switchToManual),
      ]),
    );
  }

  Widget _modeTab(String label, TuningMode mode, VoidCallback onTap) {
    final active = _tuningMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFFF6B00) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.4, color: active ? Colors.black : const Color(0xFF888888),
          )),
        ),
      ),
    );
  }

  // ── Presets panel ─────────────────────────────────────────────────────────
  Widget _buildPresetsPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Built-in presets grid
      _buildGroupLabel('BUILT-IN'),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.6,
        children: kBuiltInPresets.map((preset) => _buildPresetCard(preset)).toList(),
      ),

      // Custom presets
      if (_customPresets.isNotEmpty) ...[
        const SizedBox(height: 20),
        _buildGroupLabel('MY PRESETS'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.6,
          children: _customPresets.map((preset) => _buildPresetCard(preset, canDelete: true)).toList(),
        ),
      ],

      const SizedBox(height: 16),

      // Save current as preset
      if (!_showSaveInput)
        GestureDetector(
          onTap: () => setState(() => _showSaveInput = true),
          child: Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF2A2A2A), style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Text('+ SAVE CURRENT SETTINGS AS PRESET', style: TextStyle(
              fontFamily: 'monospace', fontSize: 10, letterSpacing: 1.4, color: Color(0xFF555555),
            )),
          ),
        )
      else
        Row(children: [
          Expanded(
            child: TextField(
              controller: _saveNameCtrl, autofocus: true,
              onSubmitted: (_) => _doSavePreset(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFE8E8E8)),
              decoration: InputDecoration(
                hintText: 'Preset name…',
                hintStyle: const TextStyle(color: Color(0xFF555555)),
                filled: true, fillColor: const Color(0xFF1A1A1A),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFFF6B00))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFFF6B00))),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _doSavePreset,
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 16)),
            child: const Text('SAVE'),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFF555555)),
            onPressed: () => setState(() { _showSaveInput = false; _saveNameCtrl.clear(); }),
          ),
        ]),
    ]);
  }

  Widget _buildPresetCard(ExhaustPreset preset, { bool canDelete = false }) {
    final isSelected = _selectedPreset == preset.name;
    return GestureDetector(
      onTap: () => _applyPreset(preset),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1A1A1A) : const Color(0xFF1A1A1A),
          border: Border.all(color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFF2A2A2A), width: isSelected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(preset.name, style: TextStyle(
              fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
              letterSpacing: 1.0, color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFFCCCCCC),
            )),
            const SizedBox(height: 4),
            Expanded(
              child: Text(preset.desc, style: const TextStyle(fontSize: 10, color: Color(0xFF555555), height: 1.3),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            Text(
              '${preset.params.hpfHz}Hz · ${preset.params.eq1Gain >= 0 ? '+' : ''}${preset.params.eq1Gain.toStringAsFixed(1)}dB · ${preset.params.compRatio.toStringAsFixed(1)}:1',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF444444)),
            ),
          ]),
          if (canDelete)
            Positioned(
              top: -4, right: -4,
              child: GestureDetector(
                onTap: () => _deleteCustomPreset(preset),
                child: Container(
                  width: 22, height: 22,
                  decoration: const BoxDecoration(color: Color(0xFF2A2A2A), shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Text('×', style: TextStyle(color: Color(0xFF888888), fontSize: 14, height: 1)),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ── Manual panel ──────────────────────────────────────────────────────────
  Widget _buildManualPanel() {
    return Column(children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Row(children: [
          Icon(Icons.info_outline, color: Color(0xFF555555), size: 14),
          SizedBox(width: 6),
          Text('Starts from defaults — edit freely', style: TextStyle(fontSize: 10, color: Color(0xFF555555), letterSpacing: 0.5)),
        ]),
      ),
      _buildParamSlider('HPF FREQUENCY',  '${_manualParams.hpfHz} Hz',   _manualParams.hpfHz.toDouble(), 60, 300, 1, (v) => _setManualParam(_manualParams.copyWith(hpfHz: v.round()))),
      _buildParamSlider('LPF FREQUENCY',  '${_manualParams.lpfHz} Hz',   _manualParams.lpfHz.toDouble(), 1000, 20000, 100, (v) => _setManualParam(_manualParams.copyWith(lpfHz: v.round()))),
      _buildParamSlider('EQ 200Hz GAIN',  '${_manualParams.eq1Gain >= 0 ? "+" : ""}${_manualParams.eq1Gain.toStringAsFixed(1)} dB', _manualParams.eq1Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq1Gain: (v * 2).round() / 2))),
      _buildParamSlider('EQ 2500Hz GAIN', '${_manualParams.eq2Gain >= 0 ? "+" : ""}${_manualParams.eq2Gain.toStringAsFixed(1)} dB', _manualParams.eq2Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq2Gain: (v * 2).round() / 2))),
      _buildParamSlider('COMP THRESHOLD', '${_manualParams.compThresh.toStringAsFixed(0)} dB', _manualParams.compThresh, -40, 0, null, (v) => _setManualParam(_manualParams.copyWith(compThresh: v.roundToDouble()))),
      _buildParamSlider('COMP RATIO',     '${_manualParams.compRatio.toStringAsFixed(1)} : 1', _manualParams.compRatio, 1, 20, null, (v) => _setManualParam(_manualParams.copyWith(compRatio: (v * 2).round() / 2))),
      _buildParamSlider('VOLUME BOOST',   '${_manualParams.volDb >= 0 ? "+" : ""}${_manualParams.volDb.toStringAsFixed(1)} dB', _manualParams.volDb, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(volDb: (v * 2).round() / 2))),
      _buildParamSlider('LIMITER CEILING','${_manualParams.limDb.toStringAsFixed(1)} dBFS', _manualParams.limDb, -12, 0, null, (v) => _setManualParam(_manualParams.copyWith(limDb: (v * 10).round() / 10))),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() { _manualParams = kDefaultParams; _params = kDefaultParams; }),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF2A2A2A)), foregroundColor: const Color(0xFF555555), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
            child: const Text('RESET', style: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.5)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() { _tuningMode = TuningMode.presets; _showSaveInput = true; }),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF2A2A2A), style: BorderStyle.solid), foregroundColor: const Color(0xFF555555), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
            child: const Text('+ SAVE AS PRESET', style: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.2)),
          ),
        ),
      ]),
    ]);
  }

  Widget _buildParamSlider(String label, String valueStr, double value, double min, double max, double? step, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, letterSpacing: 1.2, color: Color(0xFF888888))),
          Text(valueStr, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFF6B00), fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(min % 1 == 0 ? min.toInt().toString() : min.toStringAsFixed(1), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
            Text(max % 1 == 0 ? max.toInt().toString() : max.toStringAsFixed(1), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
          ]),
        ),
      ]),
    );
  }

  // ── Video section ─────────────────────────────────────────────────────────
  Widget _buildVideoSection() {
    final hasVideo    = _videoController?.value.isInitialized ?? false;
    final hasEnhanced = _enhancedController?.value.isInitialized ?? false;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

      // ── ORIGINAL / ENHANCED toggle (visible only after processing) ────────
      if (hasEnhanced) ...[
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F0F),
            border: Border.all(color: const Color(0xFF2A2A2A)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(children: [
            _viewTab('◀  ORIGINAL', isActive: !_showingEnhanced, onTap: () => _switchToView(false)),
            _viewTab('ENHANCED  ▶', isActive: _showingEnhanced,  onTap: () => _switchToView(true)),
          ]),
        ),
        const SizedBox(height: 8),
      ],

      // ── Video frame ───────────────────────────────────────────────────────
      AspectRatio(
        aspectRatio: 16 / 9,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: hasVideo ? const Color(0xFF333333) : const Color(0xFF2E2E2E), width: 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: hasVideo ? _buildVideoPlayer() : _buildEmptyPlaceholder(),
        ),
      ),

      // ── Audio hint (visible when enhanced is loaded) ─────────────────────
      if (hasEnhanced) ...[
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F0F),
            border: Border.all(color: const Color(0xFF1E1E1E)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            const Icon(Icons.volume_up_rounded, size: 13, color: Color(0xFF666666)),
            const SizedBox(width: 8),
            Expanded(child: RichText(text: TextSpan(
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF666666), letterSpacing: 0.3),
              children: _showingEnhanced
                  ? [
                      const TextSpan(text: 'Enhanced audio. Tap '),
                      const TextSpan(text: '◀ ORIGINAL', style: TextStyle(color: Color(0xFFAAAAAA), fontWeight: FontWeight.w700)),
                      const TextSpan(text: ' to compare.'),
                    ]
                  : [
                      const TextSpan(text: 'Original audio. Tap '),
                      const TextSpan(text: 'ENHANCED ▶', style: TextStyle(color: Color(0xFFFF6B00), fontWeight: FontWeight.w700)),
                      const TextSpan(text: ' to compare.'),
                    ],
            ))),
          ]),
        ),
      ],

      if (!hasVideo) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _pickVideo,
          icon: const Icon(Icons.video_library_outlined, size: 18),
          label: const Text('SELECT VIDEO FROM GALLERY',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, letterSpacing: 1.4)),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF6B00),
            side: const BorderSide(color: Color(0xFFFF6B00)),
            minimumSize: const Size.fromHeight(48),
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
          ),
        ),
      ],

      // ── Save / Discard bar (visible only after processing) ────────────────
      if (hasEnhanced) ...[
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _discardEnhanced,
            icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFF666666)),
            label: const Text('DISCARD', style: TextStyle(color: Color(0xFF666666))),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF2A2A2A)),
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _saveEnhanced,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('SAVE TO GALLERY'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B00),
                foregroundColor: Colors.black,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
                textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Adjust settings and re-process anytime before saving',
            style: TextStyle(fontSize: 9, color: Color(0xFF3A3A3A), letterSpacing: 0.3)),
      ],
    ]);
  }

  Widget _viewTab(String label, {required bool isActive, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF2A2A2A) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: isActive ? const Color(0xFFE0E0E0) : const Color(0xFF555555),
          )),
        ),
      ),
    );
  }

  Widget _buildEmptyPlaceholder() => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Container(width: 60, height: 60,
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF333333), width: 1.5), shape: BoxShape.circle),
      child: const Icon(Icons.video_library_outlined, color: Color(0xFF555555), size: 28)),
    const SizedBox(height: 14),
    const Text('No Video Selected', style: TextStyle(color: Color(0xFF555555), fontFamily: 'monospace', fontSize: 13, letterSpacing: 1.2)),
    const SizedBox(height: 6),
    const Text('use the button below', style: TextStyle(color: Color(0xFF383838), fontSize: 11)),
  ]);

  Widget _buildVideoPlayer() {
    final ctrl = (_showingEnhanced && _enhancedController != null)
        ? _enhancedController!
        : _videoController!;
    final isPlaying = ctrl.value.isPlaying;
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Stack(alignment: Alignment.center, children: [
        VideoPlayer(ctrl),
        GestureDetector(
          onTap: () => setState(() { isPlaying ? ctrl.pause() : ctrl.play(); }),
          child: AnimatedOpacity(opacity: isPlaying ? 0.0 : 1.0, duration: const Duration(milliseconds: 200),
            child: Container(width: 52, height: 52, decoration: BoxDecoration(color: Colors.black.withOpacity(0.65), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 30))),
        ),
        Positioned(top: 8, right: 8,
          child: GestureDetector(onTap: _pickVideo,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(3), border: Border.all(color: const Color(0xFF333333))),
              child: const Text('REPLACE', style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFFAAAAAA), letterSpacing: 1))))),
        // Mode badge when comparing
        if (_enhancedController != null)
          Positioned(top: 8, left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75), borderRadius: BorderRadius.circular(3),
                border: Border.all(color: _showingEnhanced ? const Color(0xFFFF6B00) : const Color(0xFF444444)),
              ),
              child: Text(_showingEnhanced ? 'ENHANCED' : 'ORIGINAL', style: TextStyle(
                fontFamily: 'monospace', fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w700,
                color: _showingEnhanced ? const Color(0xFFFF6B00) : const Color(0xFF888888),
              )),
            )),
        Positioned(left: 0, right: 0, bottom: 0,
          child: VideoProgressIndicator(ctrl, allowScrubbing: true,
            colors: VideoProgressColors(playedColor: const Color(0xFFFF6B00), bufferedColor: Colors.white.withOpacity(0.2), backgroundColor: Colors.black.withOpacity(0.4)))),
      ]),
    );
  }

  // ── Pipeline readout ──────────────────────────────────────────────────────
  Widget _buildPipelineReadout() {
    final stages = [
      ('HPF',  '${_params.hpfHz}Hz cut',          'Removes wind buffet & chassis rumble'),
      ('LPF',  '${_params.lpfHz}Hz cut',          'Strips tyre hiss & valve tick'),
      ('EQ1',  '${_params.eq1Gain >= 0 ? '+' : ''}${_params.eq1Gain.toStringAsFixed(1)}dB@200Hz', 'Mid-bass harmonic body'),
      ('EQ2',  '${_params.eq2Gain >= 0 ? '+' : ''}${_params.eq2Gain.toStringAsFixed(1)}dB@2500Hz', 'Engine bark & firing snap'),
      ('COMP', '${_params.compThresh.toStringAsFixed(0)}dB / ${_params.compRatio.toStringAsFixed(1)}:1', 'Broadcast-density compression'),
      ('VOL',  '${_params.volDb >= 0 ? '+' : ''}${_params.volDb.toStringAsFixed(1)}dB', 'Output level trim'),
      ('LIM',  '${_params.limDb.toStringAsFixed(1)}dBFS ceiling', 'Hard limiter — zero clip'),
    ];
    final stageWidgets = stages.asMap().entries.map<Widget>((entry) {
      final i = entry.key; final s = entry.value;
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 44, child: Column(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border.all(color: const Color(0xFF2E2E2E)), borderRadius: BorderRadius.circular(2)),
            child: Text(s.$1, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFFF6B00), letterSpacing: 0.5), textAlign: TextAlign.center)),
          if (i < stages.length - 1) Container(width: 1, height: 20, color: const Color(0xFF2A2A2A)),
        ])),
        const SizedBox(width: 12),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 2, bottom: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.$2, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFE0E0E0), letterSpacing: 0.3)),
          const SizedBox(height: 2),
          Text(s.$3, style: const TextStyle(fontSize: 11, color: Color(0xFF555555), height: 1.3)),
        ]))),
      ]);
    }).toList();

    return Column(children: [
      ...stageWidgets,
      // ── FFmpeg command preview ───────────────────────────────────────────
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF080808),
          border: Border.all(color: const Color(0xFF1E1E1E)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _previewCommand,
          style: const TextStyle(
            fontFamily: 'monospace', fontSize: 9,
            color: Color(0xFF555555), letterSpacing: 0.4, height: 1.5,
          ),
        ),
      ),
    ]);
  }

  // ── Enhance button ────────────────────────────────────────────────────────
  Widget _buildEnhanceButton() {
    final canProcess = _videoFile != null && !_isLoading;
    return AnimatedOpacity(
      opacity: canProcess ? 1.0 : 0.35, duration: const Duration(milliseconds: 200),
      child: ElevatedButton.icon(
        onPressed: canProcess ? _processVideo : null,
        icon: const Icon(Icons.bolt, size: 20),
        label: const Text('ENHANCE & PREVIEW'),
      ),
    );
  }

  // ── Divider label ─────────────────────────────────────────────────────────
  Widget _buildDividerLabel(String label) => Row(children: [
    Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 2.5, color: Color(0xFF444444))),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: const Color(0xFF222222))),
  ]);

  Widget _buildGroupLabel(String label) => Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, letterSpacing: 1.8, color: Color(0xFF555555)));
}
