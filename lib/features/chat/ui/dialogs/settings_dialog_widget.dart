import 'package:flutter/material.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/chat/services/llm/models/llm_inference_params.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';

class SettingsDialogWidget extends StatefulWidget {
  final double initialTemp;
  final double initialTopP;
  final int initialTopK;
  final bool initialThinking;
  final bool hasHistory;
  final Function(
    double temp,
    double topP,
    int topK,
    bool thinking,
    bool clearHistory,
  )
  onApply;

  const SettingsDialogWidget({
    super.key,
    required this.initialTemp,
    required this.initialTopP,
    required this.initialTopK,
    required this.initialThinking,
    required this.hasHistory,
    required this.onApply,
  });

  static void show(
    BuildContext context, {
    required double initialTemp,
    required double initialTopP,
    required int initialTopK,
    required bool initialThinking,
    required bool hasHistory,
    required Function(
      double temp,
      double topP,
      int topK,
      bool thinking,
      bool clearHistory,
    )
    onApply,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return SettingsDialogWidget(
          initialTemp: initialTemp,
          initialTopP: initialTopP,
          initialTopK: initialTopK,
          initialThinking: initialThinking,
          hasHistory: hasHistory,
          onApply: onApply,
        );
      },
    );
  }

  @override
  State<SettingsDialogWidget> createState() => _SettingsDialogWidgetState();
}

class _SettingsDialogWidgetState extends State<SettingsDialogWidget> {
  late double tempTemp;
  late double tempTopP;
  late int tempTopK;
  late bool tempThinking;

