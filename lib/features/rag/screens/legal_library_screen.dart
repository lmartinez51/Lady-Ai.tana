import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/rag/models/legal_document_record.dart';
import 'package:aitana/features/rag/services/streaming_document_chunker.dart';
import 'package:aitana/core/theme/app_colors.dart';
import 'package:aitana/core/ui/app_snackbars.dart';

class LegalLibraryScreen extends StatefulWidget {
  const LegalLibraryScreen({super.key});

  @override
  State<LegalLibraryScreen> createState() => _LegalLibraryScreenState();
}

class _LegalLibraryScreenState extends State<LegalLibraryScreen> {
  bool _isProcessing = false;

  Future<void> _pickAndProcessPdf() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;

        if (ObjectBoxService.instance.isDocumentExists(fileName)) {
          if (!mounted) return;
          AppSnackBars.showWarning(
            context,
            'Document "$fileName" is already in the library.',
          );
          return;
        }

        final metadata = await _showMetadataDialog(fileName);
        if (metadata == null) return;

        setState(() {
          _isProcessing = true;
        });

        // ── v1.1 Streaming Ingestion (Memory Patch) ──────────────────────────
        //
        // Legacy approach loaded the entire PDF into a single `rawText` String,
        // causing triple allocation peaks (bytes + parsed tree + mega-string).
        //
        // New approach:
        //   1. Load bytes once to open the PdfDocument (unavoidable).
        //   2. Iterate pages one at a time — only one page's text lives in the
        //      heap per iteration.
        //   3. Yield to the Dart event loop after every page via
        //      `Future.delayed(Duration.zero)` so the GC can reclaim the
        //      released page string before the next allocation.
        //   4. Call finalize() only after all pages are consumed.
        //
        final bytes = await File(filePath).readAsBytes();
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        final PdfTextExtractor extractor = PdfTextExtractor(document);
        final int pageCount = document.pages.count;

        if (pageCount == 0) {
          document.dispose();
          throw Exception('PDF has no pages.');
        }

        // Resolve the category weight from the stored enum name.
        final categoryEnum = LegalDocumentCategory.values.byName(
          metadata['category']!,
        );

        final chunker = StreamingDocumentChunker(
          documentName: fileName,
          category: categoryEnum.name,
          authorityWeight: categoryEnum.weight,
        );

        // Stream pages one at a time.
        for (int i = 0; i < pageCount; i++) {
          final pageText = extractor.extractText(
            startPageIndex: i,
            endPageIndex: i,
          );
          chunker.feedPage(pageText);
          // pageText is now unreferenced — yield so GC can reclaim it.
          await Future.delayed(Duration.zero);
        }

        // Dispose PdfDocument early to free the parsed-PDF memory.
        document.dispose();

        final chunks = chunker.finalize();

        if (chunks.isEmpty) {
          throw Exception('No extractable text found in PDF.');
        }

        final docRecord = LegalDocumentRecord(
          title: metadata['title']!,
          authorOrSource: metadata['source']!,
          uploadDate: DateTime.now(),
          chunkCount: chunks.length,
          fileName: fileName,
          category: categoryEnum.name,
        );

        ObjectBoxService.instance.saveLegalDocumentWithChunks(
          docRecord,
          chunks,
        );

