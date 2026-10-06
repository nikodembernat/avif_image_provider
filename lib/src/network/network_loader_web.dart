import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Downloads [url] with `fetch`, which requires CORS for other origins.
Future<Uint8List> loadNetworkBytes(
  String url,
  Map<String, String>? headers,
  StreamController<ImageChunkEvent> chunkEvents,
) async {
  final uri = Uri.base.resolve(url);
  final requestHeaders = JSObject();
  headers?.forEach((name, value) {
    requestHeaders.setProperty(name.toJS, value.toJS);
  });
  final response = await _fetch(
    uri.toString().toJS,
    _RequestInit(headers: requestHeaders),
  ).toDart;
  if (!response.ok) {
    throw NetworkImageLoadException(statusCode: response.status, uri: uri);
  }
  final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
  if (bytes.isEmpty) {
    throw StateError('NetworkAvifImage is an empty file: $uri');
  }
  chunkEvents.add(
    ImageChunkEvent(
      cumulativeBytesLoaded: bytes.length,
      expectedTotalBytes: bytes.length,
    ),
  );
  return bytes;
}

extension type _RequestInit._(JSObject _) implements JSObject {
  external factory({JSObject headers});
}

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, _RequestInit init);
