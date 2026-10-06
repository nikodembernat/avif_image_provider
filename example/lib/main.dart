import 'package:avif_image_provider/avif_image_provider.dart';
import 'package:flutter/material.dart';

void main() => runApp(const AvifExampleApp());

/// An animated AVIF image hosted on the web, from the libavif test data.
const networkImageUrl =
    'https://raw.githubusercontent.com/AOMediaCodec/libavif/main/tests/data/'
    'colors-animated-8bpc.avif';

class const AvifExampleApp({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AVIF image provider',
    theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
    home: const AvifGallery(),
  );
}

class const AvifGallery({super.key}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AVIF image provider')),
    body: GridView.extent(
      maxCrossAxisExtent: 320,
      padding: const EdgeInsets.all(16),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      children: const [
        _Example(
          title: 'Still image',
          image: AssetAvifImage('assets/plasma.avif'),
        ),
        _Example(
          title: 'Animated image',
          image: AssetAvifImage('assets/plasma_animated.avif'),
        ),
        _Example(
          title: 'Transparency',
          image: AssetAvifImage('assets/alpha.avif'),
          checkerboard: true,
        ),
        _Example(
          title: 'Decoded at 64 px (cacheWidth)',
          image: AssetAvifImage('assets/plasma.avif'),
          cacheWidth: 64,
        ),
        _Example(
          title: 'Network image',
          image: NetworkAvifImage(networkImageUrl),
        ),
      ],
    ),
  );
}

class const _Example({
  required final String title,
  required final ImageProvider image,
  final bool checkerboard = false,
  final int? cacheWidth,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: checkerboard
                  ? const LinearGradient(
                      colors: [Colors.black12, Colors.white],
                      stops: [0.5, 0.5],
                      tileMode: TileMode.repeated,
                      end: Alignment(-0.9, -0.9),
                    )
                  : null,
            ),
            child: Image(
              image: cacheWidth == null
                  ? image
                  : ResizeImage(image, width: cacheWidth),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  Center(child: Text('$error', textAlign: TextAlign.center)),
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                  frame == null && !wasSynchronouslyLoaded
                  ? const Center(child: CircularProgressIndicator())
                  : child,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      ],
    ),
  );
}
