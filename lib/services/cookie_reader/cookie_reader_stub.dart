import 'cookie_reader_interface.dart';

/// Test double implementing CookieReader for unit and widget testing
class StubCookieReader implements CookieReader {
  String stubCookie = '';
  String stubOrigin = 'https://dartup-stag.sunshade.icu';
  String? lastRedirectUrl;
  String? lastOpenedUrl;

  @override
  String getCookieString() => stubCookie;

  @override
  String getCurrentOrigin() => stubOrigin;

  @override
  void redirectTo(String url) {
    lastRedirectUrl = url;
  }

  @override
  void openNewTab(String url) {
    lastOpenedUrl = url;
  }
}
