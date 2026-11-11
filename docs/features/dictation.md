# Dictation (experimental)

Dictation is off by default. Either assigned global shortcut records from the chosen microphone,
transcribes locally and sends the result through `TextInjector`. Parakeet V3, Ultra and Redux
support 25 languages. Parakeet V2 and Phonon-2 support English. Phonon-2 is a smaller model
retrained from V3 for English. Qwen3-ASR 0.6B and 1.7B support 30 languages and 22 Chinese dialects.
Settings marks Parakeet Ultra as Recommended and selects it by default. Choose Download
to install the selected Parakeet or Qwen model. Apple Dictation uses speech assets managed by macOS.
After microphone access is granted, enabling Dictation offers the missing recommended downloads for
the selected engines. On the defaults, Ultra transcribes speech and S1-mini is optional for Smart
cleanup and transforms. The setup lets you download both, download Ultra alone, or decide later.
Progress appears on the main Dictation settings page.

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
  can watch the inserted text for up to 60 seconds. It learns a single similar word replacement
  after the edit settles and stops watching when focus leaves the field or the surrounding text
  changes. Add a word or phrase under Dictation Settings > Dictionary to keep its preferred spelling.
  Enter a misspelling to replace the text Tinycast repeatedly hears. The dictionary stores up to 100
  entries on this Mac and keeps manual entries when learned ones are dropped. All engines apply
  dictionary entries to finished text. Apple Dictation also uses saved words as recognition hints.
  Entries apply with learning off. Remove an entry in Dictation Settings to stop using it.
- Microphone status appears in Permissions and the Dictation pane. Neither pane prompts on display;
  only a user action requests access, while revoked access is refreshed from macOS.
- Push to talk and Hands-free have separate global shortcuts and can both be assigned.
  Hands-free shows one shortcut recorder alongside the automatic double-tap hint.
  The alternate shortcut remains available through settings.json. Both bindings use conflict handling. Push to talk accepts a Carbon chord or a
  single physical modifier, including Fn/Globe. Hands-free starts and stops on successive
  activations and accepts double taps.
  Double tapping the Push to talk modifier toggles Hands-free. Modifier holds begin after 250 ms
  alone and reserve their key across other single and double taps.
  Another modifier, key or click cancels the hold without inserting text.
- Carbon or the shared modifier monitor reports release to stop a held recording. A hold release
  or cancellation does not stop a recording started by the toggle shortcut or a composer mic.
  Return finishes dictation. Escape cancels even when another app has focus. It dismisses the
  preview and indicator without restoring the idle bar. Opening a shortcut recorder cancels a held recording before
  pausing its shortcuts. A session token prevents stale transcription from inserting text later.
- AI Chat's composer mic is always click-to-toggle into that field: `toggle(into:)` targets its
  `ComposerTextView` in process whatever has focus. `field` tells only that button it is running.
  Switching chats or closing the composer cancels that editor's mic session. The session token is
  checked again when queued insertion runs.
- Shortcut dictation uses the input focused when the transcript is ready to paste. The indicator
  gives up keyboard focus first. The panel sits above app windows and can join other apps across
  Spaces, full-screen windows and Stage Manager. Text insertion reuses `TextInjector`, including
  its temporary clipboard ownership, focus, secure-input and protected-target checks. Dictation History
  keeps completed transcripts on this Mac, including transcripts that could not be pasted.
  History keeps transcripts for three months by default. Choose how long to keep them in Dictation
  Settings. Shortening the retention period removes transcripts older than the new cutoff.
  Dictation History uses the clipboard list's date groups and copy and paste shortcuts. Its rows
  show an outline microphone at the standard menu symbol size. The history also offers full
  transcript previews and local search.
  The Information section shows the date and word count.
  New entries also show the app where the transcript was pasted successfully.
  Dictation History and Dictation Settings are available even when recording is disabled.
