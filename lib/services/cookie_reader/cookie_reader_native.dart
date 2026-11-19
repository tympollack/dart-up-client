import 'package:url_launcher/url_launcher.dart';
import 'cookie_reader_interface.dart';

typedef UrlLauncherHandler = Future<bool> Function(Uri uri);

CookieReader createCookieReader() => NativeCookieReader();

/// Native platform implementation using package:url_launcher to open external URLs and Hub SSO
class NativeCookieReader implements CookieReader {
  NativeCookieReader({
    UrlLauncherHandler? launcher,
    String? callbackUri,
  })  : _launcher = launcher ?? _defaultLauncher,
        _callbackUri = callbackUri ?? defaultNativeCallbackUri;

  static const String defaultNativeCallbackUri = 'io.sunshade.dartup://login-callback';

  final UrlLauncherHandler _launcher;
  final String _callbackUri;

  static Future<bool> _defaultLauncher(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  String getCookieString() => '';

  @override
  String getCurrentOrigin() => _callbackUri;

  @override
  void redirectTo(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      _launcher(uri);
    }
  }

  @override
  void openNewTab(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      _launcher(uri);
    }
  }
}
