import 'package:url_launcher/url_launcher.dart';
import 'cookie_reader_interface.dart';

typedef UrlLauncherHandler = Future<bool> Function(Uri uri);

CookieReader createCookieReader() => NativeCookieReader();

/// Native platform implementation using package:url_launcher to open external URLs and Hub SSO
class NativeCookieReader implements CookieReader {
  NativeCookieReader({UrlLauncherHandler? launcher})
      : _launcher = launcher ?? _defaultLauncher;

  final UrlLauncherHandler _launcher;

  static Future<bool> _defaultLauncher(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  String getCookieString() => '';

  @override
  String getCurrentOrigin() => 'https://dartup.sunshade.icu';

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
