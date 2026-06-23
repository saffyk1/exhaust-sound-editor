import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA
// ─────────────────────────────────────────────────────────────────────────────

enum _Phase { processing, done }

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class WaveformScreen extends StatefulWidget {
  final String inputPath;
  final String outputPath;
  final String ffmpegCommand;
  final Future<void> Function() onComplete;
  final void Function(String) onError;

  const WaveformScreen({
    super.key,
    required this.inputPath,
    required this.outputPath,
    required this.ffmpegCommand,
    required this.onComplete,
    required this.onError,
  });

  @override
  State<WaveformScreen> createState() => _WaveformScreenState();
}

// ─────────────────────────────────────────────────────────────────────────────
// STATE
// ─────────────────────────────────────────────────────────────────────────────

class _WaveformScreenState extends State<WaveformScreen>
    with SingleTickerProviderStateMixin {

  _Phase _phase = _Phase.processing;
  double _progress = 0.0;
  String _logLine = 'Initialising session…';
  double _idlePhase = 0.0;

  late AnimationController _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..addListener(_onTick)
      ..repeat();
    _startSession();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ── Idle waveform animation ───────────────────────────────────────────────

  void _onTick() {
    if (_phase == _Phase.processing && mounted) {
      setState(() => _idlePhase += 0.016);
    }
  }

  // ── Session ───────────────────────────────────────────────────────────────

  Future<void> _startSession() async {
    setState(() { _progress = 0.05; _logLine = 'Loading input…'; });
    await Future.delayed(const Duration(milliseconds: 400));

    setState(() { _progress = 0.12; _logLine = 'Building filter graph…'; });
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() { _progress = 0.18; _logLine = 'Starting FFmpeg session…'; });

    await _runFfmpeg(
      widget.ffmpegCommand,
      onLog: (log) => _onLog(log),
    );
  }

  void _onLog(String log) {
    if (!mounted) return;
    final lower = log.toLowerCase();

    // Parse time= progress
    final timeMatch = RegExp(r'time=(\d+):(\d+):([\d.]+)').firstMatch(log);
    if (timeMatch != null) {
      final h = int.parse(timeMatch.group(1)!);
      final m = int.parse(timeMatch.group(2)!);
      final s = double.parse(timeMatch.group(3)!);
      final secs = h * 3600 + m * 60 + s;
      setState(() {
        _progress = (0.2 + (secs / 300).clamp(0.0, 0.78));
        _logLine = 'Processing ${timeMatch.group(0)}';
      });
      return;
    }

    if (lower.contains('highpass') || lower.contains('lowpass') || lower.contains('equalizer')) {
      setState(() { _progress = 0.30; _logLine = 'Applying noise filter…'; });
    } else if (lower.contains('compand') || lower.contains('acompressor')) {
      setState(() { _progress = 0.50; _logLine = 'Compressing dynamics…'; });
    } else if (lower.contains('volume') || lower.contains('alimiter')) {
      setState(() { _progress = 0.72; _logLine = 'Mastering output level…'; });
    } else if (lower.contains('muxer') || lower.contains('output') || lower.contains('mp4')) {
      setState(() { _progress = 0.88; _logLine = 'Muxing audio to video…'; });
    }
  }

  Future<void> _runFfmpeg(String command, {required void Function(String) onLog}) async {
    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          await _onProcessingComplete();
        } else {
          final logs = await session.getLogs();
          final errMsg = logs.isNotEmpty ? logs.last.getMessage() : 'Unknown error';
          widget.onError(errMsg ?? 'FFmpeg error');
        }
      },
      (log) => onLog(log.getMessage() ?? ''),
    );
  }

  Future<void> _onProcessingComplete() async {
    if (!mounted) return;
    _ticker.stop();
    setState(() {
      _progress = 1.0;
      _logLine  = 'Audio enhanced — returning to main screen…';
      _phase    = _Phase.done;
    });
    // Brief pause so user sees "done" state, then hand control back
    await Future.delayed(const Duration(milliseconds: 900));
    await widget.onComplete();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF444444), size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('ENHANCING AUDIO',
          style: TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w800,
              letterSpacing: 3, color: Color(0xFF666666))),
      ),
      body: _phase == _Phase.done ? _buildDoneBody() : _buildProcessingBody(),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESSING BODY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildProcessingBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Animated waveform ─────────────────────────────────────────────
        SizedBox(
          height: 120,
          child: CustomPaint(
            painter: _WaveformPainter(phase: _idlePhase, progress: _progress),
            size: Size.infinite,
          ),
        ),

        const SizedBox(height: 40),

        // ── Progress bar ─────────────────────────────────────────────────
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('PROCESSING', style: TextStyle(
              fontFamily: 'monospace', fontSize: 9, letterSpacing: 2.5, color: Color(0xFF444444))),
            Text('${(_progress * 100).toInt()}%', style: const TextStyle(
              fontFamily: 'monospace', fontSize: 9, letterSpacing: 1, color: Color(0xFF444444))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 3,
              backgroundColor: const Color(0xFF1A1A1A),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)),
            ),
          ),
        ]),

        const SizedBox(height: 32),

        // ── Log line ──────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F0F),
            border: Border.all(color: const Color(0xFF1E1E1E)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            Container(
              width: 6, height: 6,
              decoration: const BoxDecoration(color: Color(0xFFFF6B00), shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(_logLine, style: const TextStyle(
              fontFamily: 'monospace', fontSize: 10, color: Color(0xFF555555), letterSpacing: 0.5),
              overflow: TextOverflow.ellipsis)),
          ]),
        ),

        const Spacer(),

        const Text('DO NOT CLOSE THIS SCREEN',
          style: TextStyle(fontFamily: 'monospace', fontSize: 9,
              letterSpacing: 2, color: Color(0xFF2A2A2A))),
      ]),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DONE BODY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDoneBody() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF00E676), width: 2),
            boxShadow: [BoxShadow(
              color: const Color(0xFF00E676).withOpacity(0.25),
              blurRadius: 24, spreadRadius: 4,
            )],
          ),
          child: const Icon(Icons.check, color: Color(0xFF00E676), size: 36),
        ),
        const SizedBox(height: 24),
        const Text('PROCESSING COMPLETE', style: TextStyle(
          fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w800,
          letterSpacing: 2.5, color: Color(0xFF00E676))),
        const SizedBox(height: 10),
        const Text('Returning to preview…', style: TextStyle(
          fontFamily: 'monospace', fontSize: 10, color: Color(0xFF444444), letterSpacing: 1)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WAVEFORM PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  final double phase;
  final double progress;

  _WaveformPainter({required this.phase, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const barCount = 48;
    final barWidth = size.width / barCount;
    final cy = size.height / 2;

    for (int i = 0; i < barCount; i++) {
      final x = i * barWidth + barWidth / 2;
      final seed = i * 0.42;
      final amp = (math.sin(seed) * 0.3 + math.sin(seed * 2.1) * 0.2 + 0.5).clamp(0.1, 1.0);
      final wave = math.sin(phase * math.pi * 2 + seed) * amp;
      final barH  = (wave.abs() * cy * 0.85 + 4).clamp(4.0, cy * 0.95);

      final lit = x / size.width < progress;
      final color = lit
          ? Color.lerp(const Color(0xFFFF6B00), const Color(0xFFFFAA00), i / barCount)!
          : const Color(0xFF1E1E1E);

      paint.color = color;
      canvas.drawLine(Offset(x, cy - barH), Offset(x, cy + barH), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.phase != phase || old.progress != progress;
}
