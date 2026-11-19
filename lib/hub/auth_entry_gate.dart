import 'package:flutter/material.dart';
import 'package:sd_client/services/sso_auth_service.dart';

/// Entry Gate displayed when unauthenticated, providing SSO login,
/// guest play, and ecosystem legal links.
class AuthEntryGate extends StatefulWidget {
  const AuthEntryGate({
    super.key,
    required this.child,
    this.authService,
  });

  final Widget child;
  final SsoAuthService? authService;

  @override
  State<AuthEntryGate> createState() => _AuthEntryGateState();
}

class _AuthEntryGateState extends State<AuthEntryGate> {
  late final SsoAuthService _authService;
  bool _isLoading = true;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? SsoAuthService();
    _checkAuthentication();
  }

  Future<void> _checkAuthentication() async {
    // 1. Check if already authenticated via URL or state
    if (_authService.isAuthenticated) {
      if (mounted) {
        setState(() {
          _isAuthenticated = true;
          _isLoading = false;
        });
      }
      return;
    }

    // 2. Attempt automatic .sunshade.icu cookie hydration
    final hydrated = await _authService.hydrateFromCookie();
    if (mounted) {
      setState(() {
        _isAuthenticated = hydrated && _authService.isAuthenticated;
        _isLoading = false;
      });
    }
  }

  Future<void> _handlePlayAsGuest() async {
    setState(() => _isLoading = true);
    await _authService.signInAsGuest();
    if (mounted) {
      setState(() {
        _isAuthenticated = true;
        _isLoading = false;
      });
    }
  }

  void _handleLoginViaHub() {
    _authService.loginViaHub();
  }

  void _openEula() {
    _authService.openExternalLink('https://sunshade.icu/eula');
  }

  void _openPrivacy() {
    _authService.openExternalLink('https://sunshade.icu/privacy');
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0C0A09),
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF97316)),
          ),
        ),
      );
    }

    if (_isAuthenticated) {
      return widget.child;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0C0A09),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [
              Color(0xFF1C1917),
              Color(0xFF0C0A09),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // App Icon / Logo
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFF97316), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFF97316).withValues(alpha: 0.3),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 48,
                      color: Color(0xFFF97316),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Title
                  const Text(
                    'DART UP!',
                    style: TextStyle(
                      fontFamily: 'sans-serif',
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 4.0,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Subtitle
                  const Text(
                    'Real-Time Space Gladiator Combat & Drone Swarms',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.5,
                      color: Color(0xFFA1A1AA),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Primary Action: Login via SunShade Hub
                  SizedBox(
                    width: 280,
                    height: 52,
                    child: ElevatedButton.icon(
                      key: const Key('login_via_hub_button'),
                      onPressed: _handleLoginViaHub,
                      icon: const Icon(Icons.login, color: Colors.white, size: 20),
                      label: const Text(
                        'Login via SunShade Hub',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316),
                        elevation: 4,
                        shadowColor: const Color(0xFFF97316).withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Secondary Action: Play as Guest
                  SizedBox(
                    width: 280,
                    height: 48,
                    child: OutlinedButton.icon(
                      key: const Key('play_as_guest_button'),
                      onPressed: _handlePlayAsGuest,
                      icon: const Icon(Icons.play_arrow_outlined, color: Color(0xFFE4E4E7), size: 20),
                      label: const Text(
                        'Play as Guest',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE4E4E7),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF3F3F46), width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Legal Links Footer
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        key: const Key('eula_link'),
                        onPressed: _openEula,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'EULA',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF71717A),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      const Text(
                        ' • ',
                        style: TextStyle(fontSize: 12, color: Color(0xFF52525B)),
                      ),
                      TextButton(
                        key: const Key('privacy_link'),
                        onPressed: _openPrivacy,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Privacy Policy',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF71717A),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
