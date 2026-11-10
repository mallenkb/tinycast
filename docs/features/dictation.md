# Dictation (experimental)

Dictation is off by default. Either assigned global shortcut records from the chosen microphone,
transcribes locally and sends the result through `TextInjector`. Parakeet V3, Ultra and Redux
support 25 languages. Parakeet V2 and Phonon-2 support English. Phonon-2 is a smaller model
retrained from V3 for English. Qwen3-ASR 0.6B and 1.7B support 30 languages and 22 Chinese dialects.
Settings lists Parakeet V3 first, marks it Recommended and selects it by default. Choose Download
to install the selected Parakeet or Qwen model. Apple Dictation uses speech assets managed by macOS.

Parakeet and Qwen use Core ML and Accelerate. Each family has its own adapter inside the bundled
helper, and variants share their family's implementation.
Parakeet variants declare their encoder, joint model, blank token and compute units in
`DictationModel` alongside the pinned download metadata. V3 uses FluidInference's re-quantized
`Encoder_v2` and V2 uses `JointDecision` with blank token 1024. Phonon-2 selects the encoder's
`enc_15000ms` function to match the preprocessor's 15-second window.
Redux's encoder uses CPU/GPU to avoid the several-minute initial Neural Engine
compilation of its 2-bit weights. The other Parakeet encoders and all Parakeet decoders and joint
models use CPU/Neural Engine.

## Invariants

- `AppCore` owns the history, model store and coordinator. The microphone session, panel and focused target
  belong only to `DictationCoordinator`; no recording starts merely by launching Tinycast or opening
  Settings.
- The enable switch is consent. It explains microphone and Accessibility access before enabling,
  and, like every Dictation preference, is excluded from backups so importing settings cannot arm
  a global recording shortcut.
- Auto-learn words defaults to on when Dictation is enabled. An explicit Off choice is preserved
  when Dictation is turned off and on again. After a confirmed paste into a readable text field, Tinycast
  can watch the inserted text for up to 12 seconds. It learns a single similar word replacement
  after the edit settles and stops watching when focus leaves the field or the surrounding text
  changes. Add a word or phrase under Dictation Settings > Dictionary to keep its preferred spelling.
  Enter a misspelling to replace the text Tinycast repeatedly hears. The dictionary stores up to 100
  entries on this Mac and keeps manual entries when learned ones are dropped. All engines apply
  dictionary entries to finished text. Apple Dictation also uses saved words as recognition hints.
  Entries apply with learning off. Remove an entry in Dictation Settings to stop using it.
- Microphone status appears in Permissions and the Dictation pane. Neither pane prompts on display;
  only a user action requests access, while revoked access is refreshed from macOS.
- Hold to talk and Hands-free have separate global shortcuts and can both be assigned.
  Both use the shared recorder and conflict handling. Hold to talk accepts a Carbon chord or a
  single physical modifier, including Fn/Globe. Hands-free starts and stops on successive
  activations and accepts double taps.
  Modifier holds begin after 250 ms alone and reserve their key across single and double taps.
  Another modifier, key or click cancels the hold without inserting text.
- Carbon or the shared modifier monitor reports release to stop a held recording. A hold release
  or cancellation does not stop a recording started by the toggle shortcut or a composer mic.
  Return finishes and Escape cancels. Opening a shortcut recorder cancels a held recording before
  pausing its shortcuts. A session token prevents stale transcription from inserting text later.
- AI Chat's composer mic is always click-to-toggle into that field: `toggle(into:)` targets its
  `ComposerTextView` in process whatever has focus. `field` tells only that button it is running.
  Switching chats or closing the composer cancels only the session targeting that editor, including
  one started by a shortcut. The session token is checked again when queued insertion runs.
- The nonactivating panel preserves the target app. It sits above app windows and can join other
  apps across Spaces, full-screen windows and Stage Manager. Text insertion reuses `TextInjector`, including
  its temporary clipboard ownership, focus, secure-input and protected-target checks. Dictation History
  keeps completed transcripts on this Mac, including transcripts that could not be pasted.
  History keeps transcripts for three months by default. Choose how long to keep them in Dictation
  Settings. Shortening the retention period removes transcripts older than the new cutoff.
  Dictation History uses the clipboard list's date groups and copy and paste shortcuts. Its rows
  show an outline microphone at the standard menu symbol size. The history also offers full
  transcript previews and local search.
  The Information section shows the date and word count.
  New entries also show the original app when the transcript was pasted successfully.
  Dictation History and Dictation Settings are available even when recording is disabled.
- The compact dictation indicators use seven bars in a light or dark capsule. The other styles use
  a capsule or rounded rectangle in light, dark, or outlined finishes and include a status label.
  The pill appears when the shortcut or composer mic starts a recording and shows Starting…
  until microphone setup completes off the main thread.
  Each indicator fits the current state. Settings previews both listening and processing for the
  selected style.
  The waveform blends neighboring
  frequency peaks so the bars rise together. Capture samples 21 bands at most 20 times per
  second through a reused 512-point Accelerate transform. The logarithmic bands span 32–5000 Hz.
  The bars grow around a fixed centerline and ease between readings when Reduce Motion is off.
  A spinning ring replaces the bars during transcription. Labeled styles cycle through a shuffled
  list of processing words every two seconds.
  The ring and the text shimmer pause when Reduce Motion is on.
  Closing the panel releases its hosting view.
