import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
void main() {
  test('Pallavi Post BrainVision amplitude matches independent MNE read', () async {
    const path='/Users/arunsasidharan/EEGdata/Pallavi/Pallavi_Task_Post_4.vhdr';
    if(!File(path).existsSync()) return;
    final rec=await RecordingLoader().load(path);
    // MNE read_raw_brainvision().get_data(start=10000,stop=10001)[0,0]*1e6.
    expect(rec.preview[0][10000],closeTo(14071.8189671,.001));
    expect(rec.sampleRate,1000);
  },timeout:const Timeout(Duration(minutes:2)));
}
