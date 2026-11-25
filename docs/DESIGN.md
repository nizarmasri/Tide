# Tide design spec

Design notes for Tide. Points, SF Symbols names and SwiftUI components are the source of truth for the UI. "{App}" means Tide.

---

## 1. Principles and anti-patterns

**Principles**
1. **One glance answers it.** The menu bar ring and the popover header tell you whether things are moving and when they'll finish, without reading any row.
2. **Progress is never lost, and never looks lost.** Power cuts, unplugged drives and sleep are normal states, not errors. Never show 0% when data exists on disk, never animate progress backwards, and resume without asking.
3. **Take the movie, leave the junk.** Defaults match how people already use aria2 on the command line: only the main video (`--select-file`), the last folder, and stop when finished (`--seed-time=0`). Accepting an add takes one press of Return.
4. **Native or nothing.** Only system controls, SF Pro, SF Symbols, semantic colours, the system accent and standard shortcuts. Only three custom views: the progress capsule, the piece bar and the schedule timeline.
5. **Calm on top, detail on demand.** Popover → window → inspector → Settings → Engine. Each layer adds detail; nothing advanced appears in the first two.
6. **Say why, offer one fix.** Every state that isn't moving data gives a plain-language reason and at most one action.
7. **Lightweight is a feature.** Under 300 ms from cold launch to a working popover. No spinners for local state, no UI work while nothing is visible, idle CPU near 0%.

**Anti-patterns (what makes download apps feel heavy)**
- Web-app chrome: custom title bars, bundled fonts, custom scrollbars, "settings pages" inside the main window.
- Making the user say what they pasted with URL / Torrent / Magnet tabs. There is one drop target and one paste field.
- Infinite spinners or silent failure when a torrent won't parse. Parse in Rust and fail within 1 s with a sentence and a fix.
- A sidebar of categories for a list that usually holds 1–5 items.
- Dashboards: speed graphs, coloured charts, peer maps, big stat tiles.
- aria2 terms in the main UI: GIDs, exit codes, `active/waiting/removed`, option names.
- Rows that re-sort on live data, digits that roll every second, spinners in the menu bar.
- Notification noise: per-start, per-resume or per-file notifications.
- Confirmations on reversible actions (pause, clear) and none on destructive ones.
- Glass everywhere: glass rows, glass on glass, stacked tinted glass banners.

---

## 2. Information architecture

| Surface | Job | Contains | Never contains |
|---|---|---|---|
| Menu bar item | Glance | Progress ring, state glyph, attention dot, optional speed text | Colour, animation |
| Popover | Daily use: check, add, pause | Active tasks, last 3 completed, Pause/Resume All, Add, Slow Mode, one contextual banner, free space | Files, peers, settings, selection |
| Main window | Manage | Full list in 2 sections, inspector, multi-select, reorder, search | Sidebar, filters, charts |
| Add window | Intake | Item preview, smart file selection, destination, start timing | Per-task advanced options (they live in the inspector) |
| Main window ▸ Search | Find | Results from free public indexes, merged by info hash; files and details of one | Settings, anything that runs before the user presses Return |
| Settings | Policy | 6 panes | Live task data |

**Sidebar: no.** Two list sections ("In Progress", "Completed") plus search replace categories. There is no filter or sort UI; the list order is the queue order.

**Activation**
- By default the app is an accessory app (menu bar only).
- It switches to `.regular` (Dock icon and ⌘-Tab) only while the main window is open, and returns to accessory when the window closes.
- Launching at login shows only the menu bar item. Launching from Finder, Spotlight or the Dock opens the main window.
- Closing the window never quits.

**Settings.** A `Settings` scene: `TabView { Tab(...) }` toolbar tabs, `Form` with `.formStyle(.grouped)`, fixed width 540, height fits the content.

1. **General** (`gearshape`)
   - Open at login
   - Show speed in menu bar (off)
   - Default app for torrents and magnet links [Make Default]
   - Prevent sleep while downloading (on)
   - Ask before quitting with active downloads (on)
   - Notifications: Completed (on), Problems (on), Waiting for drive (on), Sound on completion (on)
2. **Downloads** (`arrow.down.circle`)
   - Default folder: a popup with recent folders and free space
   - File selection: "Only the main video" (on), "Skip extras: samples, images, text files" (on)
   - Watch folder: toggle, folder, "Move added torrents to Trash"
   - Clear completed from list: Never / After 1 Day / After 1 Week
3. **Schedule** (`clock`): download hours, slow mode, pause automatically, keep awake for the schedule (see §8)
4. **Network** (`network`)
   - Speed limits ↓/↑ (Unlimited)
   - Simultaneous downloads (3)
   - Connections per server (16)
5. **BitTorrent** (`point.3.connected.trianglepath.dotted`)
   - After download: Stop Sharing (default) / Seed Until Ratio… / Seed For…
   - Max peers per download (55)
   - Listening port
   - DHT, Peer Exchange and Local Peer Discovery toggles
   - Prefer encrypted connections
   - Extra trackers, inside a disclosure
   - Search: one toggle per source (all on), "Show adult results" (off), and the footnote "Searches go to the sources you turn on." 
6. **Engine** (`gearshape.2`)
   - Status row: green dot, "Running · aria2 1.37.0"
   - "Progress saved every 10 seconds" (deliberate reassurance for the power-cut user)
   - [Restart Engine] and [Show Log]
   - Advanced aria2 options in a disclosure: a monospaced `TextEditor` with a warning footnote

---

## 3. Menu bar status item

**Implementation**
- Use an AppKit `NSStatusItem`, not `MenuBarExtra`: the icon needs drag-and-drop and a right-click menu.
- A transparent `NSDraggingDestination` subview over the button accepts `.fileURL`, `.URL` and `.string`. A hovering drag highlights the button; a drop opens the Add window.
- Left-click toggles the popover.
- Right-click or Control-click opens an `NSMenu`: Pause All / Resume All, Slow Mode, Add from Clipboard, Search Torrents, Open Downloads Window, Settings…, Quit.

