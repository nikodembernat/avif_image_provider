/// Thrown when an AVIF image cannot be decoded.
class const AvifDecodeException(
  /// A human-readable description of the error.
  final String message, {

  /// The native result code, if the error originated in the native decoder.
  ///
  /// Positive values are libavif `avifResult` codes.
  final int? code,
}) implements Exception {
  /// Creates an [AvifDecodeException].
  this;

  @override
  String toString() => code == null
      ? 'AvifDecodeException: $message'
      : 'AvifDecodeException: $message (code $code)';
}
