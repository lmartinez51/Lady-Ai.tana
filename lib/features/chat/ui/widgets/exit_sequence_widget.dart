import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:aitana/core/theme/widgets/system_lock_overlay.dart';
// (Asegúrate de importar tus AppColors y otros archivos necesarios aquí)

class ExitSequenceWidget extends StatefulWidget {
  /// Called once the 3-second exit animation has finished AND the processToWait is done.
  final VoidCallback onSequenceComplete;

  /// Tarea asíncrona (como el guardado de DB) que debe terminar antes de salir.
  final Future<void>? processToWait;

  const ExitSequenceWidget({
    super.key,
    required this.onSequenceComplete,
    this.processToWait, // Añadido como parámetro opcional
  });

  @override
  State<ExitSequenceWidget> createState() => _ExitSequenceWidgetState();
}

class _ExitSequenceWidgetState extends State<ExitSequenceWidget>
    with SingleTickerProviderStateMixin {
  // ── Animation ──────────────────────────────────────────────────────────────
  late final AnimationController _controller;

  // ── Shader ─────────────────────────────────────────────────────────────────
  ui.FragmentShader? _shader;
  bool _shaderLoaded = false;

  // ── Trails ─────────────────────────────────────────────────────────────────
  /// Rendered frame from the previous tick.
  ui.Image? _previousFrame;

  // ── Fix #1 – unmount guard ─────────────────────────────────────────────────
  /// Set to `false` in [dispose] before anything else.
  bool _isPainterActive = true;

  // ── Elapsed time (seconds) ─────────────────────────────────────────────────
  double _elapsedSeconds = 0.0;
  DateTime? _startTime;

  // ── Synchronization Flags ──────────────────────────────────────────────────
  bool _animationDone = false;
  bool _processDone = false;

  /// Verifica si tanto la animación como el proceso de fondo han terminado
  void _checkCompletion() {
    if (_animationDone && _processDone) {
      widget.onSequenceComplete();
    }
  }

  @override
  void initState() {
    super.initState();

    // [Fix A] Clock starts the moment the route is pushed
    _startTime = DateTime.now();

    // Configuración del Future a esperar
    if (widget.processToWait == null) {
      // Si no nos pasaron nada a qué esperar, marcamos el proceso como listo
      _processDone = true;
    } else {
      // Escuchamos cuando el guardado (o cualquier future) termine
      widget.processToWait!.whenComplete(() {
        if (mounted) {
          _processDone = true;
          _checkCompletion();
        }
      });
    }

    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..addListener(() {
            setState(() {
              _elapsedSeconds =
                  DateTime.now().difference(_startTime!).inMicroseconds / 1e6;
            });
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _animationDone = true;
              _checkCompletion();
            }
          });

    // Start the animation immediately
    _controller.forward();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/hypersphere_exit.frag',
      );
      if (mounted) {
        setState(() {
          _shader = program.fragmentShader();
          _shaderLoaded = true;
        });
      }
    } catch (e) {
      debugPrint('[ExitSequenceWidget] Shader load error: $e');
    }
  }

  /// Receives the composite captured from the previous tick.
  void _onFrameRendered(ui.Image? frame) {
    final old = _previousFrame;
    _previousFrame = frame;
    old?.dispose(); // [Fix #2] synchronous — no postFrameCallback
  }

  @override
  void dispose() {
    // [Fix #1] Raise the guard FIRST.
    _isPainterActive = false;

    _controller.dispose();
    _previousFrame?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1 – Black base (hard guarantee)
            const ColoredBox(color: Colors.black),

            // 2 – Shader + trails (background)
            if (_shaderLoaded && _shader != null)
              RepaintBoundary(
                child: CustomPaint(
                  painter: _ExitPainter(
                    shader: _shader!,
                    collapse: _controller.value,
                    time: _elapsedSeconds,
                    previousFrame: _previousFrame,
                    isPainterActive: _isPainterActive,
                    onFrameRendered: _onFrameRendered,
                  ),
                  size: Size.infinite,
                ),
              ),

            // 3 – Scrim for contrast
            ColoredBox(color: Colors.black.withAlpha(100)),

            // 4 – Foreground content
            const SystemLockOverlay(
              title: 'Saving neural memory...',
              subtitle: 'Disconnecting physical links...',
              showSpinner: false,
              overlayColor: Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ExitPainter
// ---------------------------------------------------------------------------

class _ExitPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final double collapse;
  final double time;
  final ui.Image? previousFrame;
  final bool isPainterActive;
  final void Function(ui.Image?) onFrameRendered;

  const _ExitPainter({
    required this.shader,
    required this.collapse,
    required this.time,
    required this.previousFrame,
    required this.isPainterActive,
    required this.onFrameRendered,
  });

  @override
  void paint(Canvas mainCanvas, Size size) {
    if (size.isEmpty) return;

    final double fullW = size.width;
    final double fullH = size.height;
    final Rect fullRect = Offset.zero & size;

    final int capW = fullW.round().clamp(1, 16384);
    final int capH = fullH.round().clamp(1, 16384);

    // ── Offscreen composite ──────────────────────────────────────────────────
    final recorder = ui.PictureRecorder();
    final offCanvas = Canvas(recorder);

    // Step 1 – Draw the previous frame (retained light from last tick).
    if (previousFrame != null) {
      offCanvas.drawImage(previousFrame!, Offset.zero, Paint());
    }

    // Step 2 – Decay the retained brightness with a semi-transparent black overlay.
    offCanvas.drawRect(
      fullRect,
      Paint()
        ..blendMode = BlendMode.srcOver
        ..color = Colors.black.withAlpha(72),
    );

    // Step 3 – Add the new shader frame with BlendMode.plus (additive).
    shader.setFloat(0, time);
    shader.setFloat(1, fullW);
    shader.setFloat(2, fullH);
    shader.setFloat(3, collapse);

    offCanvas.drawRect(
      fullRect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = shader,
    );

    // ── Capture & deliver the composite image for the next frame ────────────
    final picture = recorder.endRecording();

    // Draw synchronously FIRST so the current frame is always visible.
    mainCanvas.drawPicture(picture);

    // THEN kick off the async capture for the next frame's trail pass.
    picture.toImage(capW, capH).then((img) {
      picture.dispose();
      if (isPainterActive) {
        onFrameRendered(img);
      } else {
        img.dispose();
      }
    }, onError: (_) => picture.dispose());
  }

  @override
  bool shouldRepaint(_ExitPainter old) =>
      old.collapse != collapse ||
      old.time != time ||
      old.previousFrame != previousFrame;
}
