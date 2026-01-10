# Features

## Advanced text selection (DO NOT IMPLEMENT YET)

It should be possible to select text (and copy it). It should work like this:
- Select text within a line by clicking and dragging the mouse. This uses native macOS selection. If the mouse is released outside the line, the selection should extend to the next line by entering "line mode".
- Line mode is not the native macOS selection. It selects entire lines only, "snapping" to the nearest line boundaries as it were.
- Entering line mode unsets the native macOS selection.
- When in line mode, further dragging the mouse should extend the selection to the nearest line the mouse pointer is over.
- Clicking anywhere on text will exit line mode and go back to normal selection mode, unsetting the selection.
- Clicking in the gutter will select that entire line.
- Shift-clicking in the gutter will select lines from the current line to the line where the mouse is clicked.
- Mouse-down in the gutter and then drag will select lines from the current line to the line where the mouse is over.
- When using the copy function, it should copy the selected text to the clipboard no matter what the mode is.
- Text in the gutter must not be selectable as native macOS selection.
- When the panel has new lines appended to it, the selection must be preserved perfectly, un-influenced by the new lines.
- When the panel is scrolled, the selection must be preserved perfectly, un-influenced by the scroll.
- When the panel is resized, the selection must be preserved perfectly, un-influenced by the resize.

## Filter bar

* Hitting Cmd+E should open a filter bar for the focused panel, under the title bar.
* The "filter bar" is a UI that is a single text input field with a monospace typeface in the same size as the panel text.
* The filter bar should be hidden by default and only appear when the user hits Cmd+E.
* Typing in the filter bar will cause all the lines in the panel to be filtered instantly by regular expression. Use a short debounce (50ms) to avoid filtering on *every* keystroke.
* The filter is regexp syntax, using the standard macOS regexp syntax (NSRegularExpression).
* The filtering should be case insensitive.
* The regexp must be applied to individual lines, not across lines, and matches if the regexp matches anywhere inside the line, no anchoring.
* An empty input is the same as no filter. We can also treat ".*" as no filter for optimization purposes.
* Hitting escape key while the filter bar is open will close it.
* Hitting Cmd+E again while the filter bar is open will not do anything, it's not a toggle.

## HTTP API

- The command line tool will communicate with the main app via a local HTTP API on `localhost` on a random high port (e.g. 49152+).
- The app will start an HTTP server on launch, but there is a setting to disable it. It is enabled by default.
- The app will store the URL in a well-known file in the user's Application Support directory, `~/Library/Application Support/Proceed/client.json`.
- The HTTP API will be a simple REST API with JSON payloads:
  - `POST /processes`: Start a new process. Request body contains process settings.
  - `PATCH /processes/{id}`: Update process settings.
  - `POST /processes/{id}/stop`: Stop the process.
  - `POST /processes/{id}/restart`: Restart the process.
  - `GET /processes`: List all processes.
- The app shows a "HTTP API: <url>" or "HTTP API: disabled" pill in every title bar.

## Command line tool

- We will have a command line tool called "proceed", which is included in the built .app.
- The command line tool can be used to start/stop/restart processes from the terminal.
- The command knows where Proceed stores settings, and automatically reads the port to make a URL.
- All commands also take a --url flag to override the URL to connect to.
- The command line tool will have the following commands:
  - `proceed start [flags] [--] <command line>`: Start the process. Prints the process ID to stdout.
    - `<command line>`: The command line to run, including arguments. It's treated like the app already treats command lines.
    - `--id <id>`: Set a custom ID for the process. If not provided, a UUID will be generated. Must be unique at the time of creation. The app will error if a process with the same ID already exists.
    - `--cwd <path>`: Set the working directory for the process.
    - `--name <name>`: Set the display name for the process.
    - `--auto-restart`: Enable auto-reload for the process.
    - `--include <pattern>`: Add an include pattern for auto-reload.
    - `--exclude <pattern>`: Add an exclude pattern for auto-reload.
    - `--shell <shell>`: Optional shell override. If not provided, the app's default shell will be used.
  - `proceed update [flags] <id>`: Change process settings.
    - `<id>`: The ID of the process to update.
    - `--name <name>`: Change the display name for the process.
    - `--command <command line>`: Change command line for the process. Causes a restart if changed.
    - `--cwd <path>`: Change the working directory for the process. Causes a restart if changed.
    - `--auto-restart [true|false]`: Enable or disable auto-restart for the process.
  - `proceed stop <id>`: Stop the process with the given ID.
  - `proceed restart <id>`: Restart the process with the given ID.
  - `proceed list`: List all managed processes with their status.

## Focus

- Clicking anywhere inside the panel will focus the text view.
- When the text view is focused, it should respond to standard keyboard keys such as arrow keys (scroll up/down), cmd+up/down, etc.
- The native macOS focus outline should not be shown.

## Automatic reload on changes

* "Auto reload" is a new feature.
* When enabled, it will monitor files in the working directory for changes using the native macOS file event API.
* This is disabled by default.
* When a file is changed that matches the inclusion/exclusion rules, and the process is running, the process is restarted.
* The user can set a debounce time (default 500ms) for the auto-reload in the global settings, to avoid multiple restarts in quick succession.
* The user can enable/disable it via a toggle for each process under the process settings.
* For each process's edit dialog, there is an UI to include or exclude list by glob pattern matches against the file name relative to the working directory. Inclusions and exclusions are applied to the auto-reload monitoring. For example, `**/*.js` includes all JavaScript files in all subdirectories.
* By default, there are no include or exclude patterns, meaning all files are monitored.
* Includes and excludes support standard glob patterns: `*`, `**`, `?`, character classes like `[abc]` and ranges like `[a-z]`.
* Exclusions take precedence over inclusions. For example, if the user includes `**/*` but excludes `node_modules/**`, changes in `node_modules` are ignored.
* There is a global include/exclude list, too, in the settings panel. The per-process include/exclude patterns are applied on top of the global ones, i.e we APPEND the per-process patterns to the global patterns to form the final include/exclude lists.
* The global settings has some defaults for the global include/exclude patterns. The defaults are:
  - Include: `**/*`
  - Exclude: `node_modules/**`, `*.log`, `.git/**`, `*.pyc`, `__pycache__/**`, `*.o`, `*.class`, `dist/**`, `build/**`, maybe some other standard ones you can think of?

## Font

* The font used in the panel should be a monospaced font by default.
* The user should be able to change the font used in the panel via a settings menu.
* The font size should also be adjustable via the settings menu.
* The default font size should be 12pt.

## Auto restart

* If a process exits with a non-zero exit code, the app can automatically restart it.
* There should be a global setting to enable/disable auto-restart. It is off by default.
* There should be a per-process setting to enable/disable auto-restart. It is "auto" by default, meaning it follows the global setting.
* There is a delay before the next restart attempt. The delay is 1 second by default, but increases exponentially with each failed attempt, up to a maximum of 1 minute. The min/max is configurable in the global settings.
* When we are delaying before the next restart, we show a live timer "Restarting in X seconds..." instead of the normal run timer.
* If the process exits with a zero exit code, no auto-restart is attempted.
