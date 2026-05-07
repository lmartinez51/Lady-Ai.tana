import 'package:flutter/material.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/settings/models/persona_record.dart';
import 'package:aitana/features/chat/services/llm/local_llm_service.dart';
import 'package:aitana/core/theme/app_colors.dart';

class PersonaVaultScreen extends StatefulWidget {
  const PersonaVaultScreen({super.key});

  @override
  State<PersonaVaultScreen> createState() => _PersonaVaultScreenState();
}

class _PersonaVaultScreenState extends State<PersonaVaultScreen> {
  List<PersonaRecord> _personas = [];

  @override
  void initState() {
    super.initState();
    _loadPersonas();
  }

  void _loadPersonas() {
    if (!mounted) return;
    setState(() {
      _personas = ObjectBoxService.instance.personaManager.getAllPersonas();
    });
  }

  Future<void> _handlePersonaTap(PersonaRecord persona) async {
    ObjectBoxService.instance.personaManager.setActivePersona(persona.id);
    LocalLlmService.currentLanguage = persona.defaultLang;

    // MoE Router: auto-load the correct model for this persona's category.
    await LocalLlmService.autoSwitchModelForCategory(persona.category);

    await LocalLlmService.resetSessionState();
    _loadPersonas();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${persona.name} set as active persona.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showEditDialog(PersonaRecord persona) {
    final isEn = LocalLlmService.currentLanguage == 'EN';
    final TextEditingController controller = TextEditingController(
      text: isEn ? persona.promptEn : persona.promptEs,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.glassBorder, width: 1),
          ),
          title: Text(
            'Edit ${persona.name}',
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'Outfit',
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: controller,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'Outfit',
                fontSize: 14,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white.withAlpha(15),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54, fontFamily: 'Outfit'),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.cyberBlue,
                foregroundColor: AppColors.obsidian,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                final isEn = LocalLlmService.currentLanguage == 'EN';
                ObjectBoxService.instance.personaManager.updatePersonaPrompt(
                  persona.id,
                  controller.text,
                  isEn: isEn,
                );
                Navigator.pop(ctx);
                _loadPersonas();
              },
              child: const Text(
                'Save',
                style: TextStyle(
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.obsidian,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Persona Vault',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Outfit',
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _personas.length,
        itemBuilder: (context, index) {
          final persona = _personas[index];
          final isActive = persona.isActive;

          return Card(
            color: const Color(0xFF1E1F20),
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isActive
                    ? AppColors.cyberBlue.withAlpha(150)
                    : AppColors.glassBorder,
                width: isActive ? 1.5 : 1.0,
              ),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Icon(
                isActive ? Icons.check_circle : Icons.circle_outlined,
                color: isActive ? Colors.greenAccent : Colors.white24,
                size: 28,
              ),
              title: Text(
                persona.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  LocalLlmService.currentLanguage == 'EN'
                      ? persona.promptEn
                      : persona.promptEs,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontFamily: 'Outfit',
                    fontSize: 13,
                  ),
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.edit, color: AppColors.cyberBlue),
                onPressed: () => _showEditDialog(persona),
              ),
              onTap: () => _handlePersonaTap(persona),
            ),
          );
        },
      ),
    );
  }
}