**Glyph**
- A custom-drawn template `NSImage` (`isTemplate = true`) on an 18×18 canvas. It's the app icon reduced to a ring plus a centre glyph, and it never uses colour.
- **Ring:** centre (9,9), radius 7, 1.5 stroke, round caps.
  - When tasks exist: a track at 30% alpha, and an arc at 100% alpha from 12 o'clock, clockwise. The arc shows bytes done ÷ bytes selected across all incomplete tasks.
  - When idle: a full ring at 100%.
- **Centre glyph:** 1.5 strokes with round caps, inside a 6×7 box.
- **Attention dot:** a 5pt filled dot at (15,3) with a 1.5pt knockout gap, shown when any task has an error and the centre glyph isn't already "!".

**Centre glyph by priority (first match wins)**

| Priority | Condition | Glyph |
|---|---|---|
| 1 | Any task moving data, fetching metadata, or checking | Down arrow |
| 2 | Any error (nothing moving) | "!" |
| 3 | Waiting for drive or network | Three dots |
| 4 | Scheduled, or outside download hours | Clock hands |
| 5 | Paused (by the user or automatically) | Two pause bars |
| 6 | Just completed | Checkmark for 4 s, then idle |
| 7 | Idle | Down arrow in a full ring |

**Rules**
- Never animate or spin the glyph.
- Redraw only when the glyph changes or progress changes by 2%.
- Speed text is **off by default**, because a display notch hides status items.
- When speed text is on, it shows only while downloading, to the left of the glyph like battery %, 4pt gap. Format "24.6 MB/s" in `monospacedDigitSystemFont(ofSize: 12, weight: .regular)`, right-aligned, at a fixed width measured on "888.8 MB/s" so the menu bar never shifts.

---

## 4. Popover

**Container**
- A borderless `NSPanel` without an arrow, matching Control Center modules, hosting SwiftUI. Background: `NSGlassEffectView`, corner radius 18 (continuous).
- Placed 4pt below the menu bar, centred on the status item, clamped 8pt from the screen edges.
- Closes on an outside click, on Esc, and when the app resigns active.
- **Size:** width 360. Height fits the content: minimum 240, maximum min(600, visible screen height − 40). The list scrolls after 6 active rows; the header and footer stay fixed.
- Everything inside is flat; no glass on glass. Buttons are `.borderless` with a circular hover fill.

```
┌────────────────────────────── 360 ──────────────────────────────┐
│ 24.6 MB/s                                          (+)   (⏸)     │ header 56
│ 2 downloading · done in 1 hr 12 min                              │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ [doc.on.clipboard]  Link on clipboard                   Add  │ │ banner 36 (0–1)
│ └──────────────────────────────────────────────────────────────┘ │
│ [icon32] The.Movie.2024.2160p.UHD…REMUX.mkv              (⏸)     │ row 56
│          ███████████░░░░░░░░░░░░░░░░░░░░░                         │
│          34% · 24.6 MB/s · 1 hr 12 min left                      │
│ [icon32] Show.S01.2160p.WEB-DL…                         (none)   │
│          ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░                         │
│          [externaldrive] Waiting for Media                       │
│ Completed                                             Clear      │ 28
│ [icon24] Other.Movie.2023.2160p…mkv        41.0 GB      (🔍)     │ 36
├──────────────────────────────────────────────────────────────────┤
│ (tortoise)  Media · 412 GB free             (macwindow) (gear)  │ footer 40
└──────────────────────────────────────────────────────────────────┘
```

**Header** (56pt, horizontal padding 16)
- Line 1: 17 semibold, monospaced digits.

| State | Line 1 |
|---|---|
| Data moving | Aggregate speed |
| Paused | "Paused" |
| Outside download hours | "Starts at 01:00" |
| Everything waiting on a drive | "Waiting for Media" |
| Errors only | "1 Problem" |
| All complete | "All Done" |

- Line 2: 11 regular, secondary. A summary such as "2 downloading · done in 1 hr 12 min"; it appends "· Slow Mode" while slow mode is on.
- **Buttons** (28×28 hit area, 15pt medium symbols):
  - `magnifyingglass`: Search Torrents, which opens the main window's Search view with the cursor in its search bar.
  - `plus`: a `Menu` with Add Link…, Open Torrent File…, Import Existing Download…
  - The go/stop toggle: `pause.fill` "Pause All" while data is moving; otherwise `play.fill` "Resume All", or "Start Now" outside download hours.

**Banner** (one at a time, by priority)
1. "Download engine stopped" + Restart (red tint).
2. "Paused on battery power" / "Paused on hotspot" + Resume Anyway (orange tint).
3. "Link on clipboard" + Add (accent tint).

Styling: minimum height 36, radius 10, fill at 12% of the state colour (18% in dark mode), symbol in the state colour, 12pt primary text, `.borderless` action in 12 semibold.

**Clipboard detection:** `NSPasteboard` detect APIs, or type checks that don't read the contents, so the macOS 26 paste-privacy prompt never appears. The contents are read only when the user clicks Add.

**Active row** (56pt)
- Inset 8 from the panel; inner padding 8 horizontal, 6 vertical. Hover fill `primary.opacity(0.06)`, radius 10.
- Layout: [32pt file-type icon from `NSWorkspace`] 10 [text column] 8 [24pt action].
- Text column:
  - Name: 13 medium, one line, `.truncationMode(.middle)`.
  - 5pt gap, a 4pt capsule progress bar, 5pt gap.
  - Status: 11 secondary, monospaced digits.
- Trailing action: the state's single verb (see §7).
- **Click** opens the main window with that task selected and the inspector open. **Right-click** opens the task context menu (§5).

**Completed row** (36pt)
- 24pt icon, name in 13 regular, size, and a `magnifyingglass` button (Show in Finder).
- Shows completions from the last 24 h, at most 3.
- The "Completed" header is 11 semibold secondary, with "Clear" (no confirmation).

