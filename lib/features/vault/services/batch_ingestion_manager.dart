import 'package:flutter/foundation.dart';
import 'vault_ingestion_service.dart';

/// Represents the real-time state of a batch processing operation.
class BatchProgress {
  final int currentImageIndex;
  final int totalImages;
  final String currentStatus;
  final bool isFinished;

  BatchProgress({
    required this.currentImageIndex,
    required this.totalImages,
    required this.currentStatus,
    this.isFinished = false,
  });

  /// Factory for the initial state.
  factory BatchProgress.initial(int total) => BatchProgress(
    currentImageIndex: 0,
    totalImages: total,
    currentStatus: 'Starting batch...',
  );

  /// Factory for the final completed state.
  factory BatchProgress.finished(int total) => BatchProgress(
    currentImageIndex: total,
    totalImages: total,
    currentStatus: 'Batch completed.',
    isFinished: true,
  );
}

/// Manager responsible for sequential image processing to prevent GPU/RAM exhaustion.
///
/// This manager ensures that only one Vision LLM inference happens at a time,
/// which is critical for local on-device models with limited VRAM.
class BatchIngestionManager {
  static const int _maxBatchSize = 3;

  final VaultIngestionService _vaultIngestionService;

  /// Guard flag to prevent re-entrancy and concurrent batch processing.
  bool _isProcessing = false;

  /// Communicates progress back to the UI layers.
  final ValueNotifier<BatchProgress> progress = ValueNotifier(
    BatchProgress.initial(0),
  );

  BatchIngestionManager(this._vaultIngestionService);

  /// Processes a list of images sequentially.
  ///
  /// Truncates the input to [_maxBatchSize] to maintain system stability.
  /// Each image is processed in a try-catch block to ensure that a single failure
  /// does not halt the entire queue.
  Future<void> processImageBatch(List<String> imagePaths) async {
    // Busy Guard: return immediately if a batch is already in progress.
    if (_isProcessing) return;

    _isProcessing = true;

    try {
      // 1. Truncate batch size for safety
      final List<String> targetBatch = imagePaths.take(_maxBatchSize).toList();
      final int total = targetBatch.length;

      progress.value = BatchProgress.initial(total);

      for (int i = 0; i < total; i++) {
        final String path = targetBatch[i];
        final int displayIndex = i + 1;

        progress.value = BatchProgress(
          currentImageIndex: displayIndex,
          totalImages: total,
          currentStatus: 'Processing image $displayIndex of $total...',
        );

        try {
          final result = await _vaultIngestionService.ingestImage(path);

          // Update status based on individual result
          String resultMsg;
          switch (result) {
            case IngestionStatus.success:
              resultMsg = 'Image $displayIndex processed successfully.';
              break;
            case IngestionStatus.duplicate:
              resultMsg = 'Image $displayIndex already in vault. Skipping.';
              break;
            case IngestionStatus.error:
              resultMsg = 'Error processing image $displayIndex.';
              break;
          }

          progress.value = BatchProgress(
            currentImageIndex: displayIndex,
            totalImages: total,
            currentStatus: resultMsg,
          );
        } catch (e) {
          debugPrint('BatchIngestionManager: Failure at index $i ($path): $e');
          progress.value = BatchProgress(
            currentImageIndex: displayIndex,
            totalImages: total,
            currentStatus:
                'Critical error at image $displayIndex. Continuing...',
          );
        }

        // Small delay between inferences to allow GPU memory to settle
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Mark as finished
      progress.value = BatchProgress.finished(total);
    } finally {
      // Release the lock
      _isProcessing = false;
    }
  }
}
