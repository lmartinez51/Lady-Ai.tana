import 'package:aitana/core/services/notifications/auto_pilot_whitelist_service.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/features/notifications/models/auto_pilot_contact.dart';
import 'package:flutter/material.dart';

class AutoPilotWhitelistScreen extends StatefulWidget {
  const AutoPilotWhitelistScreen({super.key});

  @override
  State<AutoPilotWhitelistScreen> createState() =>
      _AutoPilotWhitelistScreenState();
}

class _AutoPilotWhitelistScreenState extends State<AutoPilotWhitelistScreen> {
  bool _isLoadingContacts = false;

  Future<void> _openContactsPicker(List<AutoPilotContact> savedContacts) async {
    setState(() => _isLoadingContacts = true);
    final messenger = ScaffoldMessenger.of(context);

    final granted = await AutoPilotWhitelistService.requestContactsPermission();
    if (!mounted) return;

    if (!granted) {
      setState(() => _isLoadingContacts = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Contacts permission denied.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final contacts = await AutoPilotWhitelistService.getDeviceContactNames();
    if (!mounted) return;
    setState(() => _isLoadingContacts = false);

    if (contacts.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No contacts found on this device.'),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    final savedNames = savedContacts
        .map(
          (contact) =>
              AutoPilotWhitelistService.normalizeForUi(contact.contactName),
        )
        .toSet();

    final selectedName = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _ContactPickerSheet(contacts: contacts, savedNames: savedNames),
    );

    if (selectedName == null || !mounted) return;

    final contact = await AutoPilotWhitelistService.addOrActivateContact(
      selectedName,
    );
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text('${contact.contactName} armed for Auto-Pilot.'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _deleteContact(AutoPilotContact contact) async {
    await AutoPilotWhitelistService.deleteContact(contact.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${contact.contactName} removed from Auto-Pilot.'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.obsidian,
      appBar: AppBar(
        backgroundColor: AppColors.obsidian,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'WhatsApp Auto-Pilot',
          style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.bold),
        ),
      ),
      body: StreamBuilder<List<AutoPilotContact>>(
        stream: AutoPilotWhitelistService.watchContacts(),
        builder: (context, snapshot) {
          final contacts =
              snapshot.data ?? AutoPilotWhitelistService.getContacts();

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoadingContacts
                          ? null
                          : () => _openContactsPicker(contacts),
                      icon: _isLoadingContacts
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.obsidian,
                              ),
                            )
                          : const Icon(Icons.contacts_rounded),
                      label: Text(
                        _isLoadingContacts
                            ? 'Loading contacts...'
                            : 'Select from Contacts',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.cyberBlue,
                        foregroundColor: AppColors.obsidian,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        textStyle: const TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: contacts.isEmpty
                      ? const _EmptyWhitelistState()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: contacts.length,
                          separatorBuilder: (_, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final contact = contacts[index];
                            return Dismissible(
                              key: ValueKey(contact.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withAlpha(80),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.delete_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              onDismissed: (_) => _deleteContact(contact),
                              child: _WhitelistContactTile(contact: contact),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _WhitelistContactTile extends StatelessWidget {
  const _WhitelistContactTile({required this.contact});

  final AutoPilotContact contact;

  @override
  Widget build(BuildContext context) {
    final color = contact.isActive ? AppColors.cyberBlue : Colors.white38;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withAlpha(28),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.smart_toy_rounded, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              contact.contactName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'Outfit',
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          Switch(
            value: contact.isActive,
            activeTrackColor: AppColors.cyberBlue,
            onChanged: (value) {
              AutoPilotWhitelistService.setContactActive(contact, value);
            },
          ),
        ],
      ),
    );
  }
}

class _ContactPickerSheet extends StatefulWidget {
  const _ContactPickerSheet({required this.contacts, required this.savedNames});

  final List<String> contacts;
  final Set<String> savedNames;

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.contacts.where((name) {
      return _query.isEmpty || name.toLowerCase().contains(_query);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.86,
      minChildSize: 0.48,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xF2161719),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: AppColors.glassBorder, width: 1.5),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Outfit',
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search contacts',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: Colors.white54,
                    ),
                    filled: true,
                    fillColor: Colors.white.withAlpha(14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.cyberBlue),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'No matches',
                          style: TextStyle(
                            color: Colors.white54,
                            fontFamily: 'Outfit',
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final name = filtered[index];
                          final normalized =
                              AutoPilotWhitelistService.normalizeForUi(name);
                          final alreadySaved = widget.savedNames.contains(
                            normalized,
                          );

                          return ListTile(
                            enabled: !alreadySaved,
                            leading: Icon(
                              alreadySaved
                                  ? Icons.check_circle_rounded
                                  : Icons.person_add_alt_1_rounded,
                              color: alreadySaved
                                  ? Colors.greenAccent
                                  : AppColors.cyberBlue,
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: alreadySaved
                                    ? Colors.white38
                                    : Colors.white,
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            onTap: alreadySaved
                                ? null
                                : () => Navigator.pop(context, name),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyWhitelistState extends StatelessWidget {
  const _EmptyWhitelistState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          'No contacts armed.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white54,
            fontFamily: 'Outfit',
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
