import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

class ExitSequenceWidget extends StatefulWidget {
  /// Called once the 3-second exit animation has finished AND the processToWait is done.
  final VoidCallback onSequenceComplete;

  /// Tarea asíncrona (como el guardado de DB) que debe terminar antes de salir.
  final Future<void>? processToWait;

  const ExitSequenceWidget({
    super.key,
    required this.onSequenceComplete,
    this.processToWait,
  });

  @override
  State<ExitSequenceWidget> createState() => _ExitSequenceWidgetState();
}

class _ExitSequenceWidgetState extends State<ExitSequenceWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  
  bool _animationDone = false;
  bool _processDone = false;

  void _checkCompletion() {
    if (_animationDone && _processDone) {
      widget.onSequenceComplete();
    }
  }

  @override
  void initState() {
    super.initState();

    if (widget.processToWait == null) {
      _processDone = true;
    } else {
      widget.processToWait!.whenComplete(() {
        if (mounted) {
          _processDone = true;
          _checkCompletion();
        }
      });
    }

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _animationDone = true;
          _checkCompletion();
        }
      });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SpinKitFadingCircle(
              color: Color(0xFF00F0FF),
              size: 64.0,
            ),
            const SizedBox(height: 32),
            const Text(
              'Synchronizing neural core...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Safeguarding memories and optimizing Vault vectors.\nAitana is safely disconnecting, please stand by...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                color: Colors.white54,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
