import 'package:localsend_app/util/directory_size_stub.dart' if (dart.library.io) 'package:localsend_app/util/directory_size_io.dart' as impl;

/// Calculates the total size in bytes of all files inside [path], recursively.
///
/// Runs the directory walk off the UI isolate on native platforms so that
/// large folders do not block the app. On web (where the local file system
/// is not reachable) this throws [UnsupportedError].
Future<int> calculateDirectorySize(String path) {
  return impl.calculateDirectorySize(path);
}