- Recording leaves the system output volume alone.
- Play sounds is on by default. When on, macOS's `dt-begin.caf` plays on the microphone's first samples
  and `dt-confirm.caf` when recording stops (release, toggle, Return or the length limit); cancelling
  stays silent. These are internal resources in `AssistantServices.framework`, not bundled audio;
  their location is undocumented, and a missing sound is silently skipped without blocking dictation.
  A Bluetooth headset drops output while it switches to its microphone, sometimes after the first
  samples arrive, so with a Bluetooth microphone the start cue waits half a second more. The stop cue
  plays before the microphone closes and a headset switches back. Media can mask the cues, and
  speaker playback can reach the microphone.
- The microphone, waveform, permissions and insertion stay in Tinycast. For Parakeet and Qwen,
  model loading, audio features and decoding run in `Tinycast Dictation` (`Tinycast Dev Dictation` in Debug). The helper
  starts loading the selected model alongside microphone setup. If the user stops before it is ready,
  the transcription waits for the same load before sending the buffered audio. A failed preload
  leaves the audio available for a regular transcription request. Phonon-2 has up to three minutes
  to load because its first Neural Engine compilation can take longer than a minute. Once it is ready,
  transcription uses the normal timeout. Main-app state never retains Core ML models.
  The helper is an embedded accessory app with no bundled icon, Dock item or windows.
- The Apple Dictation engine uses Apple's on-device `DictationTranscriber` and the Mac's preferred
  language. Tinycast starts preparation when recording begins. macOS installs missing speech assets,
  then manages those assets and their memory. The analyzer lives for one recording.
- Core ML models live under this build's bundle-ID cache. The idle timer starts after the recording
  and transcription finish. After one minute idle by default, the
  store terminates and reaps the helper, releasing its model memory. Other delays or Never are
  selectable. Switching models reaps the old helper before loading the next; removing a loaded model
  stops its helper before deleting the directory and blocks new requests for that model meanwhile.
  Cancelling an in-flight load or transcription, failed inference and normal quit stop the helper.
  Late results cannot paste.
- Audio stays in memory, bounded to five minutes of mono 16 kHz Float32 samples. Pipes carry
  bounded JSON control messages and binary audio; recordings are never written to disk or sent
  over the network. Long recordings split near a quiet passage without overlapping samples.
- Tinycast transcribes the complete recording after the user stops, then inserts the finished
  text in the target app.
- Model files download through a feature-private ephemeral session without a disk URL cache.
  Repositories and revisions are explicit in `DictationModel`; each download is staged and
  published only when all required files arrive, their sizes agree with the manifest and large-file
  SHA-256 checksums match. Settings shows combined byte counts and a percentage in a full-width
  progress row for the selected model. Download delegate callbacks report actual transferred bytes,
  with intermediate updates limited to one per 100 ms per file; each verified file reports its final
  count immediately. Progress observation stays in the download row. Switching
  selection leaves its download running in the background. Cancellation and
  normal quit remove staging files without publishing a partial model. A new download removes stale
  staging directories left by a crash or forced quit, without touching installed models or other files.
  A nonblocking file lock covers cleanup through publication, rejecting another download sharing
  the same cache root. Its empty lock file stays in place; macOS releases the lock on process exit.
- An installed Qwen model exposes a language hint; Auto leaves language detection to the model. Parakeet
  does not accept a language hint. Neither adapter exposes user vocabulary. Qwen prepares its fixed
  prompts and supported language hints once, then retains only the tokenizer's decoding tables
  and prepared tokens, not the BPE encoding rules.
- The `Model/` folder imports Foundation only. Context-sensitive spaces and capitalization are a
  pure decision driven by text around the caret. Capitalization adapts by default and can be disabled
  without disabling contextual spaces; if an app does not expose that context through
  Accessibility, the plain transcript is inserted without guessing.
- **Remove filler words** in the Model section is on by default. When enabled, Tinycast removes
  standalone English hesitations such as “um” and “uh” before inserting or copying text.
  It uses the selected language or identifies English locally for multilingual models in Auto.

## Validation

`dictation-cue-test` checks system resource paths, playback ordering and missing sounds without audio output.
`dictation-field-test` checks composer switching and teardown, scoped cancellation, delayed insertion
and cue timing with synthetic capture and real AppKit editors, without recording audio or touching
the shared clipboard.
`dictation-test` checks formatting and model options; `dictation-inference-test` checks score selection,
byte BPE, Fourier/mel features, listening bands and audio partitioning without downloading a model. `dictation-worker-test`
exercises framed IPC, worker reuse/switching, removal, cancellation and broken pipes with a fixture.
An in-process URLProtocol fixture checks byte progress before the first file completes, combined
progress and atomic installation for both families, including cancellation, stale staging cleanup
and competing downloads on shared or independent cache roots, without sockets or timed waits.

Also exercise all real models, short and long recordings, downloads/removal, initial microphone
grant and denial, hold/toggle shortcuts, Return/Escape, history after successful and failed pastes,
surrounding text with capitalization adaptation on and off,
model switching and idle release/reload. Check both processes in Activity Monitor, and validate
Debug and Release helper names, signatures and architecture slices. Model conversions and their
source licences must be reviewed before distribution; swapping one requires real-audio validation.

For reproducible real-model measurements, build Debug, install the models through Settings, then run:

```sh
./Scripts/benchmark-dictation.sh /path/to/sample.wav
```

The optional tool converts the supplied audio to mono 16 kHz and launches the built helper directly,
without using the microphone, clipboard or settings. It reports load and transcription times, sampled
helper `phys_footprint` in decimal MB and the recognized text, first with a fresh helper and then with
its model already loaded. macOS's file and Core ML caches remain untouched; a fresh helper is not a
cold disk-cache measurement. The 50 ms memory samples are not a guaranteed absolute peak.
Use the same audio, build configuration and otherwise idle machine for comparisons.

Optional arguments select a helper `.app`, model directory and a single model by its raw identifier.
This tool uses installed models and runs outside the deterministic suite and app targets.
