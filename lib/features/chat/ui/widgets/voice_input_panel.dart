import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/services/audio/wav_start_trimmer.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';

class VoiceInputPanel extends StatefulWidget {
  final TextEditingController textController;
  final FocusNode focusNode;
  final bool isLoading;
  final String? selectedImagePath;
  final ValueNotifier<bool> isTypingNotifier;
  final ValueListenable<bool> attachmentMenuOpenListenable;
  final VoidCallback onAttachmentPressed;
  final VoidCallback onSendText;
  final Function(String path) onAudioRecorded;

  const VoiceInputPanel({
    super.key,
    required this.textController,
    required this.focusNode,
    required this.isLoading,
    this.selectedImagePath,
    required this.isTypingNotifier,
    required this.attachmentMenuOpenListenable,
    required this.onAttachmentPressed,
    required this.onSendText,
    required this.onAudioRecorded,
  });

  @override
  State<VoiceInputPanel> createState() => VoiceInputPanelState();
}

class VoiceInputPanelState extends State<VoiceInputPanel> {
  static const MethodChannel _aiCoreChannel = MethodChannel(
    NativeChannels.aiCore,
  );

  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _hasSpoken = false;

  // --- VAD (Silence Detection) PARAMS ---
  final double _vadThreshold = -20.0;
  final double _vadSpeechHysteresisDb = -28.0;
  final int _vadSilenceDurationMs = 2500;
  final int _vadInitialTimeoutMs = 7000;
  final int _earconPlaybackMs = 100;
  final int _earconTailMs = 260;
  static const int _hardStopDurationS = 20;

  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _silenceTimer;
  Timer? _hardStopTimer;
  DateTime? _recordingStartedAt;
  DateTime? _speechGateOpensAt;

  @override
  void dispose() {
    _audioRecorder.dispose();
    _amplitudeSubscription?.cancel();
    _silenceTimer?.cancel();
    _hardStopTimer?.cancel();
    super.dispose();
  }