        if (!mounted) return;
        AppSnackBars.showSuccess(
          context,
          'Ingested ${chunks.length} chunks from $fileName [${categoryEnum.displayName}]',
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppSnackBars.showError(context, 'Error processing PDF: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<Map<String, String>?> _showMetadataDialog(String fileName) async {
    final titleController = TextEditingController(
      text: fileName.replaceAll('.pdf', ''),
    );
    final sourceController = TextEditingController();
    LegalDocumentCategory selectedCategory = LegalDocumentCategory.doctrina;

    return showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1F20),
              title: const Text(
                'Document Details',
                style: TextStyle(color: Colors.white, fontFamily: 'Outfit'),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.glassBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.cyberBlue),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: sourceController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Author / Source (e.g., SCJN)',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.glassBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.cyberBlue),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── PRO Authority Category Selector ─────────────────────────
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Authority Category',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontFamily: 'Outfit',
                        ),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          // ¡Aquí está el popup flotante 100% personalizado!
                          final LegalDocumentCategory?
                          picked = await showDialog<LegalDocumentCategory>(
                            context: context,
                            builder: (BuildContext context) {
                              return Dialog(
                                backgroundColor: const Color(
                                  0xFF18191A,
                                ), // Fondo bien oscuro para resaltar
                                elevation: 24,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  // AQUÍ ESTÁ EL CONTORNO DE LAS 3 OPCIONES:
                                  side: const BorderSide(
                                    color: AppColors.cyberBlue,
                                    width: 2.0,
                                  ),
                                ),
                                child: Container(
                                  width: 200,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12.0,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: LegalDocumentCategory.values.map((
                                      cat,
                                    ) {
                                      final isSelected =
                                          cat == selectedCategory;
                                      return ListTile(
                                        title: Text(
                                          cat.displayName,
                                          style: TextStyle(
                                            color: isSelected
                                                ? AppColors.cyberBlue
                                                : Colors.white,
                                            fontFamily: 'Outfit',
                                            fontWeight: isSelected
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                        ),
                                        subtitle: Text(
                                          'Multiplier: ×${cat.weight}',
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontFamily: 'Outfit',
                                            fontSize: 12,
                                          ),
                                        ),
                                        trailing: isSelected
                                            ? const Icon(
                                                Icons.check_circle,
                                                color: AppColors.cyberBlue,
                                              )
                                            : null,
                                        onTap: () =>
                                            Navigator.pop(context, cat),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              );
                            },
                          );

                          if (picked != null) {
                            setDialogState(() => selectedCategory = picked);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: 0.03,
                            ), // Fondo translúcido (Fixed deprecation)
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.glassBorder),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    selectedCategory.displayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'Outfit',
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Multiplier: ×${selectedCategory.weight}',
                                    style: const TextStyle(
                                      color: AppColors.cyberBlue,
                                      fontFamily: 'Outfit',
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const Icon(
                                Icons.keyboard_arrow_down,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.cyberBlue,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    if (titleController.text.isNotEmpty &&
                        sourceController.text.isNotEmpty) {
                      Navigator.pop(context, {
                        'title': titleController.text,
                        'source': sourceController.text,
                        'category': selectedCategory.name,
                      });
                    }
                  },
                  child: const Text('Ingest'),
                ),
              ],
            );
          },
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
          'Legal Library',
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Outfit',
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          if (_isProcessing)
            const LinearProgressIndicator(
              color: AppColors.cyberBlue,
              backgroundColor: Colors.transparent,
            ),
          Expanded(
            child: StreamBuilder<List<LegalDocumentRecord>>(
              stream: ObjectBoxService.instance.watchLegalDocuments(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.cyberBlue,
                    ),
                  );
                }

                final docs = snapshot.data ?? [];

                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No legal documents found.\nAdd a PDF to start building your knowledge base.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontFamily: 'Outfit',
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    return Card(
                      color: const Color(0xFF1E1F20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: AppColors.glassBorder),
                      ),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text(
                          doc.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'Outfit',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          '${doc.authorOrSource}\nCategory: ${LegalDocumentCategory.values.byName(doc.category).displayName}\n${doc.uploadDate.toLocal().toString().split(' ')[0]} • ${doc.chunkCount} chunks',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontFamily: 'Outfit',
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          onPressed: () {
                            ObjectBoxService.instance.deleteLegalDocument(
                              doc.id,
                            );
                            AppSnackBars.showSuccess(
                              context,
                              'Document deleted.',
                            );
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isProcessing ? null : _pickAndProcessPdf,
        backgroundColor: _isProcessing ? Colors.grey : AppColors.cyberBlue,
        icon: Icon(
          Icons.add_task,
          color: _isProcessing ? Colors.white54 : AppColors.obsidian,
        ),
        label: Text(
          'Add Document',
          style: TextStyle(
            color: _isProcessing ? Colors.white54 : AppColors.obsidian,
            fontFamily: 'Outfit',
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
