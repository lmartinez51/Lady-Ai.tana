import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:math';
import 'package:aitana/core/theme/app_colors.dart'; // Ajusta la ruta si es necesario

class AudioBubble extends StatefulWidget {
  final String audioPath;
  final String durationText;
  final bool isUser;

  const AudioBubble({
    super.key,
    required this.audioPath,
    required this.durationText,
    required this.isUser,
  });

  @override
  State<AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<AudioBubble> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  final List<double> _waveformHeights = [];

  @override
  void initState() {
    super.initState();
    _generateMockWaveform();
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void _generateMockWaveform() {
    final random = Random();
    for (int i = 0; i < 25; i++) {
      _waveformHeights.add(random.nextDouble() * 20 + 4);
    }
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      try {
        await _audioPlayer.play(DeviceFileSource(widget.audioPath));
      } catch (e) {
        debugPrint("Audio playback error: $e");
      }
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  @override
  Widget build(BuildContext context) {
    final waveColor = widget.isUser ? Colors.white70 : AppColors.cyberBlue.withAlpha(150);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: widget.isUser
                  ? Colors.white.withAlpha(51) // ~0.2
                  : AppColors.cyberBlue,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: widget.isUser ? Colors.white : AppColors.obsidian,
              size: 24,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 30,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: _waveformHeights.map((height) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                width: 3,
                height: height,
                decoration: BoxDecoration(
                  color: waveColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          widget.durationText,
          style: TextStyle(
            color: widget.isUser ? Colors.white : AppColors.textMedium,
            fontFamily: 'Outfit',
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}