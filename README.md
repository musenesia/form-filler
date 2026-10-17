# Form Filler

A Flutter desktop app (Windows, macOS, Linux) that uses Playwright to fill in
forms on websites you are authorized to use. You define **fill profiles** —
a target URL plus an ordered list of steps (go to, fill, click, select, …) —
and the app runs them through a real Chromium browser, showing a live log
and saving screenshots.

Playwright has no Dart SDK, so the app ships with a small Node.js runner
(`runner/`) that does the browser automation. The Flutter UI starts the
runner as a subprocess and streams its progress.

## Prerequisites

| Requirement | Notes |
|---|---|
| Flutter SDK 3.x | https://docs.flutter.dev/get-started/install |
| Node.js 18+ | https://nodejs.org — the app finds `node` on your PATH, or set a custom path in Settings |
| Desktop support enabled | Run once: `flutter config --enable-linux-desktop --enable-windows-desktop --enable-macos-desktop` |
| Linux build tools | `clang`, `ninja`, `cmake`, `pkg-config`, GTK 3 dev files. Debian/Ubuntu: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev` |

## Setup

```bash
# 1. Flutter packages
flutter pub get

# 2. Runner dependencies + browser
cd runner
npm install
npx playwright install chromium
cd ..
```

## Run

```bash
flutter run -d linux    # or: windows, macos
```

Open Settings any time to run the preflight checks (Node found, runner
dependencies installed, Chromium downloaded). Each check has a one-click
fix button.

## Usage walkthrough

1. **Create a profile** — give it a name and the target page URL.
2. **Scan the page** — in the profile editor, tap *Scan page for fields*.
   The app loads the page headlessly and lists every input, select,
   textarea and button it finds, with a suggested CSS selector. Tap
   *Add as fill step* on the rows you need (or *Add all*).
3. **Edit steps** — reorder, change selectors, pick actions:
   `goto, fill, type, click, select, check, uncheck, press, waitForSelector,
   waitForTimeout, screenshot, dump`.
4. **Log in once (optional)** — for sites that need authentication, open
   *Login sessions* (key icon), tap *Log in* next to the profile, sign in
   normally in the browser window that appears, then click
   *Done — save session* in the app. The session is saved locally and
   reused on every run — your password is never stored.
5. **Run** — tap *Run* on the profile. Watch the live log; on failure you
   get the failing step and a screenshot. On success you can review the
   final screenshot. Every run is appended to *History*.

5. **Run** — tap *Run* on the profile. Watch the live log; on failure you
   get the failing step and a screenshot. On success you can review the
   final screenshot. Every run is appended to *History*.
6. **Batch run (optional)** — attach a CSV or XLSX file in the profile's
   *Data file* section, use `{{ColumnName}}` placeholders in step values,
   then tap the *Batch run* button. The app fills the form once per data
   row, with a live per-row status list. See below.

## Data-driven batch runs

Attach a **CSV** or **Excel (.xlsx)** file to a profile (profile editor →
*Data file (batch runs)*). The first row must contain column headers.
Anywhere a step value, selector or URL can go, you can write a placeholder
like `{{FirstName}}`, `{{Email}}`, `{{OrderId}}` — it is replaced with that
row's value before the row runs.

- The editor previews the first 5 rows and shows a **first-row preview** of
  your steps with placeholders substituted, so you can sanity-check the
  mapping before running.
- In the step editor, the value field has a small table button that inserts
  `{{ColumnName}}` at the cursor.
- Missing columns are kept as literal text and reported as warnings, so a
  typo doesn't silently blank a field.
- The batch screen lets you choose a start row, a max row count, a random
  pause between rows, and whether to stop on the first failed row.
- Per-row statuses are shown live: `ok`, `failed`, or `blocked_captcha`.
  Results (including `results.jsonl` and `summary.json`) are saved under the
  app-support directory's `batch_results/` folder, which you can open from
  the summary card.

Keep batch sizes and pacing reasonable — a sudden burst of hundreds of
submissions is exactly what gets accounts flagged, placeholders or not.

## Human-like execution (optional)

Each profile has a **Human-like execution** toggle, and Settings holds the
**Humanization defaults** applied to new profiles:

- Random pause between steps and per-keystroke typing delays
- Human-like mouse movement (stepped, curved paths) instead of instant jumps
- Stealth evasions that patch common automation fingerprints
  (via `playwright-extra` + the stealth plugin)
- Optional real Chrome instead of bundled Chromium, plus custom
  viewport, user agent, locale and timezone

**Be honest with yourself about what this does:** these techniques only
reduce the chance of tripping *naive* bot checks (instant fills, perfectly
straight mouse paths, headless fingerprints). They do not make automation
undetectable, and they do not protect you from rate limits, behavioral
analysis, or a site deciding your account is misbehaving. If a site's terms
forbid automation, humanized or not, don't automate it — and keep volumes
and pacing at a level a real person could plausibly produce.

## CAPTCHA policy

Form Filler **never solves or bypasses CAPTCHAs automatically**. When a
CAPTCHA is detected (after page loads, and before submit clicks):

- In **headed** runs, the app waits up to 5 minutes for **you** to solve it
  in the browser window, then continues automatically.
- In **headless** runs it can't be solved by hand, so the run/row is marked
  `blocked_captcha` and the batch moves on to the next row.

### Step actions reference

| Action | Needs | Does |
|---|---|---|
| `goto` | `url` | Navigate to a URL |
| `fill` | `selector`, `value` | Set an input/textarea value (clears first) |
| `type` | `selector`, `value` | Type character-by-character (triggers key events) |
| `click` | `selector` | Click an element |
| `select` | `selector`, `value` | Choose a `<select>` option by its value |
| `check` / `uncheck` | `selector` | Toggle a checkbox/radio |
| `press` | `key` (+ optional `selector`) | Press a keyboard key, e.g. `Enter` |
| `waitForSelector` | `selector`, `timeoutMs` | Wait until an element appears |
| `waitForTimeout` | `value` (ms) | Fixed pause |
| `screenshot` | `value` (path, optional) | Capture the page |
| `dump` | `selectors` (list) | Read values back (used for verification) |

Selectors default to CSS; choose `xpath` or `text` per step when needed.

## Where your data lives

Everything stays on your machine, under the app-support directory
(`~/.local/share/form_filler/` on Linux, `%APPDATA%\form_filler\` on
Windows, `~/Library/Application Support/form_filler/` on macOS):

- `profiles.json` — your fill profiles
- `sessions/<profileId>.json` — saved login sessions (cookies)
- `screenshots/` — run screenshots
- `batch_results/` — per-batch job JSON, `results.jsonl` and `summary.json`
- `runs.jsonl` — run history

`sessions/`, `screenshots/` and `node_modules/` are git-ignored. Never
commit session files — they grant access to your accounts.

## Security note

Only automate websites you are authorized to use, and respect each site's
terms of service. Form Filler never sends your data anywhere: there is no
server, no analytics, no cloud sync.

## Troubleshooting

- **"node not found"** — install Node.js 18+, or set the full path to the
  `node` executable in Settings.
- **"Playwright browsers not installed"** — run `npx playwright install chromium`
  inside `runner/` (or tap *Install Chromium* in Settings).
- **Login window doesn't appear** — `login.js` needs a display. On headless
  Linux servers it can't open a window; use it on your desktop machine.
- **A step fails with "waiting for selector"** — the page structure changed.
  Re-run *Scan page for fields* and update the selector.
- **Slow pages** — raise `timeoutMs` on the step, or insert a
  `waitForSelector` step before interacting.
