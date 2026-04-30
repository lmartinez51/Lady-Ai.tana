import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:aitana/features/auth/providers/auth_provider.dart';
import 'package:aitana/core/theme/app_colors.dart';

class LockScreen extends StatelessWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(gradient: AppColors.premiumGradient),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Branding
            const Icon(Icons.fingerprint, size: 80, color: AppColors.cyberBlue),
            const SizedBox(height: 20),
            Text("aitana", style: Theme.of(context).textTheme.displayLarge),
            Text(
              "SECURE OFFLINE AI",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                letterSpacing: 4,
                color: AppColors.cyberBlue,
              ),
            ),
            const SizedBox(height: 60),

            // Status Indicator
            _buildStatusWidget(context, authProvider),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusWidget(BuildContext context, AuthProvider auth) {
    switch (auth.status) {
      case AuthStatus.initial:
      case AuthStatus.authenticating:
        return const Column(
          children: [
            CircularProgressIndicator(color: AppColors.cyberBlue),
            SizedBox(height: 20),
            Text("Authenticating..."),
          ],
        );

      case AuthStatus.noBiometrics:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.error,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                auth.errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                "Access is restricted until security is configured.",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMedium),
              ),
            ],
          ),
        );

      case AuthStatus.unauthenticated:
        return Column(
          children: [
            if (auth.errorMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  auth.errorMessage,
                  style: const TextStyle(color: AppColors.error),
                ),
              ),
            ElevatedButton.icon(
              onPressed: () => auth.authenticate(),
              icon: const Icon(Icons.lock_open),
              label: const Text("Unlock Aitana"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
            ),
          ],
        );

      case AuthStatus.authenticated:
        return const Icon(Icons.check_circle, color: Colors.green, size: 48);
    }
  }
}
