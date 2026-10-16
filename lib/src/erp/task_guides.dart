const erpTaskGuides = <String, String>{
  'MMN':
      'Auditory mismatch · stimulus-locked. Compare standard vs deviant tones (ERP CORE 80 vs 70). Start with FCz, 125–225 ms, negative peak.',
  'N170':
      'Face processing · stimulus-locked. Compare cars vs faces (ERP CORE 41–80 vs 1–40). Start with PO7/PO8 mean, 110–170 ms, negative peak.',
  'N2pc':
      'Visual attention · stimulus-locked. Choose left-target vs right-target trial groups. PO7 is the left ROI and PO8 the right; the engine derives contralateral minus ipsilateral, 200–275 ms.',
  'N400':
      'Semantic processing · stimulus-locked to the target word. Compare related/congruent vs unrelated/incongruent targets. Start with Cz, 300–500 ms, negative peak.',
  'P3':
      'Target detection · stimulus-locked. Compare non-target vs target trials. Start with Pz, 300–600 ms, positive peak.',
  'ERN':
      'Error processing · RESPONSE-locked, not stimulus-locked. Compare correct vs error responses. Start with FCz, 0–100 ms, negative peak. If the saved trials were locked to stimuli, return to Preprocess and epoch on response codes.',
  'LRP':
      'Motor preparation · RESPONSE-locked. Choose correct left-hand vs correct right-hand response groups. C3 is the left ROI and C4 the right; the engine derives contralateral minus ipsilateral, −100–0 ms.',
  'Custom':
      'Choose two saved condition groups, the measurement ROI and time window. Existing trial boundaries are preserved. Review the experiment’s stimulus/response locking before interpreting results.',
};