  Future<void> startManualRecording() async {
    if (!_isRecording && mounted) {
      await _startRecording();
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/aitana_audio_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: filePath,
      );

      _recordingStartedAt = DateTime.now();
      _speechGateOpensAt = _recordingStartedAt!.add(
        Duration(milliseconds: _earconPlaybackMs + _earconTailMs),
      );

      if (!mounted) {
        final orphanedPath = await _audioRecorder.stop();
        if (orphanedPath != null) {
          try {
            final orphanedFile = File(orphanedPath);
            if (await orphanedFile.exists()) await orphanedFile.delete();
          } catch (e) {
            debugPrint('Could not delete orphaned temp audio: $e');
          }
        }
        _recordingStartedAt = null;
        _speechGateOpensAt = null;
        return;
      }

      setState(() {
        _isRecording = true;
        _hasSpoken = false;
      });

      HapticFeedback.lightImpact();
      unawaited(_playReadinessEarcon());

      _hardStopTimer = Timer(const Duration(seconds: _hardStopDurationS), () {
        if (_isRecording && mounted) _stopRecording(cancelAndDiscard: true);
      });

      _amplitudeSubscription = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((Amplitude amplitude) {
            final speechGateOpensAt = _speechGateOpensAt;
            if (speechGateOpensAt != null &&
                DateTime.now().isBefore(speechGateOpensAt)) {
              return;
            }

            if (amplitude.current > _vadThreshold) {
              _silenceTimer?.cancel();
              _silenceTimer = null;
              _hasSpoken = true;
            } else {
              if (_hasSpoken) {
                if (amplitude.current > _vadSpeechHysteresisDb) {
                  _silenceTimer?.cancel();
                  _silenceTimer = Timer(
                    Duration(milliseconds: _vadSilenceDurationMs),
                    () {
                      if (_isRecording && mounted) _stopRecording();
                    },
                  );
                } else {
                  _silenceTimer ??= Timer(
                    Duration(milliseconds: _vadSilenceDurationMs),
                    () {
                      if (_isRecording && mounted) _stopRecording();
                    },
                  );
                }
              } else {
                _silenceTimer ??= Timer(
                  Duration(milliseconds: _vadInitialTimeoutMs),
                  () {
                    if (_isRecording && mounted) {
                      _stopRecording(cancelAndDiscard: true);
                    }
                  },
                );
              }
            }
          });
    }
  }

  Future<void> _playReadinessEarcon() async {
    try {
      final played = await _aiCoreChannel.invokeMethod<bool>(
        'playReadinessEarcon',
        {'durationMs': _earconPlaybackMs},
      );
      if (played != true) {
        debugPrint('Native readiness earcon did not start.');
      }
    } catch (e) {
      debugPrint('Could not play readiness earcon: $e');
    }
  }

  Future<void> _stopRecording({bool cancelAndDiscard = false}) async {
    final trimDuration = _calculateEarconTrimDuration();
    _hardStopTimer?.cancel();
    _hardStopTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _recordingStartedAt = null;
    _speechGateOpensAt = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    final String? path = await _audioRecorder.stop();
    if (path != null) {
      if (cancelAndDiscard) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('⚠️ Could not delete discarded temp audio: $e');
        }
        if (mounted) setState(() => _isRecording = false);
      } else {
        if (mounted) setState(() => _isRecording = false);
        final trimmedPath = await _trimEarconFromRecording(path, trimDuration);
        widget.onAudioRecorded(trimmedPath);
      }
    }
  }

  Duration _calculateEarconTrimDuration() {
    final startedAt = _recordingStartedAt;
    final speechGateOpensAt = _speechGateOpensAt;
    if (startedAt == null || speechGateOpensAt == null) {
      return Duration.zero;
    }
    final trimDuration = speechGateOpensAt.difference(startedAt);
    return trimDuration.isNegative ? Duration.zero : trimDuration;
  }

  Future<String> _trimEarconFromRecording(
    String path,
    Duration trimDuration,
  ) async {
    if (trimDuration <= Duration.zero) return path;

    try {
      final trimmedPath = await WavStartTrimmer.trimStart(
        inputPath: path,
        trimDuration: trimDuration,
      );
      if (trimmedPath != path) {
        final originalFile = File(path);
        if (await originalFile.exists()) {
          await originalFile.delete();
        }
      }
      return trimmedPath;
    } catch (e) {
      debugPrint('Could not trim readiness earcon from WAV: $e');
      return path;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFieldTapRegion(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.deepIndigo,
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: AppColors.glassBorder, width: 1.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(70),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Left actions ──
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _isRecording
                  ? const SizedBox(width: 12, key: ValueKey('pad'))
                  : Padding(
                      key: const ValueKey('actions'),
                      padding: const EdgeInsets.only(
                        left: 6.0,
                        top: 6.0,
                        bottom: 6.0,
                      ),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: widget.attachmentMenuOpenListenable,
                        builder: (context, isOpen, _) {
                          return _AttachmentPlusButton(
                            isOpen: isOpen,
                            isEnabled: !widget.isLoading || isOpen,
                            onPressed: widget.onAttachmentPressed,
                          );
                        },
                      ),
                    ),
            ),

            // ── Center: TextField OR Waveform ──
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isRecording
                    ? const Padding(
                        key: ValueKey('wave'),
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 14,
                        ),
                        child: _WaveformWidget(),
                      )
                    : TextField(
                        key: const ValueKey('textfield'),
                        controller: widget.textController,
                        focusNode: widget.focusNode,
                        maxLines: 5,
                        minLines: 1,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'Outfit',
                          fontSize: 15,
                        ),
                        cursorColor: AppColors.cyberBlue,
                        onTapOutside: (PointerDownEvent event) =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        decoration: const InputDecoration(
                          hintText: 'Message Aitana...',
                          hintStyle: TextStyle(
                            color: Colors.white30,
                            fontFamily: 'Outfit',
                          ),
                          filled: true,
                          fillColor: Colors.transparent,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 12,
                          ),
                        ),
                      ),
              ),
            ),

            // ── Right: action button ──
            ValueListenableBuilder<bool>(
              valueListenable: widget.isTypingNotifier,
              builder: (context, isTyping, _) {
                final showSend = isTyping || widget.selectedImagePath != null;
                return Padding(
                  padding: const EdgeInsets.all(6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: widget.isLoading
                          ? Colors.grey[800]
                          : _isRecording
                          ? Colors.redAccent.withAlpha(30)
                          : AppColors.cyberBlue.withAlpha(40),
                      shape: BoxShape.circle,
                      border: _isRecording
                          ? Border.all(
                              color: Colors.redAccent.withAlpha(160),
                              width: 1.5,
                            )
                          : null,
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) =>
                          ScaleTransition(scale: animation, child: child),
                      child: widget.isLoading
                          ? IconButton(
                              key: const ValueKey('stop'),
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                color: Colors.redAccent,
                                size: 22,
                              ),
                              tooltip: 'Stop generation',
                              onPressed: () {
                                LocalLlmService.stopInference();
                              },
                            )
                          : showSend
                          ? IconButton(
                              key: const ValueKey('send'),
                              icon: const Icon(
                                Icons.send_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              onPressed: widget.onSendText,
                            )
                          : IconButton(
                              key: const ValueKey('mic'),
                              icon: Icon(
                                _isRecording
                                    ? Icons.stop_rounded
                                    : Icons.mic_none_rounded,
                                color: _isRecording
                                    ? Colors.redAccent
                                    : AppColors.cyberBlue,
                                size: 22,
                              ),
                              onPressed: _toggleRecording,
                            ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentPlusButton extends StatelessWidget {
  final bool isOpen;
  final bool isEnabled;
  final VoidCallback onPressed;

  const _AttachmentPlusButton({
    required this.isOpen,
    required this.isEnabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = isEnabled
        ? const Color(0xFF00F0FF)
        : Colors.white.withAlpha(76);

    return Tooltip(
      message: isOpen ? 'Close attachments' : 'Open attachments',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: 44,
        width: 44,
        decoration: BoxDecoration(
          color: isOpen
              ? const Color(0x3300F0FF)
              : AppColors.cyberBlue.withAlpha(40),
          shape: BoxShape.circle,
          border: Border.all(
            color: isOpen ? const Color(0x9900F0FF) : Colors.transparent,
            width: 1,
          ),
          boxShadow: isOpen
              ? const [
                  BoxShadow(
                    color: Color(0x3300F0FF),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: isEnabled ? onPressed : null,
            splashColor: const Color(0x3300F0FF),
            highlightColor: const Color(0x1F00F0FF),
            child: Center(
              child: AnimatedRotation(
                turns: isOpen ? 0.125 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(Icons.add_rounded, color: iconColor, size: 27),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformWidget extends StatefulWidget {
  const _WaveformWidget();

  @override
  State<_WaveformWidget> createState() => _WaveformWidgetState();
}

class _WaveformWidgetState extends State<_WaveformWidget>
    with TickerProviderStateMixin {
  static const int _barCount = 5;
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  static const List<int> _delays = [0, 120, 60, 180, 30];
  static const List<int> _durations = [420, 360, 500, 380, 450];

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(_barCount, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: _durations[i]),
      );
    });

    _animations = List.generate(_barCount, (i) {
      return Tween<double>(begin: 0.15, end: 1.0).animate(
        CurvedAnimation(parent: _controllers[i], curve: Curves.easeInOut),
      );
    });

    for (int i = 0; i < _barCount; i++) {
      Future.delayed(Duration(milliseconds: _delays[i]), () {
        if (mounted) {
          _controllers[i].repeat(reverse: true);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(_barCount, (i) {
        return AnimatedBuilder(
          animation: _animations[i],
          builder: (context, child) {
            final height = 6.0 + (_animations[i].value * 22.0);
            return Container(
              width: 4,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: AppColors.cyberBlue.withAlpha(200),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          },
        );
      }),
    );
  }
}
