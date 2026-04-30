import 'package:flutter/material.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/core/domain/entities/geofence_record.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/geofencing/services/geofence_service.dart';

/// Developer Easter Egg: visualises the live GeofenceRecord log from ObjectBox.
///
/// Triggered by a long-press on the persona pill in [MainChatScreen].
/// Reads synchronously from ObjectBox — no async needed.
class DevGeofenceModal extends StatefulWidget {
  const DevGeofenceModal({super.key});

  @override
  State<DevGeofenceModal> createState() => _DevGeofenceModalState();
}

class _DevGeofenceModalState extends State<DevGeofenceModal> {
  late List<GeofenceRecord> records;

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  void _refreshList() {
    final repo = ObjectBoxService.instance.geofenceRepository;
    final all = repo.getAllRecords();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
    setState(() {
      records = all;
    });
  }

  Future<void> _confirmNukeAll(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E212B),
        title: const Text(
          'Clear All Records?',
          style: TextStyle(color: Colors.white, fontFamily: 'Outfit'),
        ),
        content: const Text(
          'This will permanently delete all geofence logs and unregister them from Android.',
          style: TextStyle(color: AppColors.textMedium, fontFamily: 'Outfit'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Nuke It', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await GeofenceService().clearAllGeofenceRecords();
      _refreshList();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF12141C), // slightly darker than obsidian
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ────────────────────────────────────────────────
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // ── Title row ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.cyberBlue.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.cyberBlue.withAlpha(60),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.bug_report_rounded,
                    color: AppColors.cyberBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DEV · Geofence Log',
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      'ObjectBox · GeofenceRecord',
                      style: TextStyle(
                        color: AppColors.textMedium,
                        fontFamily: 'Outfit',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // Panic Button
                IconButton(
                  onPressed: () => _confirmNukeAll(context),
                  icon: const Icon(
                    Icons.delete_forever,
                    color: Colors.redAccent,
                  ),
                  tooltip: 'Nuke All Records',
                ),
                // Live record count badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.deepIndigo,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.glassBorder, width: 1),
                  ),
                  child: Text(
                    '${records.length} records',
                    style: const TextStyle(
                      color: AppColors.textMedium,
                      fontFamily: 'Outfit',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          const Divider(color: AppColors.glassBorder, height: 1),

          // ── Record list ────────────────────────────────────────────────
          records.isEmpty
              ? const _EmptyState()
              : ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shrinkWrap: true,
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const Divider(
                      color: AppColors.glassBorder,
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                    ),
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return Dismissible(
                        key: ValueKey(record.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (direction) {
                          GeofenceService().removeGeofenceRecord(record.id);
                          setState(() {
                            records.removeAt(index);
                          });
                        },
                        child: _RecordTile(record: record),
                      );
                    },
                  ),
                ),

          // ── Bottom safe area ───────────────────────────────────────────
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }
}

// ── Private sub-widgets ────────────────────────────────────────────────────────

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final GeofenceRecord record;

  static String _fmt(DateTime dt) {
    String p(int v) => v.toString().padLeft(2, '0');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day} · ${p(dt.hour)}:${p(dt.minute)}:${p(dt.second)}';
  }

  ({String emoji, String label, Color color}) get _meta {
    return switch (record.status.toUpperCase()) {
      'TRIGGERED' => (
        emoji: '🟢',
        label: 'TRIGGERED',
        color: const Color(0xFF4CAF50),
      ),
      'FAILED' => (emoji: '🔴', label: 'FAILED', color: Colors.redAccent),
      _ => (emoji: '🟡', label: 'PENDING', color: const Color(0xFFFFCA28)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Status emoji ─────────────────────────────────────────────
          Text(meta.emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),

          // ── Main content ─────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + ID badge on same row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        record.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // ID chip
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.deepIndigo,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppColors.glassBorder,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        '#${record.id}',
                        style: const TextStyle(
                          color: AppColors.textMedium,
                          fontFamily: 'Outfit',
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 4),

                // Location key + status badge
                Row(
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 12,
                      color: AppColors.textMedium,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      record.locationKey,
                      style: const TextStyle(
                        color: AppColors.textMedium,
                        fontFamily: 'Outfit',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: meta.color.withAlpha(25),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: meta.color.withAlpha(80),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        meta.label,
                        style: TextStyle(
                          color: meta.color,
                          fontFamily: 'Outfit',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Timestamps
                Text(
                  'Created: ${_fmt(record.createdAt)}',
                  style: const TextStyle(
                    color: Colors.white30,
                    fontFamily: 'Outfit',
                    fontSize: 11,
                  ),
                ),
                if (record.triggeredAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Triggered: ${_fmt(record.triggeredAt!)}',
                      style: const TextStyle(
                        color: Color(0xFF4CAF50),
                        fontFamily: 'Outfit',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_off_outlined, color: Colors.white24, size: 40),
          SizedBox(height: 12),
          Text(
            'No geofence records yet.',
            style: TextStyle(
              color: Colors.white38,
              fontFamily: 'Outfit',
              fontSize: 14,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Ask Aitana to schedule a location reminder.',
            style: TextStyle(
              color: Colors.white24,
              fontFamily: 'Outfit',
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
