import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mini_vault/photos.dart';

void main() {
  img.Image resized(int width, int height, {int orientation = 1}) {
    final image = img.Image(width: width, height: height);
    image.exif.imageIfd.orientation = orientation;
    final out = img.decodeJpg(resizeForUpload(img.encodeJpg(image)))!;
    return out;
  }

  test('shrinks the long edge to 2048 px, keeping the aspect ratio', () {
    final landscape = resized(4000, 3000);
    expect((landscape.width, landscape.height), (2048, 1536));

    final portrait = resized(1000, 4000);
    expect((portrait.width, portrait.height), (512, 2048));
  });

  test('keeps a small photo at its size', () {
    final small = resized(800, 600);
    expect((small.width, small.height), (800, 600));
  });

  test('turns a photo upright from its EXIF orientation', () {
    // Orientation 6: stored landscape, shown rotated 90 degrees, so it is portrait.
    final rotated = resized(4000, 3000, orientation: 6);
    expect((rotated.width, rotated.height), (1536, 2048));
  });

  test('rejects bytes that are not an image', () {
    expect(
      () => resizeForUpload(
        img.encodeJpg(img.Image(width: 1, height: 1)).sublist(0, 4),
      ),
      throwsFormatException,
    );
  });
}
