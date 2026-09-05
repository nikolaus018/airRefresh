# Changelog

## Unreleased

### Fixed

- **A build could look like it had hung at its eighth line.** The log inferred
  "is the user still at the bottom?" from `onAppear`/`onDisappear` on its scroll
  anchor — which lives inside a `LazyVStack`, so layout materialised the anchor,
  the handler wrote `@State`, that write forced another layout, and the main
  thread never came back. Following is now an explicit control that cannot feed
  back into layout. *(Introduced and caught inside this same cycle, by running a
  real build against the real app; the unit tests never saw it.)*
- **Console output is published in batches** rather than one line at a time.
  `xcodebuild` emits lines faster than SwiftUI can lay them out, and a line-by-line
  publish spent the build re-rendering a list instead of reading a pipe.
- **A failed build read "Build failed exited with code 65".** `ShellError.failed`
  was handed a human summary and formatted it as though it were a command name.
- **The most common `devicectl` failure produced no advice.** The hint matched
  "could not find device"; what `devicectl` actually prints is "The specified
  device was not found."
- **A signing reset that failed part-way left profiles in two places at once** —
  some apps re-signed, others holding a profile whose siblings had vanished, and
  nothing on screen saying which was which. A partial archive now rolls itself
  back and reports the original error.
- **`Label`-based buttons had no accessible name at all.** SwiftUI does not turn
  a Button's `Label` into an `AXTitle` or `AXDescription` on macOS, so VoiceOver
  announced most of the app's controls as just "button". Every one is now
  labelled explicitly.
- **Two refreshes could start at once on one project.** The guard against a
  second run read a phase that only became "running" once the async task got
  its turn on the main actor — so a double-click, or a held ⌘1, walked straight
  past it and put two `xcodebuild`s into the same build directory, with only
  the second one reachable by Stop. A run now claims its slot synchronously.
- **Pressing Stop counted as a failure.** It armed the scheduler's two-hour
  backoff and, after three of them, paused automatic refresh on a project that
  was in perfect health. Stop is now its own outcome: not a success, not a
  fault. A run the 30-minute watchdog gives up on still counts as a failure,
  because that one is.
- **A profile that expired days ago said "Expires today".** The day count is
  floored at zero so the scheduler never has to reason about negative time, but
  the sentence on screen now says "Expired" and turns red.
- **The menu bar icon showed the same glyph whether or not a refresh was
  running**, which made the "running" branch of the code decorative. Running,
  healthy, due and failed each have their own symbol now.
- **`⋯ ▸ Open Profile Backups` did nothing before the first reset**, because the
  folder does not exist until something is backed up into it. It is created on
  demand.
- **Clicking the Dock icon could raise the wrong window.** It reached for
  `NSApp.windows.first`, which is just as likely to be the status item or the
  settings pane.
- **"Open AirRefresh" from the menu bar put the Dock icon back** — permanently,
  until the next launch — on an app the user had explicitly asked to keep out
  of the Dock.
- **Choosing a folder with no Xcode project in it beeped and gave no reason.**
  It says what was wrong with the folder now.
- **Diagnostic hints were matched against the whole log**, so a stray
  "mismatch" or "passcode" in an earlier step could put confident, wrong advice
  under an unrelated failure. Hints now read only the failing command's own
  output.
- **The scheduler's timer could be throttled into silence by App Nap** — the
  one thing an app whose entire job happens while nobody is watching cannot
  afford. It now holds an activity assertion that opts out of App Nap while
  automatic refresh is on, and deliberately still lets the Mac sleep.
- **Signing expiry was re-read once per slot, on the main thread, every three
  minutes**, re-parsing every provisioning profile on the Mac each time. One
  pass now serves every slot, off the main actor.
- **The scheduler's explanation on screen was up to three minutes stale**, so
  the settings pane would sit there describing what would happen under the
  threshold you had just changed. It is worked out live.
- **A denied notification permission was invisible**, leaving a switch that was
  on and did nothing — and notifications posted while AirRefresh was frontmost
  were never presented at all.

- **`Refresh All` ran every project at once.** Parallel `xcodebuild`s racing
  through the same provisioning-profile folder is precisely the conflict the
  scheduler goes out of its way to avoid — and the README claimed they already
  ran one at a time. They do now.