**Footer** (40pt, divider above)
- `tortoise` / `tortoise.fill` toggles slow mode; indigo tint when on. Tooltip "Slow Mode (2 MB/s)".
- Free space on the default volume: "Media · 412 GB free", or "Media · Not connected".
- `macwindow` opens the Downloads window.
- `gearshape` is a `Menu`: Settings… ⌘, / About / Quit ⌘Q.

**Empty state**
- The header shows "Downloads" (13 semibold) and only the `plus` button.
- The body is a compact `ContentUnavailableView`: `arrow.down.circle` 32pt, "No Downloads", "Drop a torrent, magnet link or URL here.", [Paste Link], and a link button "Import Existing Download…".

**Drop overlay** (popover and window): fades in over 0.15 s; 2pt accent border inset 8, radius 12, accent fill at 6%, centred `arrow.down.circle` 32pt, "Drop to Add".

**Keyboard**

| Keys | Action |
|---|---|
| ↑ ↓ | Move between rows |
| Return | Open in the window |
| Space | Quick Look (completed only) |
| ⌘. / ⌘/ | Pause / Resume |
| ⌘V | Add from the clipboard |
| Esc | Close |

---

## 5. Main window

**Structure**
- One window, titled "Tide", default 980×600, minimum 640×400. It has two views, **Downloads** and **Search**, switched by a segmented control at the leading edge of the toolbar (⌘1 / ⌘2). Leading, not centred: a centred control squeezes the toolbar so much that the filter field collapses to an icon.
- Each view brings its own toolbar items and inspector. Only one search field is ever on screen: Downloads has the small toolbar filter, Search has a large search bar in its content. Filtering your downloads and searching for torrents never share a field.
- Downloads content: `List(selection: Set<ID>)` in `.inset` style, plus `.inspector(isPresented:)` with `.inspectorColumnWidth(min: 260, ideal: 300, max: 380)`.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ●●● [Downloads|Search] Tide       [+▾] [⏸] [tortoise] [▯] [Filter Downloads]│
│      2 downloading · 24.6 MB/s                                             │
├───────────────────────────────────────────────────────┬─────────────────────┤
│ In Progress                                           │ Inspector (300)     │
│ [32] The.Movie.2024.2160p.UHD.BluRay…REMUX.mkv   (⏸)  │                     │
│      ██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░          │                     │
│      23.2 of 68.2 GB · 24.6 MB/s · 1 hr 12 min left   │                     │
│                                    18 seeds · 42 peers│                     │
│ Completed ▾                                     Clear │                     │
└───────────────────────────────────────────────────────┴─────────────────────┘
```

**Toolbar** (system glass grouping)
- Leading: the Downloads | Search control. Title "Tide". Live `.navigationSubtitle`: "2 downloading · 24.6 MB/s", plus "· ↑ 1.2 MB/s" only while uploading and "· Slow Mode" while it's on.
- Trailing items, in order:
  1. `plus`: a `Menu` whose primary action is Add Link…, with Open Torrent File… and Import Existing Download…
  2. Pause All / Resume All toggle (`pause.fill` / `play.fill`)
  3. Slow Mode (`tortoise` / `tortoise.fill`)
  4. `ToolbarSpacer(.fixed)`
  5. `.searchable` (toolbar placement), prompt "Filter Downloads"
  6. Inspector toggle (`sidebar.trailing`)
- That's 4 buttons plus the filter, besides the view control. Nothing else.

**List**
- **In Progress** holds all incomplete tasks in queue order. Drag to reorder (`.onMove`), which maps to aria2 `changePosition`.
- **Completed** is newest first, collapsible (`Section(isExpanded:)`), with "Clear" in the header.
- Rows never re-sort on live data.

**Standard row** (60pt, padding 12 horizontal, 8 vertical)
- Layout: [32 icon] 10 [text column] [24 action, centred vertically].
- Text column:
  - Name: 13 medium, middle truncation.
  - 5pt gap, 4pt bar, 5pt gap.
  - Status line: 11 secondary, monospaced digits. "23.2 of 68.2 GB · 24.6 MB/s · 1 hr 12 min left", with "18 seeds · 42 peers" right-aligned on the same line for torrents.
- A completed row has no bar. Status "68.2 GB · Today at 07:42"; action `magnifyingglass`.

**Compact rows** (View ▸ Compact Rows; 28pt, one line)
- [14pt state symbol in a 16 slot] [name, flexible] [60×4 bar + "34%" in a 32 slot] [size, 64] [speed, 72] [ETA, 72].
- Numeric columns are right-aligned with fixed widths.

**Selection**
- Standard click, ⌘-click, ⇧-click and ⌘A.
- Double-click or Return: Open a completed task (in its default app); Show Info for an in-progress one.
- A completed row can be dragged to Finder or a player as its file URL.
- The toolbar pause control always acts on everything; menu commands and shortcuts act on the selection.

**Multi-select inspector:** "3 Downloads · 182 GB · 41% overall", [Pause] [Resume] [Remove…], and a shared Speed Limit picker.

**Inspector**
- **Fixed header**
  - 48pt icon.
  - Name: 15 semibold, up to 3 lines, selectable.
  - State symbol and state name, 11pt.
  - A 6pt progress bar, with "34.2%" on the left and "1 hr 12 min left" on the right.
  - A 2×2 stats `Grid`: Downloaded "23.3 of 68.2 GB", Speed ↓/↑, Peers "18 seeds · 42 peers", Limit "None". Labels 11 secondary; values 13 medium, monospaced digits.
- Below it, a segmented `Picker`: **Info | Files | Peers**. HTTP tasks hide the picker and show Info only.
- **Info** (grouped `Form`)
  - Saved To: folder icon, "Movies — Media", reveal button.
  - Speed Limit: Unlimited / 1 / 2 / 5 / 10 / 25 MB/s / Custom…
  - After Download: Use Default (Stop) / Stop / Seed…
  - Start At (only when set).
  - **Pieces:** a 10pt piece bar drawn in a `Canvas`, downsampled to the pixel width. Caption "1,480 of 4,352 pieces · 16 MB each".
  - **Details** (collapsed `DisclosureGroup`): added date; info hash (SF Mono 11, selectable); magnet link [Copy]; trackers (n); created by / comment; aria2 GID and error code (the only place they appear).
- **Files:** the same tree as the Add window, plus a mini bar and % per file. Edits apply immediately (the core pauses, changes `select-file`, then resumes). Footer: "67.9 GB selected".
- **Peers:** summary "Connected to 42 peers · 18 seeds". 28pt rows: IP:port (SF Mono 11), client (secondary, flexible), %, ↓ speed. Re-sorted by ↓ speed every 5 s, without animation.

**Context menu** (`.contextMenu(forSelectionType:menu:primaryAction:)`; labels pluralise, e.g. "Pause 3 Downloads")

| Group | Items |
|---|---|
| 1 | Pause / Resume · Start Now · Start At… |
| 2 | Open · Show in Finder · Quick Look (completed only) |
| 3 | Copy Magnet Link / Copy Link · Speed Limit ▸ · Move to Top / Move to Bottom · Verify Data |
| 4 | Remove… · Remove and Move to Trash… (`role: .destructive`) |

**Remove dialog** (incomplete tasks)
- Title: "Remove 'The.Movie…REMUX.mkv'?"
- Message: "The 23.1 GB already downloaded stays in Movies on Media, so you can import it later."
- Buttons: [Remove] (default), [Remove and Move to Trash] (destructive; moves both the partial data and the `.aria2` to the Trash), [Cancel].
- Removing a completed task from the list needs no dialog. Moving its files to the Trash always confirms.

**Quit dialog:** shown only when tasks are active. "2 downloads will pause and continue when you open {App} again." [Quit] / [Cancel], plus "Don't ask again".

**Keyboard shortcuts**

| Shortcut | Action |
|---|---|
| ⌘N | Add Link… |
| ⌘O | Open Torrent File… |
| ⇧⌘I | Import Existing Download… |
| ⇧⌘F | Search Torrents (Search view, cursor in the search bar) |
| ⌘1 / ⌘2 | Downloads / Search view |
| ⌘V | Paste a link (list focused) |
| ⌘. / ⌘/ | Pause / Resume selected (Transmission convention) |
| ⌥⌘. / ⌥⌘/ | Pause All / Resume All |
| ⇧⌘L | Slow Mode |
| ⌘R | Show in Finder |
| Space | Quick Look |
| ⌘I | Show Info (inspector) |
| ⌘C | Copy magnet or link |
| ⌥⌘↑ / ⌥⌘↓ | Move up / down in the queue |
| ⌫ / ⌘⌫ | Remove… / Remove and Move to Trash… |
| ⌘F | The visible field: Filter Downloads, or the Search bar in the Search view |
| ⌘, | Settings |
| ⌘W | Close window |

---

## 6. Add flow and import flow

**Add window**
- A dedicated `WindowGroup("Add Download", for: AddRequest.ID.self)`: a titled window with the title hidden, width 520, `.windowResizability(.contentSize)`, content margins 20.
- It opens centred, frontmost and key. Return = Download, Esc = Cancel.
- It opens for drops, ⌘V, ⌘N, `.torrent` files opened from Finder, and `magnet:` links.
- Watch-folder items skip the window: they use the defaults and post one notification, "Added from watch folder — only the movie selected".

```
┌─────────────────────────────────────── 520 ─┐
│ [icon40] The.Movie.2024.2160p.UHD.BluRay     │ 15 semibold, 2 lines max
│          Torrent · 5 files · 68.4 GB         │ 11 secondary
│                                              │
│ ┌ Files ───────────────────────────────────┐ │ GroupBox
│ │ [x] [film] The.Movie…REMUX.mkv   68.2 GB │ │
│ │ Skipping 4 extras (214 MB): sample,      │ │ 11 secondary
│ │ 2 images, 1 text file    Show All Files ▸│ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ Save to  [ [externaldrive] Movies — Media · 412 GB free ▾ ]  │
│          (warning line, conditional)         │
│                                              │
│                       [Cancel] [Download ▾]  │
└──────────────────────────────────────────────┘
```

**Input types**
- **Add Link… with an empty field:** a `TextField` "Paste a magnet link or URL" (one link per line is accepted). Once a link is valid, the window turns into the layout for that link. No tabs.
- **URL:** filename and size (or "Size unknown"). No Files box.
- **Magnet before metadata:**
  - The Files box shows a small `ProgressView` and "Getting file list from peers… (6 connected)".
  - Footnote: "You can start now — only the main video will be selected when the list arrives."
  - Download stays enabled. aria2 runs with `--pause-metadata`; the core applies the smart selection and then unpauses.
  - After 30 s with no peers: "No peers yet. It'll keep trying in the background."
- **Several items:** stacked, collapsible cards (icon, name, selected size, smart summary), one shared Save To, and the primary button "Download 3".
- **Unreadable torrent** (reported within 1 s): an inline `exclamationmark.triangle.fill` (red) with "This torrent file can't be read." and, on the next line, "It may be incomplete or damaged. Try downloading it again." Buttons: [Choose Another File…] [Cancel].
- **Duplicate:** the subtitle becomes "Already in your downloads" with a [Show] button, and the primary button is disabled.
- **Existing data at the destination** (same name with an `.aria2`): an accent banner with `arrow.clockwise.circle`, "Found 23.1 GB already here — it'll continue from 34%."

**Smart file selection rules**
- **Single main video:** if one video file (mkv, mp4, m2ts, ts, mov, avi) is at least 50% of the total, select only that file.
- **Several episodes:** otherwise select every video file of 100 MB or more.
- **Never selected by default:** names or folders containing "sample", .nfo, .txt, image files, .url, .exe.
- **Not a video torrent:** select everything.
- **The summary line** is always visible (never behind a disclosure): "Skipping N extras (size): …".
- **"Show All Files"** expands an outline, max height 240, scrolling:
  - Rows: tri-state folder checkboxes, 16pt icon, name 13 regular with middle truncation, size 12 secondary with monospaced digits.
  - Junk rows show their names in secondary text with a 10pt capsule tag ("Sample", "Image", "Text") on a `.quaternary` fill.
  - Footer links: "All · Videos Only · None", and "67.9 GB selected of 68.4 GB".

**Save To** (a `Picker` in menu style)
- Up to 5 recent folders. Each shows a volume symbol (`externaldrive` or `internaldrive`), the folder name, and a subtitle like "Media · 412 GB free".
- An unplugged volume reads "Media · Not connected": dimmed but selectable.
- A separator, then "Choose Folder…".
- **Warnings** (11pt, symbol in the state colour, primary text):

| Condition | Message | Primary button |
|---|---|---|
| Not enough space | "Needs 68.2 GB — Media has 41 GB free." | Disabled |
| FAT32 volume, file over 4 GB | "Media is formatted as FAT32, which can't store files over 4 GB." | Disabled |
| Volume not connected | "Media isn't connected. The download will start when you plug it in." | Enabled, labelled "Add" |

**Start timing**
- The primary control is a prominent `Menu` with a primary action. Default action: Download Now. Menu items: Download At…, Add Paused.
- Download At… reveals a row "Starts at [01:00] · tomorrow": a `DatePicker(.hourAndMinute)` in `.stepperField` style. "Tomorrow" is inferred automatically, and an × removes the row.
- While the row is showing, the primary button reads "Schedule".

**Search view** (main window; the view control, ⌘2, File ▸ Search Torrents ⇧⌘F, the popover's `magnifyingglass`)
```
┌───────────────────────────────────────────────────────────────────────────────┐
│ ●●● [Downloads|Search] Tide                                            [▯]   │
│                        214 results from 4 sources                            │
├─────────────────────────────────────────────────────────┬─────────────────────┤
│ ( 🔍 ubuntu                              ⓧ ) [All Categories ▾] │ Inspector (300)     │
├─────────────────────────────────────────────────────────┤                     │
│ Name                         Size   Seeds  Peers  Added │                     │
│ [box]  ubuntu-26.04-desktop… 6.52 GB  147   108  7 mo ago│                     │
│        The Pirate Bay · Bitsearch                       │                     │
└─────────────────────────────────────────────────────────┴─────────────────────┘
```
- **Search bar:** a native `NSSearchField` at the large control size, full width at the top of the content, with 20 horizontal and 12 vertical padding. The Category menu (All, Movies, TV, Music, Anime, Apps, Games, Books, Other) sits beside it and filters locally. The bar takes focus whenever the view appears. Clearing it returns to the empty state.
- Toolbar: only the inspector toggle. The search state lives as long as the window: switching views keeps it, and closing the window drops it and its downloaded .torrent files. Nothing is created until the Search view first opens.
- **Searching happens on Return only**, never per keystroke: the free sources have per-IP limits.
- **Sources** (free, no key): Knaben (a meta-index: The Pirate Bay, YTS, Nyaa and more), The Pirate Bay directly, Bitsearch (a DHT index, 200 requests a day per IP) and Torrents-CSV. Each has 6 s, a 5xx is retried once, and a source that fails is a quiet note in the subtitle, never an error.
- **Merging:** one row per info hash. Most seeds and peers across sources, the size most of them agree on, the earliest date, the union of trackers (12 at most), and the source names as the row's second line.
- Results appear once, when every source has answered or timed out, sorted by seeds. Rows never re-sort by themselves; column headers sort.
- Subtitle: "214 results from 4 sources", "12 of 214 results…" with a category, plus "· Bitsearch didn't respond" or "· Bitsearch's daily limit is reached".
- **Table** columns: Name (category symbol, 13 medium name, 11 secondary sources line with "In Downloads" and a green check when the hash is already a download), Size, Seeds, Peers, Added (relative). Double-click or Return downloads; context menu: Download / Show in Downloads, Copy Magnet Link, Open on <source>. ⌘C copies the magnet.
- **Inspector:** fixed header (15 semibold name, a 2×2 grid: Size, Peers, Added, Category), then Files and a collapsed Details (info hash, where it was found, uploader, tracker count), then [Copy Magnet Link] and the prominent [Download]. Already downloaded: "Already in your downloads" and [Show].
- **Files** load for the selected row only, 400 ms after the selection rests:
  - The index's list first (The Pirate Bay's names and sizes, or Bitsearch's paths).
  - Then the real .torrent, from the source's own link (Nyaa) or a public cache by info hash. It's used only after the core has read it and its info hash matches. It replaces the list with the full tree and the "Skipping N extras" line.
  - With neither: "The file list arrives when the download starts."
- **Download** opens the usual Add window. With the verified .torrent it shows the real files, smart selection and free space, and starts without waiting for metadata; otherwise it gets the magnet.
- Empty: "Search for Torrents" / "Searches The Pirate Bay, YTS, Nyaa, Bitsearch and more. Free, no account." No results: the system search empty state. Every source failed: "Can't Reach Any Search Source" (or "You're Offline") with [Try Again].

**First run: Welcome window** (480 wide, one screen)
- A 96pt app icon, "Welcome to {App}", and a one-line description.
- Save Downloads To [popup].
- [x] Open torrents and magnet links with {App}.
- [x] Open at login.
- As soon as a folder is chosen, scan it (top level plus one level down) for `*.aria2`.
  - **Found:** a card animates in: `tray.and.arrow.down`, "Found an unfinished download in Movies", "The.Movie…REMUX.mkv — 34% of 68.2 GB", [Import…].
  - **Nothing found:** a link button "Import Existing Download…".
- Primary button: [Get Started].

**Import Existing Download** (sheet or window, 480 wide)
1. `NSOpenPanel`, folders or files: "Choose the folder with your unfinished download, or its .torrent or .aria2 file."
2. Scan, usually under 1 s: "Reading progress…".
3. Review:

```
[icon48]  The.Movie.2024.2160p.UHD.BluRay.REMUX.mkv
          68.2 GB · in Movies on Media