- The compact dictation indicators use seven bars. The other styles use a capsule or rounded
  rectangle and include a status label. The style picker selects the shape. A Dark mode switch
  chooses light or dark for every style. Gray is no longer offered in Settings.
  The pill and transcript preview share the background for the selected appearance. In light mode,
  they also share the border color. Both appearances show an outline around the pill and transcript.
  The pill appears when the shortcut or composer mic starts a recording and shows Starting…
  until microphone setup completes off the main thread.
  It sits 16 points above a visible bottom Dock, or above the screen edge when the Dock is hidden,
  on another edge or display, or the active app is full-screen with the Dock hidden.
  Revealing a bottom Dock moves the indicator above it. It repositions when Spaces,
  display configuration or system presentation changes and checks visible Dock bounds twice per second.
  When the window list lacks the Dock's bounds, the indicator can use the Dock's accessibility
  bounds to distinguish a hidden Dock from space macOS still reserves for it.
  The indicator and transcript follow the frontmost app's frontmost visible standard window,
  using the display containing the largest portion of that window. Without an app window, they
  use the pointer's display. App activation updates placement immediately; window moves and
  switches within the same app are picked up by the existing twice-per-second placement check.
  The optional idle indicator shows a small bar while dictation is enabled without recording audio
  or loading a model. It restores on launch when enabled. Hovering reveals a microphone button
  at the same height as the recording pill. The button starts hands-free dictation. The indicator
  expands into the selected pill when recording begins and contracts when
  dictation finishes. The border follows the pill as it resizes. Live transcript preview is
  separately opt-in and shows recent words above the pill. It transcribes up to eight seconds of
  recent audio at a time, with a 1.5-second pause between requests. Preview requests are serialized
  with the final transcription. The full recording is transcribed when recording stops.
  After four seconds without new preview text, the card fades out while the recording pill stays visible.
  Its text and width are retained, and a new transcript update fades it back in. Empty or repeated
  recognition results do not restart this timer. Finishing or cancelling recording cancels the timer.
  Transcript animation defaults to on and follows global animations and Reduce Motion.
  The animation preference remains accessible in settings.json. New characters appear from left
  to right over 30 ms per character, with cubic ease-out and 150 ms character fades. The preview grows to its
  maximum width without shrinking during a recording. By default it scrolls along one line.
  Both preview modes grow with the revealed text up to 360 points. Two-line mode grows on the first wrap.
  Overlapping audio windows use bounded word alignment to retain recent words and apply recognition
  revisions. Uncertain overlaps replace the recent preview rather than append possible duplicates.
  Preview history is limited to 100 words. The bubble fits the visible
  text up to two lines. Older lines scroll up when new words begin appearing on the next line.
  Corrections update in place without replaying earlier text.
  Text updates without an implicit crossfade inside the separately animated, clipped viewport.
  Reduce Motion or turning the effect off displays updates immediately.
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
- Core ML models live under this build's bundle-ID cache. By default, the store terminates and reaps
  the helper as soon as speech recognition finishes, so cleanup can run without keeping the speech
  model resident. Choose a delay or Never to keep it warm between recordings. Switching models
  reaps the old helper before loading the next. Removing a loaded model
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
  pure decision driven by text around the caret. Capitalization adapts by default.
  The `dictation.adaptsCapitalization` override in `settings.json` leaves contextual spaces enabled.
  Capitalization, spacing, and correction learning share one snapshot of the focused editor.
  If an app does not expose caret context through Accessibility, Tinycast inserts the plain transcript.
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

## Text cleanup and transforms

Smart cleanup is opt-in. Its engine defaults to S1-mini by Superwhisper, with Apple Intelligence
and S1-ASR-Cleanup available as alternatives. S1-ASR-Cleanup is Daniel Rosehill's fine-tune of
S1-mini by Superwhisper for dictation with paragraph breaks. Each Q4_K_M download has its own
file in the channel's caches, pinned to a repository revision and checked against its SHA-256 digest. The app
bundles a pinned, statically linked llama.cpp server under `Contents/Helpers/TinycastCleanup`.
It binds only to authenticated loopback, disables its web UI and logs, and performs no remote
inference. Downloads alone use the network. Both downloads are intended for English. Smart cleanup
with either download preserves other languages. The local engine accepts up to 3,500 characters.
For Smart cleanup, both models use their published settings and disable thinking. S1-mini uses
semi-formal, lists, and general. S1-ASR-Cleanup uses semi-formal, prose, general, and layers 1 and 2.
When a recording will use Smart cleanup or an automatic transform, Tinycast starts loading the
selected cleanup engine at recording start. The local helper stays available through the recording
and exits when the recording and its cleanup or transform finish. Cancelling a recording releases
its helper too. Standalone previews and manual transforms keep a one-minute idle grace period.
The helper also stops on request errors, disabling dictation, changing engines, or quitting.
Tinycast releases its Apple Intelligence session after use.
macOS manages the shared Apple Intelligence model's memory.