  @override
  void initState() {
    super.initState();
    tempTemp = widget.initialTemp;
    tempTopP = widget.initialTopP;
    tempTopK = widget.initialTopK;
    tempThinking = widget.initialThinking;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.obsidian,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.glassBorder, width: 1),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            "Model Parameters",
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Outfit',
              fontWeight: FontWeight.bold,
            ),
          ),
          GestureDetector(
            onTap: () => _showParameterInfo(
              context,
              '🔥 Roast Protocol (Spicy Mode)',
              'Need to blow off some steam and start a digital bar fight? Dial in these settings for maximum emotional damage:\n\n• Temperature: 0.85 (Liquid courage)\n• Top K: 80 (Unlocks the forbidden dictionary)\n• Enable Thinking: ON (So she logically plots your demise)\n\nDisclaimer: Do not use these settings if you actually need to schedule something... or if you have a fragile ego.',
              actionLabel: 'ENGAGE SPICY MODE',
              onAction: () {
                setState(() {
                  tempTemp = 0.85;
                  tempTopK = 80;
                  tempThinking = true;
                });
              },
            ),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4.0),
              child: Icon(
                Icons.local_fire_department,
                color: Colors.deepOrangeAccent,
                size: 24,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.deepIndigo.withAlpha(127),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.memory, color: Colors.white54, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    "Accelerator: ",
                    style: TextStyle(
                      color: Colors.white54,
                      fontFamily: 'Outfit',
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.cyberBlue.withAlpha(40),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AppColors.cyberBlue.withAlpha(100),
                        width: 0.5,
                      ),
                    ),
                    child: const Text(
                      "√ CPU",
                      style: TextStyle(
                        color: AppColors.cyberBlue,
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                children: [
                  const Text(
                    "Enable thinking",
                    style: TextStyle(color: Colors.white, fontFamily: 'Outfit'),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showParameterInfo(
                      context,
                      "Enable Thinking",
                      'Forces the AI to reason internally before replying. Slower response, but much smarter logic.',
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Switch(
                    activeTrackColor: AppColors.cyberBlue,
                    value: tempThinking,
                    onChanged: (val) => setState(() => tempThinking = val),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.glassBorder),
            _ParameterSlider(
              label: "Temperature",
              tooltipMessage:
                  'Controls randomness. Low (0.2): Strict & focused (Best for tools/tasks). High (0.8): Creative & chaotic (Best for roasting).',
              min: 0.0,
              max: 2.0,
              value: tempTemp,
              isDouble: true,
              onChanged: (val) => setState(() => tempTemp = val),
            ),
            _ParameterSlider(
              label: "Top K",
              tooltipMessage:
                  'Vocabulary pool size. Low: Uses common, safe words. High: Expands word choices, more dynamic.',
              min: 1,
              max: 100,
              value: tempTopK.toDouble(),
              isDouble: false,
              onChanged: (val) => setState(() => tempTopK = val.toInt()),
            ),
            _ParameterSlider(
              label: "Top P",
              tooltipMessage:
                  'Probability threshold. Low: Predictable phrasing. High: Diverse and expressive sentence structures.',
              min: 0.0,
              max: 1.0,
              value: tempTopP,
              isDouble: true,
              onChanged: (val) => setState(() => tempTopP = val),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: () {
            setState(() {
              tempTemp = const LlmInferenceParams().temperature;
              tempTopK = const LlmInferenceParams().topK;
              tempTopP = const LlmInferenceParams().topP;
              tempThinking = const LlmInferenceParams().enableThinking;
            });
          },
          icon: const Icon(
            Icons.restart_alt_rounded,
            size: 18,
            color: Colors.redAccent,
          ),
          label: const Text(
            'Reset',
            style: TextStyle(color: Colors.redAccent, fontFamily: 'Outfit'),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54, fontFamily: 'Outfit'),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.cyberBlue,
                foregroundColor: AppColors.obsidian,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () async {
                Navigator.pop(context);

                if (widget.hasHistory) {
                  final bool? confirmed = await showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder: (BuildContext ctx) {
                      return AlertDialog(
                        backgroundColor: AppColors.obsidian,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: const BorderSide(
                            color: AppColors.glassBorder,
                            width: 1,
                          ),
                        ),
                        title: const Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orangeAccent,
                              size: 22,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Clear Memory?',
                              style: TextStyle(
                                color: Colors.white,
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        content: const Text(
                          'Applying new parameters will clear the current conversation memory. Proceed?',
                          style: TextStyle(
                            color: Colors.white70,
                            fontFamily: 'Outfit',
                            height: 1.4,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                color: Colors.white54,
                                fontFamily: 'Outfit',
                              ),
                            ),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orangeAccent,
                              foregroundColor: AppColors.obsidian,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text(
                              'Proceed',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Outfit',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirmed != true) return;
                }

                await LocalLlmService.updateSamplerParams(
                  LlmInferenceParams(
                    temperature: tempTemp,
                    topK: tempTopK,
                    topP: tempTopP,
                    enableThinking: tempThinking,
                  ),
                );

                widget.onApply(
                  tempTemp,
                  tempTopP,
                  tempTopK,
                  tempThinking,
                  widget.hasHistory,
                );
              },
              child: const Text(
                'OK',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Outfit',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void _showParameterInfo(
  BuildContext context,
  String title,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.deepIndigo,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Outfit',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepOrangeAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      onAction();
                    },
                    child: Text(
                      actionLabel,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

class _ParameterSlider extends StatefulWidget {
  final String label;
  final String tooltipMessage;
  final double min;
  final double max;
  final double value;
  final bool isDouble;
  final ValueChanged<double> onChanged;

  const _ParameterSlider({
    required this.label,
    required this.tooltipMessage,
    required this.min,
    required this.max,
    required this.value,
    required this.isDouble,
    required this.onChanged,
  });

  @override
  State<_ParameterSlider> createState() => _ParameterSliderState();
}

class _ParameterSliderState extends State<_ParameterSlider> {
  late TextEditingController _inputCtrl;
  late double _currentValue;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.value;
    _inputCtrl = TextEditingController(text: _formatValue(_currentValue));
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ParameterSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      setState(() {
        _currentValue = widget.value;
        _inputCtrl.text = _formatValue(_currentValue);
      });
    }
  }

  String _formatValue(double val) {
    return widget.isDouble ? val.toStringAsFixed(2) : val.toInt().toString();
  }

  void _updateFromText(String text) {
    double? parsed = double.tryParse(text);
    if (parsed != null) {
      if (parsed < widget.min) parsed = widget.min;
      if (parsed > widget.max) parsed = widget.max;
      setState(() {
        _currentValue = parsed!;
        _inputCtrl.text = _formatValue(_currentValue);
      });
      widget.onChanged(_currentValue);
    } else {
      _inputCtrl.text = _formatValue(_currentValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'Outfit',
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _showParameterInfo(
                  context,
                  widget.label,
                  widget.tooltipMessage,
                ),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.info_outline, size: 16, color: Colors.grey),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: AppColors.cyberBlue,
                    inactiveTrackColor: Colors.white12,
                    thumbColor: Colors.white,
                    overlayColor: AppColors.cyberBlue.withAlpha(50),
                    trackHeight: 4.0,
                  ),
                  child: Slider(
                    value: _currentValue,
                    min: widget.min,
                    max: widget.max,
                    divisions: widget.isDouble
                        ? 100
                        : (widget.max - widget.min).toInt(),
                    onChanged: (val) {
                      setState(() {
                        _currentValue = val;
                        _inputCtrl.text = _formatValue(val);
                      });
                      widget.onChanged(val);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _inputCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Outfit',
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    filled: true,
                    fillColor: Colors.white.withAlpha(15),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: _updateFromText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
