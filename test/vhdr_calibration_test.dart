import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/vhdr_loader.dart';

void main() {
  for (final orientation in ['MULTIPLEXED', 'VECTORIZED']) {
    for (final format in ['IEEE_FLOAT_32', 'INT_16', 'INT_32']) {
      test(
        'BrainVision $format $orientation applies resolution and units once',
        () {
          final dir = Directory.systemTemp.createTempSync(
            'ccs-vhdr-calibration',
          );
          addTearDown(() => dir.deleteSync(recursive: true));
          File('${dir.path}/x.vhdr').writeAsStringSync(
            '''BrainVision Data Exchange Header File Version 1.0
[Common Infos]
DataFile=x.eeg
DataFormat=BINARY
DataOrientation=$orientation
NumberOfChannels=2
SamplingInterval=1000
[Binary Infos]
BinaryFormat=$format
[Channel Infos]
Ch1=Fz,,0.0488281,µV
Ch2=Pz,,0.001,mV
''',
          );
          final samples = orientation == 'MULTIPLEXED'
              ? [100, -2, 200, 3]
              : [100, 200, -2, 3];
          final width = format == 'INT_16' ? 2 : 4;
          final data = ByteData(samples.length * width);
          for (var i = 0; i < samples.length; i++) {
            if (format == 'IEEE_FLOAT_32') {
              data.setFloat32(i * width, samples[i].toDouble(), Endian.little);
            } else if (format == 'INT_16') {
              data.setInt16(i * width, samples[i], Endian.little);
            } else {
              data.setInt32(i * width, samples[i], Endian.little);
            }
          }
          File('${dir.path}/x.eeg').writeAsBytesSync(data.buffer.asUint8List());
          final rec = VhdrLoader().load('${dir.path}/x.vhdr');
          expect(rec.preview[0][0], closeTo(4.88281, 1e-6));
          expect(rec.preview[0][1], closeTo(9.76562, 1e-6));
          expect(rec.preview[1], [-2, 3]);
        },
      );
    }
  }
}