Saved transforms live in `dictation-transforms.json` in this channel's application-support directory.
Polish, Shorten, Make a list, and Prompt Engineer seed a new installation; users can edit, create, or delete entries.
Transforms use the same engine selection as Smart cleanup, even in the Off, Basic, and Advanced
modes. Local models receive the transform instructions directly. Apple Intelligence honors its
availability and route switch. Auto-apply is off by default. Automatic processing occurs before
insertion, with the original recording token checked again after processing. Smart cleanup failures
use Advanced cleanup. If only an automatic transform was requested and it fails, Tinycast keeps
the transcript it received. Cleanup and transforms run locally.

History preserves original recognition text when the inserted text was processed. Its actions
include saved transforms, Copy original, and Restore original. The preview shows only the current
transcript; the original stays available through Actions without a second transcript section.
The built-in Paragraphs transform is available in History and as an assignable shortcut. The
selected engine chooses which sentences start a paragraph, and Tinycast inserts the breaks into the
existing text. This preserves the words and punctuation and keeps the work out of automatic dictation.
A transform shortcut processes the latest History entry and opens History for review; it never
replaces arbitrary text in another app. Manual operations check cancellation, entry identity, and
unchanged input before updating History. Restoring an original cancels a pending manual operation.
The Text cleanup cards show fixed examples of the same dictation at each level. Below the cards,
the preview sits beside the editable sample and updates when the sample or mode changes.
The Examples menu fills the sample with currency, a date, a time, or a spoken paragraph command.
Smart cleanup waits briefly for typing to pause. The transform editor has its own sample preview.

Prompt Engineer uses a structured output template, preserves quoted examples, and leaves missing
requirements as placeholders. It generates a prompt instead of executing the dictated task.

## Settings organization

The main Dictation page groups the Dictation History and Dictation Settings commands with Enable
Dictation. Recording groups Push to talk, both Hands-free shortcuts, the microphone,
Indicator & feedback, and Speech recognition. Writing groups Text cleanup, After dictation,
Dictionary, and history retention. The Indicator & feedback row previews
the current style alongside the preview on its detail page. Settings search opens the detail
page containing its target. The window Back and Forward buttons include these detail pages
in their history, including the transform editor, and restore the page visited before switching
settings panes. Back from the editor returns to After dictation. The title-bar header
uses native macOS path breadcrumbs beside Back and Forward, with space between the controls.
Clicking Dictation returns to the overview; no second back row appears inside the page.

Text cleanup offers Off, Basic, Advanced, and Smart. Basic and Advanced remove English fillers
and format supported spoken values, including currency, dates, times, percentages, measurements,
fractions, and certain contact details. Both use local rules and load the bundled FluidInference
formatter when a supported phrase needs it. Advanced also handles stutters, clear weekday
corrections, and spoken punctuation. It can format lists from explicit commands, ordered cues,
headings, or a matching item count. It can add paragraph breaks at clear topic changes and recaps. See the
[formatting reference](dictation-formatting.md) for examples and limits. If the 30 ms formatting
budget expires, Basic keeps its filler removal and Advanced keeps the original text. Smart runs the
selected engine. The After dictation switch
pauses automatic transforms without clearing the Default transform selection. Transform instructions,
shortcuts and sample preview appear while editing that transform. Smart cleanup and transforms
share the engine selected in Text cleanup. The Text cleanup page also manages its model downloads.
Speech recognition manages the speech model. Sounds are under Indicator & feedback.

The cleanup model download shows transferred bytes and percentage in a linear progress bar. At 100%,
Finishing download remains visible while the model checksum is verified. Cancel stays available.
The Smart cleanup preview shows the selected engine beside its result.
