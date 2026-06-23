import 'dart:convert';
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
  }

  @override
  void dispose() {
    _videoController?.dispose();
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
    _manualParams = kDefaultParams;
    _params       = kDefaultParams;
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

  // ── Permissions ────────────────────────────────────────────────────────────
  Future<bool> _ensurePermissions() async {
    PermissionStatus status;
    if (Platform.isAndroid) {
      status = await Permission.videos.request();
      if (!status.isGranted) status = await Permission.storage.request();
    } else {
      status = await Permission.photos.request();
    }
    return status.isGranted;
  }

  // ── Video picking ──────────────────────────────────────────────────────────
  Future<void> _pickVideo() async {
    if (_isLoading) return;
    final granted = await _ensurePermissions();
    if (!granted) { _showStatus('Storage permission denied.', isError: true); return; }
    final XFile? picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    await _initVideoController(file);
    setState(() => _videoFile = file);
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
    final cacheDir  = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempOutput = p.join(cacheDir.path, 'exhaust_studio_$timestamp.mp4');
    final inputPath  = _videoFile!.path;
    final command    = '-y -i "$inputPath" -c:v copy -af "${_params.filterChain}" "$tempOutput"';

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => WaveformScreen(
      inputPath: inputPath, outputPath: tempOutput, ffmpegCommand: command,
      onComplete: () async {
        try {
          final saved = await _saveToGallery(tempOutput, timestamp);
          try { File(tempOutput).deleteSync(); } catch (_) {}
          if (mounted) { Navigator.pop(context); _showSuccessSheet(saved); }
        } catch (e) {
          if (mounted) { Navigator.pop(context); _showStatus('Gallery save failed: $e', isError: true); }
        }
      },
      onError: (err) {
        if (mounted) { Navigator.pop(context); _showStatus('Processing failed.', isError: true); }
      },
    )));
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
    final hasVideo = _videoController?.value.isInitialized ?? false;
    return GestureDetector(
      onTap: hasVideo ? null : _pickVideo,
      child: AspectRatio(
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
    );
  }

  Widget _buildEmptyPlaceholder() => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Container(width: 60, height: 60,
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF333333), width: 1.5), shape: BoxShape.circle),
      child: const Icon(Icons.add, color: Color(0xFF555555), size: 28)),
    const SizedBox(height: 14),
    const Text('Upload Ride Video', style: TextStyle(color: Color(0xFF555555), fontFamily: 'monospace', fontSize: 13, letterSpacing: 1.2)),
    const SizedBox(height: 6),
    const Text('tap to select from gallery', style: TextStyle(color: Color(0xFF383838), fontSize: 11)),
  ]);

  Widget _buildVideoPlayer() => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: Stack(alignment: Alignment.center, children: [
      VideoPlayer(_videoController!),
      GestureDetector(
        onTap: () => setState(() { _videoController!.value.isPlaying ? _videoController!.pause() : _videoController!.play(); }),
        child: AnimatedOpacity(opacity: _videoController!.value.isPlaying ? 0.0 : 1.0, duration: const Duration(milliseconds: 200),
          child: Container(width: 52, height: 52, decoration: BoxDecoration(color: Colors.black.withOpacity(0.65), shape: BoxShape.circle),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 30))),
      ),
      Positioned(top: 8, right: 8,
        child: GestureDetector(onTap: _pickVideo,
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(3), border: Border.all(color: const Color(0xFF333333))),
            child: const Text('REPLACE', style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFFAAAAAA), letterSpacing: 1))))),
      Positioned(left: 0, right: 0, bottom: 0,
        child: VideoProgressIndicator(_videoController!, allowScrubbing: true,
          colors: VideoProgressColors(playedColor: const Color(0xFFFF6B00), bufferedColor: Colors.white.withOpacity(0.2), backgroundColor: Colors.black.withOpacity(0.4)))),
    ]),
  );

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
    return Column(children: stages.asMap().entries.map((entry) {
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
    }).toList());
  }

  // ── Enhance button ────────────────────────────────────────────────────────
  Widget _buildEnhanceButton() {
    final canProcess = _videoFile != null && !_isLoading;
    return AnimatedOpacity(
      opacity: canProcess ? 1.0 : 0.35, duration: const Duration(milliseconds: 200),
      child: ElevatedButton.icon(
        onPressed: canProcess ? _processVideo : null,
        icon: const Icon(Icons.bolt, size: 20),
        label: const Text('ENHANCE & SAVE TO GALLERY'),
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
