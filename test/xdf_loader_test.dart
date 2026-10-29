import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/xdf_loader.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';

List<int> integer(int n, int width) {
  final data = ByteData(width);
  if (width == 2) {
    data.setUint16(0, n, Endian.little);
  } else {
    data.setUint32(0, n, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int> real(double n, {bool single = false}) {
  final data = ByteData(single ? 4 : 8);
  if (single) {
    data.setFloat32(0, n, Endian.little);
  } else {
    data.setFloat64(0, n, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int> chunk(int tag, List<int> bytes) => [
  4,
  ...integer(bytes.length + 2, 4),
  ...integer(tag, 2),
  ...bytes,
];
List<int> header(
  int id,
  String format,
  double rate, {
  String name = 'EEG',
  String unit = 'V',
  int channels = 1,
}) => chunk(2, [
  ...integer(id, 4),
  ...utf8.encode(
    '<info><name>$name</name><type>$name</type><channel_count>$channels</channel_count><nominal_srate>$rate</nominal_srate><channel_format>$format</channel_format><desc><channels><channel><label>Fz</label><unit>$unit</unit></channel></channels></desc></info>',
  ),
]);
List<int> fixture({
  String format = 'float32',
  bool gap = false,
  bool extra = false,
}) => [
  ...ascii.encode('XDF:'),
  ...chunk(1, utf8.encode('<info><version>1</version></info>')),
  ...header(1, format, 100),
  ...header(2, 'string', 0, name: 'Markers'),
  if (extra) ...header(3, 'float32', 100, name: 'Other EEG'),
  ...chunk(4, [...integer(1, 4), ...real(10), ...real(1)]),
  ...chunk(4, [...integer(2, 4), ...real(20), ...real(-9)]),
  ...chunk(3, [
    ...integer(1, 4),
    1,
    3,
    8,
    ...real(10),
    ...real(1e-6, single: format == 'float32'),
    0,
    ...real(2e-6, single: format == 'float32'),
    8,
    ...real(gap ? 11 : 10.02),
    ...real(3e-6, single: format == 'float32'),
  ]),
  ...chunk(3, [
    ...integer(2, 4),
    1,
    1,
    8,
    ...real(20.01),
    1,
    4,
    ...utf8.encode('S 10'),
  ]),
];
void main() async {
  late Directory temp;
  late File file;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('xdf_test_');
    file = File('${temp.path}/test.xdf');
  });
  tearDown(() => temp.deleteSync(recursive: true));
  for (final format in ['float32', 'double64']) {
    test(
      '$format samples, implicit timestamps, units and cross-stream clock offsets',
      () async {
        file.writeAsBytesSync(fixture(format: format));
        final rec = await XdfLoader().load(file.path);
        expect(rec.sampleRate, closeTo(100, 1e-8));
        expect(rec.labels, ['Fz']);
        expect(rec.preview.single, orderedEquals([1, 2, 3]));
        expect(rec.markers.single.label, 'S 10');
        expect(rec.markers.single.startSeconds, closeTo(.01, 1e-8));
      },
    );
  }
  test(
    'stream inventory does not decode samples; selected stream preserved',
    () async {
      file.writeAsBytesSync(fixture(extra: true));
      expect((await XdfLoader().inspect(file.path)).map((s) => s.id), [1, 3]);
      expect(
        (await XdfLoader().load(
          file.path,
          streamId: 1,
        )).provenance['xdf_stream_id'],
        1,
      );
    },
  );
  test(
    'reject gaps and truncated files rather than shifting markers',
    () async {
      file.writeAsBytesSync(fixture(gap: true));
      await expectLater(XdfLoader().load(file.path), throwsFormatException);
      file.writeAsBytesSync(fixture().sublist(0, fixture().length - 1));
      await expectLater(XdfLoader().load(file.path), throwsFormatException);
    },
  );
  test('worker loader returns XDF signals and reports phases', () async {
    file.writeAsBytesSync(fixture());
    final progress = <String>[];
    final rec = await RecordingLoader().load(
      file.path,
      onProgress: (p, m) => progress.add(m),
    );
    expect(rec.format, 'xdf');
    expect(progress.any((m) => m.contains('XDF')), true);
    expect(rec.markers.single.label, 'S 10');
  });
  test('loading can be cancelled while worker is decoding', () async {
    file.writeAsBytesSync(fixture());
    final loader = RecordingLoader();
    final future = loader.load(
      file.path,
      onProgress: (p, m) => loader.cancelPendingLoads(),
    );
    await expectLater(future, throwsStateError);
    expect((await loader.load(file.path)).sampleCount, 3);
  });
  test('immediate cancellation before isolate startup is safe', () async {
    file.writeAsBytesSync(fixture());
    final loader = RecordingLoader();
    final future = loader.load(file.path);
    loader.cancelPendingLoads();
    await expectLater(future, throwsStateError);
  });
  for (final format in ['int8', 'int16', 'int32', 'int64']) {
    test('$format numeric EEG values are decoded as signed samples', () async {
      final width = {'int8': 1, 'int16': 2, 'int32': 4, 'int64': 8}[format]!;
      List<int> sample(int value) {
        final data = ByteData(width);
        if (width == 1) {
          data.setInt8(0, value);
        }
        if (width == 2) {
          data.setInt16(0, value, Endian.little);
        }
        if (width == 4) {
          data.setInt32(0, value, Endian.little);
        }
        if (width == 8) {
          data.setInt64(0, value, Endian.little);
        }
        return data.buffer.asUint8List();
      }

      file.writeAsBytesSync([
        ...ascii.encode('XDF:'),
        ...header(1, format, 100, unit: 'uV'),
        ...chunk(3, [
          ...integer(1, 4),
          1,
          3,
          8,
          ...real(10),
          ...sample(-1),
          0,
          ...sample(2),
          0,
          ...sample(3),
        ]),
      ]);
      expect((await XdfLoader().load(file.path)).preview.single, [-1, 2, 3]);
    });
  }
}