- **A slot removed while its card was on screen could crash the app.**
  `SlotCardView` addressed its slot by array position, and SwiftUI can evaluate
  a view — or write through one of its bindings — after the underlying element
  is gone. Slots are addressed by identity throughout now.
- **Stop only sent `SIGTERM`.** A wedged `xcodebuild` is free to ignore that, so
  it is now followed by `SIGKILL` after a five-second grace period.
- **A build that never finished blocked every future automatic refresh**, because
  `isAnyRunning` stayed true forever. Runs now give up after 30 minutes and say so.
- Turning notifications on after first launch never asked for permission, leaving
  a switch that was on and did nothing.
- Runners were created lazily from inside view bodies, mutating observable state
  during a SwiftUI update.
- The output stream had no buffering limit; a pathological build could grow the
  app's memory without bound.
- Scheme discovery failing left an empty dropdown and no explanation. The reason
  is shown on the card now.
- The scheduler polled for devices with a subprocess every ten minutes even when
  nothing could possibly run, and did not re-check after the Mac woke from sleep.

- **Signing resets no longer take out unrelated projects.** A refresh used to
  archive *every* provisioning profile on the Mac. With more than one slot on
  automatic refresh that meant each project destroyed the others' signing, and
  the scheduler — which treats "no profile found" as "refresh right now" —
  rebuilt them in a loop indefinitely. A refresh now reads the target's bundle
  identifier before touching anything and archives only the profiles that cover
  that app, plus any that have already expired. `⋯ ▸ Reset Signing Only…` still
  archives everything, because that is what you are explicitly asking it for.
- A slot whose profile cannot be found on disk now waits out the assumed 7-day
  lifetime from its last good run instead of being declared due on every tick.
- Toggling *Start at login* when macOS refuses the request no longer re-enters
  its own `didSet`.
- Build log lines containing the word "succeeded" in passing are no longer
  coloured as successes.

### Changed

- **The window header answers the question instead of repeating the title.**
  The title bar already says AirRefresh; the header now leads with how much
  life your signing has left, with colour spent only on bad news.
- **The project name is a label until you ask to rename it.** As a permanently
  live text field it became the window's first responder, so opening AirRefresh
  greeted you with your project's name selected and one keystroke from being
  replaced. Double-click it, or use ⋯ ▸ Rename.
- **The log stops yanking you back to the bottom** the moment you scroll up to
  read something, and offers a "Jump to Latest" button instead.
- **"Refresh All" is hidden when only one project is set up**, where it was a
  second prominent blue button doing the same thing as the first.
- Borders were drawn in hardcoded black at low opacity, which is not a border
  in dark mode. They use the system separator colour now.
- Icon-only buttons, pills and pickers have accessibility labels.
- The device bar shows one line with the full list in its tooltip, rather than
  pasting every device end to end.
- Settings grew a version row and a shortcut to the profile backups, and its
  height follows its content instead of clipping the last project.
- "Clear Log" clears the log and nothing else — it used to wipe the card's
  status along with it.
- The menu bar shows what a running project is *doing*, not its profile expiry.
- The signing reset and the build-output clean now run off the main actor.
- `-showBuildSettings` carries an explicit `-destination-timeout`, so step one
  cannot sit waiting on a sleeping phone when the bundle id from the last run
  would have done.
- `SWIFT_STRICT_CONCURRENCY = complete` is on in both configurations, and the
  target builds clean under it.

### Added

- **A test harness for the pipeline itself.** `SlotRunner` now reaches the world
  through a `RunEnvironment` of injected closures, so the whole
  inspect → reset → build → install → launch sequence can be driven against a
  fake: every step, every failure branch, cancellation, and the argument list
  each command is actually given — with no process spawned, no profile moved and
  no phone involved. This is the one genuinely destructive path in the app and it
  had no coverage at all. It found three real bugs on the first run.
- An app icon, generated by `Tools/GenerateAppIcon.swift` so it can be reviewed
  in a diff rather than landing as an opaque binary.
- A unit test target — 69 tests — covering the signing-reset rules and the
  archiving itself (against a scratch directory), profile parsing, the
  scheduler's decision table, `Shell`'s streaming and cancellation, `devicectl`
  output parsing, and slot migration.
- A hint for schemes that are not shared.
- `Scripts/build-release.sh` and a GitHub Actions workflow.
