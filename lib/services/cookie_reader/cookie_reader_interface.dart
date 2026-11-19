abstract class CookieReader {
  String getCookieString();
  String getCurrentOrigin();
  void redirectTo(String url);
  void openNewTab(String url);
}
