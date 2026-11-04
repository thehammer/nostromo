# Task output window

A task window shows the task's output from one shared `TaskOutputModel` per `(tag, taskId)` (the same
model `nostromo-app tasks output` reads). See the type's doc comment for the load ladder and polling.

## Catching up and the end of the output

- A file that is ahead of what the model holds is read chunk by chunk, back to back, not one chunk per
  poll. While that goes on the model reports itself busy (`isRefreshing`), so `tasks output` says
  `loading`, not `ready`.
- When the task ends mid catch-up the final read keeps following the file until it reaches its end, up
  to 64 MiB or 10 s (`finalReadCapBytes`, `finalReadCapSeconds`). A file more than the 10 MB window ahead
  is reloaded from its tail instead. If the cap is hit the notice line says `Output truncated: ...`;
  it is never silent.

## Copying

- **Copy All** (the button and the context menu item) copies the output as the model holds it.
- **Select All, then ⌘C** copies the text view's *display* text. That text has a soft newline inserted
  every 65,536 UTF-16 units of a line that has no newline (`TaskOutputDisplay.lineLimit`) so one huge line
  does not stall TextKit. Those newlines are in the copy. Only Copy All returns the original text.
  (Intercepting ⌘C to map the selection back onto the original was not worth the code: a selection would
  have to be translated through every inserted break.)
