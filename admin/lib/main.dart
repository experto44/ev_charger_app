import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/admin_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.web);
  runApp(const AdminApp());
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GeoCharge Admin',
        debugShowCheckedModeBanner: false,
        theme: buildAdminTheme(),
        home: const _AuthGate(),
      );
}

/// Routes between the login screen and the dashboard based on auth + admin
/// status. Non-admin signed-in accounts are shown an access-denied screen so a
/// regular app user who logs in can't peek at the panel shell.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AdminService.I.authState,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        if (snap.data == null) {
          return const LoginScreen();
        }
        // Signed in — verify admin membership before revealing the dashboard.
        return FutureBuilder<bool>(
          future: AdminService.I.isCurrentUserAdmin(),
          builder: (context, adminSnap) {
            if (adminSnap.connectionState == ConnectionState.waiting) {
              return const _Splash();
            }
            if (adminSnap.data == true) {
              return const DashboardScreen();
            }
            return const _AccessDenied();
          },
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class _AccessDenied extends StatelessWidget {
  const _AccessDenied();
  @override
  Widget build(BuildContext context) {
    final email = AdminService.I.currentUser?.email ?? '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 56, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text('Access denied',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '$email is not an admin of this panel.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              FilledButton.tonal(
                onPressed: () => AdminService.I.signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
