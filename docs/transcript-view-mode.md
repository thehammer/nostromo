# Transcript view mode: manual QA

The Focus / All activity mode per focus (View menu, the chip in the composer bar, the global default) is
covered by tests, except what needs a person at the keyboard with Full Keyboard Access on.

**Manual QA (needs a person; none of it runs in CI).**

- View menu chords work, including with a SwiftTerm terminal pane focused, and the macOS-injected
  Enter Full Screen items in the View menu do not collide with them.
- With Full Keyboard Access on (System Settings, Keyboard), Tab from another control and ⌃Tab from the
  composer both reach the transcript view chip. Tab inside the composer types a tab and never leaves it,
  the same as the model and background chips. (`testTheKeyViewLoopAfterTheComposerReachesTheChipWithFullKeyboardAccessOn`
  checks the key view loop and skips on CI, where Full Keyboard Access is off.)
