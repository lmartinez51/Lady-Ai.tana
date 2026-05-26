import 'dart:io';
import 'dart:ui';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/vault/models/personal_vault_image.dart';
import 'package:aitana/features/vault/services/batch_ingestion_manager.dart';
import 'package:aitana/features/vault/services/vault_ingestion_service.dart';
import 'package:aitana/objectbox.g.dart';

class VaultManagerScreen extends StatefulWidget {
  final BatchIngestionManager? batchManager;

  const VaultManagerScreen({super.key, this.batchManager});

  @override
  State<VaultManagerScreen> createState() => _VaultManagerScreenState();
}

class _VaultManagerScreenState extends State<VaultManagerScreen> {
  final ImagePicker _picker = ImagePicker();
  final Box<PersonalVaultImage> _vaultBox =
      ObjectBoxService.instance.vaultImageBox;
  late final BatchIngestionManager _batchManager;

  @override
  void initState() {
    super.initState();
    _batchManager =
        widget.batchManager ?? BatchIngestionManager(VaultIngestionService());
  }

  /// Trigger the batch picking and processing flow.
  Future<void> _handleBatchAnalysis() async {
    final List<XFile> pickedFiles = await _picker.pickMultiImage();
    if (pickedFiles.isNotEmpty) {
      final List<String> paths = pickedFiles.map((f) => f.path).toList();
      await _batchManager.processImageBatch(paths);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepIndigo.withValues(alpha: 0.95),
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          // Background subtle gradients for depth
          Positioned(
            top: -100,
            right: -100,
            child: _buildBlurCircle(
              AppColors.cyberBlue.withValues(alpha: 0.15),
            ),
          ),
          Positioned(
            bottom: -50,
            left: -50,
            child: _buildBlurCircle(Colors.purple.withValues(alpha: 0.1)),
          ),

          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDashboardHeader(),
                _buildActionSection(),
                _buildProgressSection(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Text(
                    "Stored Content",
                    style: TextStyle(
                      color: Colors.white70,
                      fontFamily: 'Outfit',
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Expanded(child: _buildVaultGrid()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AppBar(
            backgroundColor: Colors.white.withValues(alpha: 0.05),
            elevation: 0,
            title: const Text(
              "SECURITY VAULT",
              style: TextStyle(
                fontFamily: 'Outfit',
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                fontSize: 16,
              ),
            ),
            centerTitle: true,
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardHeader() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Personal Vault",
            style: TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 8),
          StreamBuilder<int>(
            stream: _vaultBox
                .query()
                .watch(triggerImmediately: true)
                .map((q) => q.count()),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              return Text(
                "$count items analyzed and secured",
                style: const TextStyle(
                  color: AppColors.cyberBlue,
                  fontSize: 16,
                  fontFamily: 'Outfit',
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildActionSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    "Batch Analysis",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "Process up to 3 images simultaneously.",
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
            ValueListenableBuilder<BatchProgress>(
              valueListenable: _batchManager.progress,
              builder: (context, progress, child) {
                // Disable button if totalImages > 0 and batch is not finished.
                final bool isProcessing =
                    progress.totalImages > 0 && !progress.isFinished;

                return ElevatedButton(
                  onPressed: isProcessing ? null : _handleBatchAnalysis,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.cyberBlue,
                    disabledBackgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  child: const Text("Analyze"),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection() {
    return ValueListenableBuilder<BatchProgress>(
      valueListenable: _batchManager.progress,
      builder: (context, progress, child) {
        if (progress.isFinished || progress.totalImages == 0) {
          return const SizedBox.shrink();
        }

        final double percent =
            progress.currentImageIndex / progress.totalImages;

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.cyberBlue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.cyberBlue.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      progress.currentStatus,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    Text(
                      "${(percent * 100).toInt()}%",
                      style: const TextStyle(
                        color: AppColors.cyberBlue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: percent,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation(
                      AppColors.cyberBlue,
                    ),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVaultGrid() {
    return StreamBuilder<List<PersonalVaultImage>>(
      stream: _vaultBox
          .query()
          .order(PersonalVaultImage_.uploadDate, flags: Order.descending)
          .watch(triggerImmediately: true)
          .map((query) => query.find()),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 48,
                  color: Colors.white24,
                ),
                SizedBox(height: 16),
                Text(
                  "The vault is empty",
                  style: TextStyle(color: Colors.white38),
                ),
              ],
            ),
          );
        }

        final images = snapshot.data!;

        return GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1,
          ),
          itemCount: images.length,
          itemBuilder: (context, index) {
            final img = images[index];
            return GestureDetector(
              onTap: () => _showItemInspector(context, img),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(img.fileUri), fit: BoxFit.cover),
                      // Glassy overlay for the shelf label
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ClipRRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 12,
                              ),
                              color: Colors.black.withValues(alpha: 0.3),
                              child: Builder(
                                builder: (context) {
                                  final analysis = img.analysisChunks.isNotEmpty
                                      ? img.analysisChunks.first
                                      : null;
                                  final emoji = analysis?.categoryEmoji ?? '📁';
                                  final keyword =
                                      analysis?.categoryKeyword ?? 'General';
                                  final dateStr = DateFormat(
                                    "MMM ''yy",
                                  ).format(img.uploadDate);

                                  return Text(
                                    '$emoji $keyword • $dateStr',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      fontFamily: 'Outfit',
                                    ),
                                    textAlign: TextAlign.center,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showItemInspector(BuildContext context, PersonalVaultImage image) {
    final analysis = image.analysisChunks.isNotEmpty
        ? image.analysisChunks.first
        : null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: const BoxDecoration(
            color: Color(0xFF1E1F20),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Builder(
                          builder: (context) {
                            final emoji = analysis?.categoryEmoji ?? '📁';
                            final keyword =
                                analysis?.categoryKeyword ?? 'General';
                            final dateStr = DateFormat(
                              "MMM ''yy",
                            ).format(image.uploadDate);
                            return Text(
                              '$emoji $keyword • $dateStr',
                              style: const TextStyle(
                                color: AppColors.cyberBlue,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            );
                          },
                        ),
                        const Text(
                          "Technical Analysis",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.delete_forever_rounded,
                            color: Colors.redAccent,
                          ),
                          onPressed: () => _confirmDeletion(context, image),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              // Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow(
                        "DESCRIPTION",
                        analysis?.imageDescription ?? "Pending analysis...",
                      ),
                      _buildInfoRow(
                        "OBJECTS DETECTED",
                        analysis?.objects ?? "None identified",
                      ),
                      _buildInfoRow(
                        "ENVIRONMENT",
                        analysis?.environment ?? "Unknown",
                      ),
                      _buildInfoRow(
                        "TEXT / OCR",
                        analysis?.textContent.isNotEmpty == true
                            ? analysis!.textContent
                            : "No text detected",
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "RAW DATA (KOTLIN BRIDGE)",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: SelectableText(
                          analysis?.rawJson ?? "{}",
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(height: MediaQuery.of(context).padding.bottom),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlurCircle(Color color) {
    return Container(
      width: 300,
      height: 300,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Future<void> _confirmDeletion(
    BuildContext context,
    PersonalVaultImage image,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F20),
          title: const Text(
            "Confirm deletion",
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            "Are you sure you want to delete this item from the vault? This action will permanently delete the record and the physical file.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                "CANCEL",
                style: TextStyle(color: Colors.white38),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                "DELETE",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      if (!context.mounted) return;
      // Close the inspector modal
      Navigator.pop(context);

      // Perform deletion
      await ObjectBoxService.instance.deleteVaultItem(image.id);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Item deleted from the vault."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
