import 'package:web/web.dart' as web;
import 'cookie_reader_interface.dart';

CookieReader createCookieReader() => WebCookieReader();

class WebCookieReader implements CookieReader {
  @override
  String getCookieString() => web.document.cookie;

  @override
  String getCurrentOrigin() => web.window.location.origin;

  @override
  void redirectTo(String url) {
    web.window.location.href = url;
  }

  @override
  void openNewTab(String url) {
    web.window.open(url, '_blank');
  }
}
