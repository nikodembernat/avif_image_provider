import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

final HttpClient _sharedHttpClient = HttpClient()..autoUncompress = false;

HttpClient get _httpClient {
  HttpClient? client;
  assert(() {
    client = debugNetworkImageHttpClientProvider?.call();
    return true;
  }(), 'Uses debugNetworkImageHttpClientProvider in debug mode');
  return client ?? _sharedHttpClient;
}

/// Downloads [url], reporting progress to [chunkEvents].
Future<Uint8List> loadNetworkBytes(
  String url,
  Map<String, String>? headers,
  StreamController<ImageChunkEvent> chunkEvents,
) async {
  final uri = Uri.base.resolve(url);
  final request = await _httpClient.getUrl(uri);
  headers?.forEach(request.headers.add);
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<List<int>>(<int>[]);
    throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
  }
  final bytes = await consolidateHttpClientResponseBytes(
    response,
    onBytesReceived: (cumulative, total) {
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: cumulative,
          expectedTotalBytes: total,
        ),
      );
    },
  );
  if (bytes.isEmpty) {
    throw StateError('NetworkAvifImage is an empty file: $uri');
  }
  return bytes;
}
