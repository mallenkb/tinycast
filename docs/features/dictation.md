# Dictation (experimental)

Dictation is off by default. Either assigned global shortcut records from the chosen microphone,
transcribes locally and sends the result through `TextInjector`. Parakeet V3, Ultra and Redux
support 25 languages. Parakeet V2, Unified and Phonon-2 support English. Phonon-2 is a smaller model
retrained from V3 for English. Qwen3-ASR 0.6B and 1.7B support 30 languages and 22 Chinese dialects.
Settings marks Parakeet Ultra as Recommended and selects it by default. The speech recognition page
shows selectable rows and filters for accuracy, speed, multilingual support, compact size and live
preview. Accuracy and speed are curated shortlists, compact means at most 650 MB on disk, and live
includes Apple Dictation and Parakeet Unified. Unified uses rolling batch preview, not streaming.
Rows show language coverage and approximate disk size; published
benchmark figures are external measurements, with their sources in the row help. Hovering over language coverage shows the supported languages.
Choose an installed model, download one from its row, or remove it after selecting another. Cohere Q8
uses a separate Core ML encoder-decoder pipeline and 14 selectable languages, with English as its default.
Its fixed 35-second batch encoder does not provide live preview. A window that fills the decoder's
cache keeps the text it produced. Its six-token repetition ban covers only generated text. Cohere Q4 requires a separate GGUF
speech runtime and remains unavailable.
Qwen models remain available. Apple Dictation uses speech assets managed by macOS.
After microphone access is granted, enabling Dictation offers the missing recommended downloads for
the selected engines. On the defaults, Ultra transcribes speech and Emberon-2 is optional for Smart
cleanup. The setup lets you download both, download Ultra alone, or decide later.
Model downloads show progress and cancellation within their row; onboarding also shows progress on
the main Dictation settings page.

