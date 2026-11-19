import 'cookie_reader_interface.dart';
import 'cookie_reader_native.dart'
    if (dart.library.js_interop) 'cookie_reader_web.dart';

export 'cookie_reader_interface.dart';
export 'cookie_reader_stub.dart';
export 'cookie_reader_native.dart';

CookieReader getPlatformCookieReader() => createCookieReader();