██████████▌░░░░░░░░░░░░░░░░░░░░░   piece bar 10pt (real bitfield from .aria2)
34% already downloaded                              15 semibold, mono digits
23.1 of 68.2 GB                                     11 secondary

[checkmark.circle.fill] Torrent file      The.Movie.torrent
[checkmark.circle.fill] Progress file     The.Movie.mkv.aria2 · saved 2 days ago
[checkmark.circle.fill] Downloaded data   The.Movie.mkv

Files: Only the movie (skipping 4 extras)                         Change…
Continues in place — files stay in Movies on Media.

                                       [Cancel] [Continue Download]
```

**Import variants**
- **No progress file:** an orange `exclamationmark.circle` row: "Progress file missing — {App} will check the data on disk first (about 40 seconds on this drive)", with the time estimated from measured drive throughput. The headline becomes "Progress will be confirmed by a quick check", and the task starts in Checking.
- **Progress file but no torrent:** "Torrent file not found — the file list will be fetched from peers."
- **Several found:** a checklist, each item with a mini bar and %. Primary button "Import 3 Downloads".
- **Nothing found:** `ContentUnavailableView` "No Unfinished Download Here", with [Choose Another Folder…].

**After the import**
- The row appears at 34%, never passing through 0%.
- It gets a one-time accent highlight at 10% that fades over 1.0 s.
- Its status reads "Continuing from 34%" until the first bytes arrive.

---

## 7. State presentation

**Rules**
- Colour appears only on the state symbol and the bar.
- Status text is always `.secondary`, except error rows: `.primary` text beside a red symbol, for contrast.
- Never dim a paused row; dimming reads as disabled.
- Every state has its own symbol and text.

| State | Symbol (colour) | Bar | Status text (popover form) | Row action |
|---|---|---|---|---|
| Downloading | `arrow.down.circle.fill` (accent) | Accent | 34% · 24.6 MB/s · 1 hr 12 min left | Pause |
| Stalled (0 B/s for over 2 min) | Same | Accent | 34% · Looking for peers | Pause |
| Resuming (≤ 10 s) | Same | Accent, at its existing value | Continuing from 34% | Pause |
| Fetching metadata | `arrow.down.circle.dotted` (accent) | Empty track, static | Getting file list · 6 peers | Pause |
| Queued | `hourglass` (secondary) | Gray | Queued · 2nd in line | Start Now |
| Paused | `pause.circle.fill` (secondary) | Gray | Paused · 34% of 68.2 GB | Resume |
| Auto-paused | `battery.50percent` / `personalhotspot` (orange) | Gray | Paused on battery power | Resume Anyway |
| Scheduled / outside hours | `clock` (secondary) | Gray | Starts at 01:00 / Starts tomorrow at 01:00 | Start Now |
| Checking | `doc.text.magnifyingglass` (teal) | Teal, shows check progress | Checking data · 41% · 38 sec left | None |
| Waiting for drive | `externaldrive` (orange) | Gray | Waiting for Media — plug it in to continue | None (resumes on mount) |
| Waiting for network | `wifi.slash` (orange) | Gray | Waiting for network | None |
| Error | `exclamationmark.triangle.fill` (red) | Red, at its value | Not enough space on Media | One fix verb |
| Completed | `checkmark.circle.fill` (green) | Hidden | 68.2 GB · Today at 07:42 | Show in Finder |
| Seeding | `arrow.up.circle.fill` (green) | Green, ratio toward target | Seeding · ↑ 1.2 MB/s · ratio 0.4 of 1.0 | Stop Sharing |

**Behaviour**
- When checking finishes, the bar changes from teal to accent and jumps to the download value without animating.
- A lost network, an unplugged drive and having no peers are **never** errors. They are waiting states that retry automatically.
- After a power cut, a drive that mounts late at login shows Waiting, never Error.

**Error copy**

| Cause | Status line | Inspector explanation | Fix |
|---|---|---|---|
| Disk full | "Not enough space on Media" | "Media needs 44.9 GB more. Free up space, then try again." | Retry |
| Can't create or open the file | "Can't save to Movies" | "{App} doesn't have permission to write to this folder." | Choose Folder… |
| File already exists | "A file with this name is already in Movies" | — | Resolve… (alert: Replace / Keep Both) |
| HTTP 404 | "The server doesn't have this file anymore" | — | Copy Link |
| HTTP auth | "This link needs a login" | — | Copy Link |
| FAT32 write | "Media can't store files over 4 GB" | — | Choose Folder… |
| Bad torrent | "This torrent file can't be read" | — | Choose Another File… |
| Engine crash | Banner: "Download engine stopped" | Restarted automatically; only shown if the restart fails | Restart Engine |
| Unknown | "Something went wrong with this download" | aria2's message under Details | Retry |

**Copy rules**
- Sentence case. Status lines are 45 characters at most, with no final period. Explanations are full sentences.
- Name things the user knows: the drive, the folder, the file. No paths, codes, "aria2" or "RPC".
- Never "Error:", "Failed to", "Oops" or "!".
- Lead with the consequence.
- One fix button, in Title Case, with "…" when it opens a dialog.

**Notifications**
- "Download Complete": "The.Movie…REMUX.mkv is ready in Movies on Media." Action: [Show in Finder].
- "Download Stopped": the plain reason, with [Show].
- "Waiting for Media": once per unplug.
- Nothing for starts or resumes.

---

## 8. Scheduling

**Settings ▸ Schedule: "Download Hours"** (a toggle)

```
              00    03    06    09    12    15    18    21    24
