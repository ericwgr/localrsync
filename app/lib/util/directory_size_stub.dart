/// Web (and other IO-less) fallback: the local file system is not reachable,
/// so a directory size cannot be computed.
Future<int> calculateDirectorySize(String path) async {
  throw UnsupportedError('Calculating the directory size is not supported on this platform');
}