Parakeet and Qwen use Core ML and Accelerate. Unified uses a separate RNNT decoder and offline 15-second windows; its live preview uses the existing rolling batch preview. Each family has its own adapter inside the bundled
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
- Auto-learn words is active when Dictation is enabled. After a confirmed paste into a readable text
  field, Tinycast watches that insertion while the field remains focused. It finds the insertion again
  by up to 48 characters on each side, so edits elsewhere in the document or a moved caret don't lose
  it; editing those neighboring characters ends the watch. An `AXObserver` (or `NSText` change
  notifications in Tinycast's own editors) wakes the watcher on edits and focus moves, with a
  5-second safety poll; a field without notifications is polled every second. The watcher stops 60
  seconds after the last edit and 5 minutes after the paste at most. Fields over 8,192 UTF-16 units,
  checked through `AXNumberOfCharacters` before the value is copied, are not observed.
  After two seconds without an edit, it aligns the original and edited words and passes each changed
  span of up to three words to `DictationCorrectionPolicy`. If the field closes or clears, the last
  read edit counts only if it had already paused for a second, so a half-typed word is never learned.
  Starting another recording flushes readable pending edits before taking the next vocabulary snapshot.
  The watcher also stops when the insertion is deleted, Dictation is disabled, or its composer is
  closed or rebound. Stopping releases the field probe, observer and transcript snapshots.
  The policy treats the system spell checker as the vocabulary: changing one real word to another
  (affect/effect, Monday/Tuesday, a rewrite) is a choice, not a misrecognition, and is never learned.
  Numeric edits, recognized English number/date/negation words, punctuation-only edits, swaps and
  conflicting replacements of the same source are rejected. A name-like target (capitalized mid-sentence
  or with inner capitals) close in spelling or in a coarse sound key is learned on first sight
  (cubernetes → Kubernetes, Jhon → John, mc donald → McDonald). Weaker pairs are candidates: a
  merged multi-word mishearing (there sure → Thiessen), a capitalization of an unknown term
  (tinycast → Tinycast, never at a sentence start), a fix to a real word, or a swap between two names.
  A candidate is learned when a second dictation in the same app session makes the same change; the
  same neighboring words keep the entry scoped to them, different ones learn it everywhere. Up to 100
  candidates are kept in memory; they do not load a speech or cleanup model and are discarded on quit.
  Revisions and undo update the original recognition mapping, rather than teaching a replacement chain,
  and changing a replaced word back to what was heard removes the entry.
  Each newly learned entry shows a “Learned” HUD, and Dictation Settings > Dictionary marks learned
  entries so they can be removed.
  A user's manual dictionary entries take priority. Add a word or phrase under Dictation Settings >
  Dictionary to keep its preferred spelling, or enter a misspelling to replace it explicitly.
  The dictionary stores up to 100 entries on this Mac and keeps manual entries when learned ones are
  dropped. Learned entries persist across restarts and apply once to finished text after cleanup and
  transforms, as whole words (a possessive ’s still matches). Apple Dictation also uses unscoped saved
  words as recognition hints. Remove an entry in Dictation Settings to stop using it. Edits to part of an
  already replaced multiword alias are skipped. These rules infer spelling preferences, not changes to
  the speaker's intent.
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
  preview and indicator without restoring the idle bar. Once a recording passes 30 seconds, the
  first Escape only shows a reminder HUD and a second Escape within two seconds discards it. A
  dialog would take focus from the app being dictated into, so the confirmation stays a key press.
  Starting a dictation while the last one is still transcribing shows a "Still finishing" HUD. Opening a shortcut recorder cancels a held recording before
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
  When the app focused at stop differs from the one focused when the text is ready, or the paste
  fails, Tinycast copies the transcript and says so in a HUD instead of pasting.
  A tap under 250 ms is ignored silently; an empty result shows a neutral "No speech detected".
  Paste Last Transcript pastes the newest History entry. Undo Last Dictation removes the last
  insertion only when the field still holds exactly what dictation left: an own editor is restored
  in place, and another app gets ⌘Z only when it is frontmost and Accessibility shows the same text
  and caret. Otherwise a HUD explains it can't undo. Both commands have optional shortcuts in
  Dictation settings and are unbound by default.
  After a failed transcription or a cancel, the recording stays in memory for 60 seconds.
  Retry Last Dictation transcribes it again into the focused input; quitting discards it.
  When a speech model fails, Apple Dictation transcribes the recording instead and a HUD says so.
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
  By default it sits 16 points above a visible bottom Dock, or above the screen edge when the Dock is hidden,
  on another edge or display, or the active app is full-screen with the Dock hidden. Dragging the pill
  shows alignment guides and snaps it to the display center and edges. A click on the idle pill still
  starts dictation. Its position is remembered per display, and Indicator & feedback can restore the
  default position. The transcript card follows the pill and stays within the display when it appears.
  Revealing a bottom Dock moves the indicator above it. It repositions when Spaces,
  display configuration or system presentation changes. While recording, transcribing or dragging,
  it also checks Dock bounds and the frontmost window twice per second; the idle bar does not poll.
  When the window list lacks the Dock's bounds, the indicator can use the Dock's accessibility
  bounds to distinguish a hidden Dock from space macOS still reserves for it. Those bounds are
  read once and reused until the Dock changes.
  The indicator and transcript follow the frontmost app's frontmost visible standard window,
  using the display containing the largest portion of that window. Without an app window, they
  use the pointer's display. App activation updates placement immediately; window moves and
  switches within the same app are picked up by the active pill's placement check.
  Idle hover uses a tracking area on the bar itself rather than a global mouse monitor.
  The optional idle indicator shows a small bar while dictation is enabled without recording audio
  or loading a model. It restores on launch when enabled. Hovering reveals a microphone button
  at the same height as the recording pill. The button starts hands-free dictation. The indicator
  expands into the selected pill when recording begins and contracts when
  dictation finishes. The border follows the pill as it resizes. Live transcript preview is
  separately opt-in and shows recent words above the pill. Apple Dictation streams audio to one
  recognition session and displays partial results as they arrive. Stopping flushes the remaining
  audio and finalizes that session. If the stream fails, the full recording is still available for
  a fresh Apple Dictation pass. Parakeet and Qwen use overlapping five-second audio windows and aim
  to start requests at least 350 ms and 500 ms apart, respectively. One request runs at a time.
  A request is skipped when the audio since the previous one stays near the recording's noise floor
  and a request has already covered the end of speech. After three unchanged results the interval
  doubles, and after six it triples, until the text changes. Five-second windows stay because
  the decoders' cost grows with the audio, even though the encoders pad to 15 seconds.
  For Parakeet and Qwen, the recognition loop also looks for a pause of at least 600 milliseconds
  from 10 seconds into each segment. A pause is quiet relative to the tenth-percentile frame level
  of the last 30 seconds, never below the original absolute threshold. Without a pause by 30 seconds,
  it cuts at the quietest 200 ms of the last three seconds. A cut rejected for an unfinished
  number moves the next forced cut at most five seconds later. It transcribes completed audio at
  those cuts, even with the preview off. On stop it transcribes the remaining audio and joins the
  results in order. A failed segment is dropped and the next one covers its audio again; after three
  failures in a row, segmentation stops. It retries the full recording if the tail is longer than
  30 seconds or cannot be reused, or an amount may cross a segment boundary. The app retains the
  bounded capture until this check finishes.
  A preview error hides stale text and retries after 1.5 seconds. Three consecutive failures end
  the preview loop; the full recording remains available for final transcription.
  After four seconds without new preview text, the card fades out while the recording pill stays visible.
  Its text and width are retained, and a new transcript update fades it back in. Empty or repeated
  recognition results do not restart this timer. Finishing or cancelling recording cancels the timer.
  Transcript animation defaults to on and follows global animations and Reduce Motion.
  The animation preference remains accessible in settings.json. The newest words receive a
  character reveal of up to 340 ms per line with a 150 ms fade. Word alignment preserves earlier
  text when recognition revises a phrase or shifts the rolling window. The viewport follows the
  newest text. The preview grows to its maximum width without shrinking during a recording.
  By default it scrolls along one line. Both modes grow up to 400 points; two-line
  mode shows the newest two lines.
  Overlapping audio windows use bounded word alignment to retain recent words and apply recognition
  revisions. Uncertain overlaps replace the recent preview rather than append possible duplicates.
  Preview history is limited to 100 words. Text updates without an implicit crossfade inside the
  separately animated, clipped viewport. Reduce Motion or turning the effect off displays updates
  immediately.
  While live preview is active, Basic and Advanced prepare completed blocks that remain unchanged
  across two recognition updates. One background task runs at a time and never writes to the preview.
  Final cleanup reuses complete lines only on an exact source match. Within a revised line it can
  reuse validated spoken-value conversions after matching those phrases again in the final context.
  Language, literal-text, size, correction and formatting checks still apply to the final transcript.
  Preparation reads a bounded recent preview and keeps a bounded cache for the current recording.
  Stopping cancels pending preparation without waiting for it; completed entries are consumed by
  final cleanup. Cancellation, preview failures and session reset discard the cached text.
  When Smart cleanup uses a downloaded engine and no automatic transform, one background worker
  can clean completed transcript sections as recognition continues. It waits for at least 100
  words and a sentence boundary, leaving recent words for the next section. On stop, Tinycast
  reuses the prepared sections only while they match the final source text exactly. The final
  tail goes through cleanup in order. Automatic transforms still use the complete transcript.
  Each indicator fits the current state. Settings previews both listening and processing for the
  selected style.
  The waveform blends neighboring
  frequency peaks so the bars rise together. Capture samples 21 bands at most 20 times per
  second through a reused 512-point Accelerate transform. The logarithmic bands span 32–5000 Hz.
  The bars grow around a fixed centerline and ease between readings when Reduce Motion is off.
  A spinning ring replaces the bars during final transcription and cleanup. Labeled styles cycle
  through the same shuffled list of ten processing words every two seconds across both stages.
  The visible capsule fits the current word with equal horizontal padding and resizes around its
  center. The ring and word stay centered together. The containing window reserves room for the
  longest word so cycling does not clip the capsule or shift its position. Active labeled edge snaps
  reserve the same room; idle edge placement stays unchanged. Settings uses the same
  cycling preview. Reduce Motion and disabled animations make width changes immediate.
  The ring and the text shimmer are repeating SwiftUI animations rather than per-frame timelines,
  and pause when Reduce Motion is on. Only the waveform view reads live levels. After five seconds
  of processing, labeled styles add an elapsed clock. In the final minute of a recording, labeled
  styles show a countdown after Listening; the compact pill keeps its size and VoiceOver announces
  one minute and ten seconds left in every style. The Settings preview stops cycling words while
  its window is inactive or the preview is scrolled away.
  Closing the panel releases its hosting view.
- Recording leaves the system output volume alone.
- Play sounds is on by default. When on, macOS's `dt-begin.caf` plays on the microphone's first samples
  and `dt-confirm.caf` when recording stops (release, toggle, Return or the length limit); cancelling
  stays silent. These are internal resources in `AssistantServices.framework`, not bundled audio;
  the cue runner loads them only when a recording first plays a sound.
  Their location is undocumented, and a missing sound is silently skipped without blocking dictation.
  A Bluetooth headset drops output while it switches to its microphone, sometimes after the first
  samples arrive, so with a Bluetooth microphone the start cue waits half a second more. The stop cue
  plays before the microphone closes and a headset switches back. Media can mask the cues, and
  speaker playback can reach the microphone.
- The microphone, waveform, permissions and insertion stay in Tinycast. For Parakeet and Qwen,
  model loading, audio features and decoding run in `Tinycast Dictation` (`Tinycast Dev Dictation` in Debug). The helper
  starts loading the selected model alongside microphone setup. If the user stops before it is ready,
  the transcription waits for the same load before sending the buffered audio. A failed preload
  leaves the audio available for a regular transcription request. Every model has up to three
  minutes to load, because a first Core ML compilation can take longer than a minute. Once it is
  ready, transcription uses the normal timeout. Capture start, model loads and each preview,
  segment and final transcription emit `com.tinycast.perf` signpost intervals for Instruments. Main-app state never retains Core ML models.
  The helper is an embedded accessory app with no bundled icon, Dock item or windows.
- The Apple Dictation engine uses Apple's on-device `DictationTranscriber` and the Mac's preferred
  language. Tinycast starts preparation when recording begins. macOS installs missing speech assets,
  then manages those assets and their memory. The analyzer lives for one recording.
- Dev and release share Core ML models under `~/Library/Caches/com.tinycast.app/Dictation/`. By default, the store reaps
  the helper one minute after the last recording, so back-to-back dictation finds the model warm.
  Choose After each dictation to reap it as soon as speech recognition finishes, or a longer delay or
  Never to keep it longer. Switching models
  reaps the old helper before loading the next. Removing a loaded model
  stops its helper before deleting the directory and blocks new requests for that model meanwhile.
  Cancelling an in-flight load or final transcription, failed final inference and normal quit
  stop the helper. A cancelled or failed preview or segment request keeps the loaded helper: the
  exchange finishes and its result is discarded. Late results cannot paste.
- Audio stays in memory, bounded to ten minutes of mono 16 kHz Float32 samples. Pipes carry
  bounded JSON control messages and binary audio; recordings are never written to disk or sent
  over the network. Long recordings split near a quiet passage without overlapping samples.
  The capture buffer grows a minute at a time, and the helper reads audio straight into its buffer.
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
  prompts, supported language hints and their embeddings once, then retains only the tokenizer's
  decoding tables and prepared tokens, not the BPE encoding rules.
- The `Model/` folder imports Foundation only. Context-sensitive spaces and capitalization are a
  pure decision driven by text around the caret. Capitalization adapts by default.
  Mid-sentence, the first letter stays capitalized for "I" and its contractions, a word whose
  second letter is uppercase, a word the transcript capitalizes mid-sentence elsewhere, and a
  word that starts a Dictionary spelling.
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
`dictation-test` checks formatting, model options, multi-edit alignment, confidence checks, source
attribution, undo, debounce, input bounds and repeated inference. `dictation-correction-test` runs a
table of realistic correction scenarios (misheard words and names, rewrites, deletions, casing,
punctuation, changes of mind, autocorrect, shifted insertions, abandoned edits, reverts) through the
detection, session timing, insertion anchor and store, with a fixture vocabulary. Hidden-editor checks in
`dictation-field-test` also cover learning across dictations, persistence, candidate corroboration,
manual-entry priority and correction watcher teardown. These fixtures do not activate windows,
record audio or write to the shared clipboard. `dictation-inference-test` checks score selection,
byte BPE, Fourier/mel features, listening bands, audio partitioning, pause cuts, preview pacing,
Cohere's mel features against a scalar reference and its repetition ban without downloading a model. `dictation-worker-test`
exercises framed IPC, worker reuse/switching, removal, cancellation, dropped previews and segments
that keep the helper, and broken pipes with a fixture.
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

Smart cleanup is opt-in. Its engine defaults to Emberon-2 Q4, with Apple Intelligence,
S1-mini by Superwhisper, and S1-ASR-Cleanup available as alternatives. S1-ASR-Cleanup is Daniel Rosehill's fine-tune of
S1-mini by Superwhisper for dictation with paragraph breaks. Each Q4_K_M download has its own
file in the shared caches, pinned to a repository revision and checked against its SHA-256 digest. The app
bundles a pinned, statically linked llama.cpp server under `Contents/Helpers/TinycastCleanup`.
It binds only to authenticated loopback, disables its web UI and logs, and performs no remote
inference. Downloads alone use the network. The local models are intended for English. Smart cleanup
with a local model preserves other languages. Smart cleanup processes long recordings in sections
of up to 1,800 UTF-8 bytes, preferring line and sentence breaks and retaining the original whitespace
between sections. Text without a safe break within that limit stays as dictated. For local cleanup,
one helper serves sections sequentially. Sentences with recognized numbers, currency, and literal
text use local rules. If a model response loses too many source words or adds a protected value,
the source section stays in the transcript. If a model request fails, completed sections are kept
and Advanced cleanup handles the remaining sections. A transform sends the whole transcript in one
request when it fits: up to 3,500 characters for a local engine, and up to 8,000 for Apple
Intelligence, subject to the model's limits. Longer transcripts go through Polish, Shorten, and Make a
list in the same 1,800-byte sections. Prompt Engineer and custom transforms need the whole text, so a
longer transcript fails at once with a too-long message. Apple Intelligence gives one request, or all
of its sections, a single deadline of 15 seconds plus 8 ms per byte, and prewarms the next section's
session while the current one runs. Apple Intelligence and Emberon-2 each combine Smart cleanup with
an automatic transform in one request when both are enabled.
For Smart cleanup, the S1 models use their published settings and disable thinking. S1-mini uses
semi-formal, lists, and general. S1-ASR-Cleanup uses semi-formal, prose, general, and layers 1 and 2.
Emberon-2 uses Promethic Labs' cleanup prompt and the transcript without an S1 control line.
When Emberon-2 is selected, After dictation and manual transforms use S1-mini. With an automatic
transform, S1-mini also takes the Smart cleanup instructions, so the recording loads one model and
makes one pass. Emberon-2 can't follow transform instructions, and loading both would mean two
servers or a cold start between key release and paste. When a recording will use Smart cleanup or an
automatic transform, Tinycast starts loading the engine that recording will use at recording start. The local helper stays available through the recording
and exits when the recording and its cleanup or transform finish. Cancelling a recording releases
its helper too. Standalone previews and manual transforms keep a one-minute idle grace period.
The helper also stops on request errors, disabling dictation, changing engines, or quitting.
Tinycast releases its Apple Intelligence session after use.
macOS manages the shared Apple Intelligence model's memory.

Raw recording buffers are released as soon as recognition returns, before cleanup and insertion.
Each cleanup operation and model download creates its own ephemeral network session and invalidates it
when finished; an idle cleanup store retains no network session.

Saved transforms live in `dictation-transforms.json` in the shared application-support directory.
Polish, Shorten, Make a list, and Prompt Engineer seed a new installation; users can edit, create, or delete entries.
Transforms use the same engine selection as Smart cleanup, even in the Off, Basic, and Advanced
modes. Local models receive the transform instructions directly. Apple Intelligence honors its
availability and route switch. Auto-apply is off by default. Automatic processing occurs before
insertion, with the original recording token checked again after processing. Smart cleanup failures
use Advanced cleanup and show one notice: the missing model or disabled route when that is the
cause, otherwise the fallback notice. When an automatic transform fails, Tinycast keeps the Smart
cleanup result, or the transcript it received, and the notice names the transform's own reason: too
long, a model to download, a timeout, or a generic failure. When Smart cleanup shared that request,
Advanced cleanup runs on the original instead. The app also logs each error for diagnosis. Cleanup
and transforms run locally.

App overrides on the Text cleanup page choose a cleanup level and an automatic transform per app by
bundle ID. Each choice can stay on Default. The app is the dictation's target when recording starts.
The overrides live in `dictationAppOverrides`, mirror to `settings.json` as `dictation.appOverrides`,
and stay out of settings backups with the other writing preferences. Deleting a transform sets any
override that named it to No transform.

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
Dictation. Recording groups Push to talk, both Hands-free shortcuts, Paste last transcript,
Undo last dictation, the microphone,
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
formatter when a supported phrase needs it. Advanced also handles repeated pronouns and contractions,
other supported stutters, clear weekday
corrections, and spoken punctuation. It can format lists from explicit commands, ordered cues,
headings, or a matching item count. It can add paragraph breaks at clear topic changes and recaps,
or at transitions and questions after a substantial passage. See the
[formatting reference](dictation-formatting.md) for examples and limits. If the formatter's fixed
work allowance runs out, Basic keeps its filler removal and tries currency formatting on its own.
Advanced keeps the original text. Smart runs the
selected engine. The After dictation switch
pauses automatic transforms without clearing the Default transform selection. Transform instructions,
shortcuts and sample preview appear while editing that transform. Smart cleanup and transforms
share the engine selected in Text cleanup. The Text cleanup page also manages its model downloads,
including S1-mini when Emberon-2 is selected and After dictation is on. The After dictation page offers
the transform engine's download whenever it is missing.
Speech recognition manages the speech model. Sounds are under Indicator & feedback.

The cleanup model download shows transferred bytes and percentage in a linear progress bar. At 100%,
Finishing download remains visible while the model checksum is verified. Cancel stays available.
The Smart cleanup preview shows the selected engine beside its result.
