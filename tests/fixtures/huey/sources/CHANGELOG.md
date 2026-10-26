# Changelog

## 2.1.310

- Fixed the status line flickering when a terminal is resized during a long tool call
- Fixed `/resume` listing sessions from other working directories
- Improved startup time on very large repositories

## 2.1.309

- Fixed an occasional hang when a background task finished while a permission prompt was open
- Added a short confirmation after `/export` writes a file

## 2.1.308

- Fixed duplicate entries in the command history after a crash
- Reduced memory use when reading very long tool output

## 2.1.307

- Fixed proxy settings being ignored for plugin downloads
- Improved error messages when a hook script is not executable

## 2.1.306

- Fixed the cursor jumping to the start of the prompt after pasting multi-line text
- Fixed `--print` mode exiting with status 0 after an authentication error

## 2.1.305

- Added `/doctor` output for network proxy configuration
- Fixed wrapped lines in diffs losing their indentation

## 2.1.304

- Fixed a rare crash when two sessions wrote the same settings file at once
- Improved the wording of the rate limit notice

## 2.1.303

- Added the `--quiet-hours` flag to silence desktop notifications between two clock times
- Fixed the model picker forgetting the last choice after an update
- Improved scrolling performance in long transcripts

## 2.1.302

- Fixed tab completion for paths that contain spaces
- Removed a stale warning shown on first launch

## 2.1.301

- Fixed the update check running more than once per day
- Improved the alignment of the session list on narrow terminals