Downloads    [████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]   accent band
Slow Mode    [░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░████████████░░░░░]   indigo band
                                     ▲ now
From [01:00] to [08:00]     (S)(M)(T)(W)(T)(F)(S)
Downloads run 01:00–08:00 every day. Next window opens in 3 hr 12 min.
```

**Timeline control** (the one custom control)
- Two 14pt tracks with a 4pt gap, full row width. Bands have radius 3. Track fill `.quaternary`.
- Hour labels every 3 h: 10pt secondary, monospaced digits, following the locale's 12/24-hour setting.
- A "now" marker: a 1pt `.primary` line with a 5pt triangle.
- Each band has 12pt round knobs at both ends, snapping to 15 minutes. Dragging the band body moves the whole window.
- A window that crosses midnight (22:00–06:00) draws as two segments.
- `DatePicker` fields below for exact values.
- Weekday chips: `Toggle` with `.toggleStyle(.button)`, 24pt circles.
- A plain summary sentence is always shown. When the feature is off, the band is full and labelled "Any time".

**Other settings on this pane**
- Toggle "Keep Mac awake to start downloads on time" (on). Footnote: "Your Mac can't start downloads while it's asleep." It prevents system sleep only while tasks are waiting for the window; the display can still sleep.
- **Slow Mode**
  - Download limit [2] MB/s and upload limit [0.5] MB/s, each a field with a unit picker.
  - "Turn on automatically" enables the second timeline track.
  - The manual toggle (popover footer, toolbar, ⇧⌘L) overrides the schedule until its next change.
  - Slow Mode is always indigo with `tortoise.fill`.
- **Pause Automatically:** "On battery power" and "On Personal Hotspot or Low Data Mode networks" (`NWPath.isExpensive || isConstrained`). Both are off by default.

**The schedule at a glance**
- Menu bar: the clock glyph.
- Popover header: "Starts at 01:00", with Start Now as the go button.
- Rows: "Starts at 01:00".
- Toolbar: the tortoise is filled while slow mode is on.
- Start Now overrides the hours until the window would have ended.

**Per-task Start At…** (context menu, Add window, inspector)
- A time field; today or tomorrow is inferred.
- An explicit per-task time overrides the download hours. If it falls outside them: "Outside download hours — this download will start anyway."

---

## 9. Visual system

**Typography** (SF Pro only; at most 3 sizes per surface)

| Use | Style |
|---|---|
| Popover headline | 17 semibold `.monospacedDigit()` |
| Window, inspector and add titles | 15 semibold (`.title3`) |
| Row title | 13 medium |
| Body and controls | 13 regular |
| Status and secondary | 11 regular (`.subheadline`) secondary |
| Section headers | 11 semibold secondary |
| Hash, IP, advanced options | SF Mono 11 (`.monospaced()`) |

- Every changing number uses `.monospacedDigit()`.
- Inline ↓/↑ are `Image(systemName: "arrow.down")` / `"arrow.up"` at text size, not Unicode arrows.

**Number formatting**

| Value | Format | Examples |
|---|---|---|
| Sizes | `ByteCountFormatStyle(.file)`: decimal like Finder, 3 significant digits | 68.2 GB · 412 GB · 1.21 TB |
| Speed | Same, per second | 24.6 MB/s · 512 KB/s |
| Percent | Integer in rows, one decimal in the inspector | 34% · 34.2% |
| ETA | Abbreviated, from a 10 s EMA of speed, refreshed at most every 2 s; hidden when speed is 0 | 1 hr 12 min left · Less than a minute · 2 days left |
| Times | The system locale | — |

**Colour**
- The system accent is the active colour. No AccentColor asset.
- Semantic colours:

| Colour | Meaning |
|---|---|
| `.green` | Done, seeding |
| `.orange` | Waiting, auto-paused |
| `.red` | Error |
| `.teal` | Checking |
| `.indigo` | Slow mode |
| `.secondary` | Paused, queued, scheduled |

- Progress track: `.quaternary`. No hex values in the UI; the icon is the only exception.

**Materials**
- Liquid Glass only on system chrome: the toolbar, the popover panel and the timeline knobs.
- Rows, cards, banners and the inspector body are flat. Banners use tinted solid fills.
- Never glass on glass.

**Spacing and sizes**
- 4pt grid.
- Margins: windows and sheets 20, inspector 16, list rows 12 horizontal, popover text inset 16 (8 panel inset plus 8 row padding).
- Section spacing: 16 in forms and the Add window.
- Radii: popover panel 18; popover rows and banners 10 (concentric: 18 − 8); cards (import, welcome) 12; drop overlay 12; progress bars capsule.
- Row heights: popover active 56, popover completed 36, window standard 60, window compact 28.
- Bar heights: rows 4, inspector 6, piece bar 10.

**Motion**

| What | How |
|---|---|
| Hover fill | 0.12 s ease-out |
| State symbol change | `.contentTransition(.symbolEffect(.replace))` |
| Row insert/remove | `.smooth(duration: 0.3)`, opacity plus move from the top |
| Popover height change | 0.25 s ease-in-out |
| Banner, drop overlay | Fade, 0.15–0.2 s |
| Completion | One `.symbolEffect(.bounce)` on the checkmark, only if visible |
| Progress fill | `.linear(duration: 1.0)`, forward only, matching the 1 Hz tick, only while visible |

**Must not animate**
- Speed, ETA and percentage text (no `numericText` on live values).
- The menu bar item.
- Row order, or scroll position during updates.
- Backwards progress: snap instead.
- Indeterminate bars: use static tracks.

**Performance:** stop UI polling when the popover is closed and the window is hidden or occluded; poll at 1 Hz while visible.

**Light and dark**
- System colours only. Test both modes plus Increase Contrast.
- File icons come from `NSWorkspace`, so they adapt.
- No pure #FFF or #000 surfaces.

---

## 10. App icon


**The Tide mark** is a disc sliced by two parallel wave cuts into three bands: sky, swell and depth. It reads as a moon over the sea and works down to 16 px. Its geometry lives in `TideMark` and is shared by the app icon and the menu bar glyph:

| Property | Value |
|---|---|
| Cut centres | 0.43 and 0.67 of the disc height |
| Gap | 0.058 |
| Wave amplitude | 0.034 |
| Wave cycles | 1.05 |
| Wave phase | 0.08 |

**App icon** (1024 canvas)
- Body: an 824×824 continuous squircle (radius 185.4) with a diagonal gradient #4338CA → #2563EB → #06B6D4, plus a white sheen fading from 16% to 0% over the top 42%.
- Mark: a 540 pt disc, centred. Band fills, top to bottom: white → #E4F1FF gradient, white 70%, white 42%.
- Shadow: black 22%, blur 30, y +16.
- Dark variant: a #24243A → #0B0D14 body, with the mark in #A5B4FC → #67E8F9.

**Menu bar glyph** (§3 is unchanged except for the drawing)
- An 18 pt template image of the same disc (r 7.5).
- **Idle:** the solid mark with both wave cuts.
- **Any other state:** the disc dims to 32%, and solid "water" fills it from the bottom up to the aggregate progress, with a wavy surface and a 10% minimum.
- **Downloading:** keeps the cuts and shows no symbol; the rising water says it.
- **Paused, scheduled, waiting, problem:** the cuts are dropped, and the state symbol is drawn with a 4.2 pt clear halo so it reads over water or air.
- **Just completed:** the full solid disc with the check knocked out.
- The attention dot is unchanged.

## 11. Accessibility

**Rows**
- `.accessibilityElement(children: .combine)`. Label: the name.
- Value: a spelled-out sentence such as "Downloading, 34 percent, 24.6 megabytes per second, about 1 hour 12 minutes left". Build it explicitly; don't rely on "MB/s" being read out.
- `.accessibilityActions`: Pause/Resume, Show in Finder, Quick Look, Copy Magnet Link, Remove.
- Row bars are `.accessibilityHidden(true)`; the inspector bar carries the value.

**Announcements:** only completion and errors (`AccessibilityNotification.Announcement`). Never speed ticks.

**Status item:** label "{App}", value "2 downloading, 34 percent" (updated on state changes only), help "Show downloads".

**Controls**
- Every icon-only button has `.accessibilityLabel` and `.help()`.
- "In Progress" and "Completed" carry `.isHeader`.
- Popover and list rows are reachable by keyboard, with the system focus ring.

**Custom views**
- Timeline: each band end is an adjustable element (`.accessibilityAdjustableAction`, 15-minute steps) with a value like "1:00 AM". The time fields are an equivalent path.
- Piece bar: label "Pieces", value "1,480 of 4,352 downloaded".

**System settings**
- **Reduce Motion:** no progress tweening, no bounce, insert/remove by opacity only, instant popover resize.
- **Reduce Transparency:** system glass turns opaque automatically. Banners and the drop overlay use an opaque `controlBackgroundColor` with a 1pt stroke in the state colour.
- **Increase Contrast:** the progress track uses full-strength `.separator` and the bar gets a 0.5pt outline. State is never shown by colour alone.

**Contrast**
- All informational text is at least 4.5:1. Never use tertiary or quaternary label colours for information, and never orange, red or teal body text.
- Bar fill against its track: at least 3:1.

---

## 12. Design review checklist (pass/fail on PNG screenshots)

**Render matrix.** Each in Light, Dark, Graphite accent and Increase Contrast:

| Surface | Screens |
|---|---|
| Menu bar item | All 7 glyph states, with and without the attention dot and speed text (@1x and @2x crops) |
| Popover | Empty; mixed states with Completed; banner; drop overlay |
| Main window | Empty; standard rows; compact rows; inspector Info, Files and Peers; multi-select |
| Add window | Torrent default; files expanded; magnet fetching; URL; several items; low space; drive not connected; unreadable torrent |
| Main window ▸ Search | Empty; results; inspector with the full tree; inspector with an index list; files loading; partial failure; category; no results; unreachable |
| Import | Complete; missing progress file; nothing found |
| Welcome | With and without a found download |
| Settings | All 6 panes |
| Dialogs | Remove; Quit |

**Checklist**
1. Only SF Pro and SF Mono; at most 3 text sizes per surface.
2. Every live number uses monospaced digits, and digit columns line up across rows.
3. Names truncate in the middle with the extension visible; nothing clips or wraps inside rows.
4. Every state has its own symbol and text, and all states can still be told apart in grayscale.
5. Colour appears only on symbols, bars, the accent button, the selection and the drop overlay. No coloured body text or row fills.
6. No glass on rows or cards, and no glass on glass.
7. Exactly one prominent button per window or sheet, bottom right, as the default action.
8. Margins: 20 in windows, 16 popover text inset, 12 list rows (40/32/24 px at @2x). Every gap is a multiple of 4.
9. Each row's title, bar and status text share one left edge, and the popover header lines up with the row text.
10. Row heights stay the same across states: 56 / 36 / 60 / 28.
11. Units: decimal, a space before the unit, 3 significant digits, integer percentages in rows. No "MiB", no "68.20 GB".
12. No aria2 terms (GID, codes, `active/waiting`, option names, "RPC") outside Engine and Details.
13. Every error row has a plain reason (≤ 45 characters, sentence case, no "Error", "Failed" or "!") and exactly one fix action.
14. Waiting-for-drive, imported and resumed rows name the volume and show the existing progress, never 0%.
15. The Add window shows the smart selection summary, the selected size and the free space without expanding anything.
16. The menu bar glyph is monochrome in every state, legible at 1x, and each state is recognisable. With speed text on, the width doesn't change.
17. Dark mode: no pure white or black surfaces, no light-mode leftovers, separators visible but subtle.
18. Under the Graphite accent, every accent element recolours; nothing stays blue except the app icon.
19. Under Increase Contrast, progress tracks are clearly visible and secondary text is readable.
20. Empty states have one symbol, one title, a description of one line at most, and at most two actions.
21. Title Case for buttons, menus and window titles; sentence case for status and descriptions; "…" on actions that open a dialog; no "!".
22. In the Remove dialog the default is the non-destructive Remove, the Trash option is red and not the default, and the message gives the size and the drive.
23. The toolbar has at most 4 buttons plus search, all icon-only SF Symbols, and the subtitle shows live totals.
24. The popover is exactly 360 wide with no horizontal scroll. It scrolls only past 6 active rows, and the footer is always visible.
25. The app icon reads clearly at 16, 32, 128, 512 and 1024 px, and the Tide mark (disc plus two wave cuts) matches the idle menu bar glyph.
