# susurrus

A native macOS music library and player (SwiftUI + AVAudioEngine).

It plays music from anywhere the Mac can see it: the internal disk, an external drive, or a
network share (SMB/NAS). Local files are played in place; for slow network shares there are a few
extras, described under [Playback from a network share](#playback-from-a-network-share).

## Build, run, test

Needs macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
scripts/bundle.sh
```

```bash
open "build/susurrus.app"
```

```bash
scripts/test.sh
```

`scripts/test.sh` builds and runs the swift-testing suites. With only the Command Line Tools,
`swift test` builds them but SwiftPM's helper never runs them, so the script loads the test bundle
with a tiny runner (`scripts/testrunner/main.swift`). Pass swift-testing flags through, e.g.
`scripts/test.sh --filter Player`. The player tests play generated tones through the real audio
engine at zero volume. The tag-writing tests write only to generated files in a temp folder.

To try a build without touching your real library, set `SUSURRUS_SUPPORT_DIR` to a scratch folder
(it stands in for `~/Library/Application Support`; such a build also keeps its own Soulseek
password in the keychain).

## Releases and updates

Installed copies update themselves with [Sparkle](https://sparkle-project.org): they read
`appcast.xml` from the latest GitHub release (daily, or **susurrus ▸ Check for Updates…**) and only
install a zip whose EdDSA signature matches the public key in `scripts/bundle.sh`.

To release, tag and push; [`.github/workflows/release.yml`](.github/workflows/release.yml) builds,
signs and publishes the release:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The version shown in the app is the tag; the build number is the commit count.

The private signing key lives in the login Keychain (Sparkle's `generate_keys --account susurrus`)
and, for the workflow, in the `SPARKLE_PRIVATE_KEY` repository secret. Builds are ad-hoc signed,
not notarized, so the first copy downloaded by hand needs its quarantine flag cleared before it
opens (updates installed by Sparkle don't):

```bash
xattr -dr com.apple.quarantine /Applications/susurrus.app
```

## Features

**Library**
- **Add to Library** (⌘O, or drag files/folders onto the window) and **watched folders**
  (Settings ▸ Library), rescanned at launch, when a volume mounts, and every 30 minutes. Tags are
  read with AVFoundation; untagged files fall back to `Artist/Album/NN Title` folder layout. Adds
  made while a scan runs wait their turn. A rescan also re-reads the files another app changed
  since they were read (their date or size differs, which comes with the folder listing): tags the
  file has replace the library's, while tags it lacks, or ones only guessed from its name, leave
  the library's alone, since they can be edits that were never written into the file. Files that
  can't be read as audio are remembered and left alone until they change.
- **Activity**: whatever runs in the background (adding files, writing tags, detecting BPM or
  keys, finding covers, checking for missing files, imports) shows as a progress ring in the
  toolbar on every pane; click it for each job's progress and a Stop button.
- **Notices**: errors and import summaries appear in a corner of the window instead of in dialogs,
  so the mixer stays usable while they're up; errors stay until dismissed, the rest fade. Open and
  save panels don't block the window either.
- Views: All Tracks, **Albums** (cover grid), **Artists** (see below), **Browse** (Genre → Artist →
  Album columns).
- Built-in lists: **Recently Added** and **Recently Played** (last 30 days), **History** (every
  play, newest first, seeded with each track's last play on upgrade; right-click ▸ Clear
  History), **Duplicates** (same artist and title ignoring case/accents/punctuation, lengths
  within 2 s, grouped together) and **Missing Files** (only shown when there are some).
- Search across title/artist/album/genre/composer, ignoring case and accents ("bjork" finds Björk;
  every word must match; `-word` excludes,
  `"quoted phrases"` stay together) with field scopes: `artist:`, `title:`, `album:`,
  `albumartist:`, `genre:`, `composer:`, `comment:`, `grouping:`, `kind:flac`, `file:`;
  numbers `bpm:120-128`, `rating:>=4`, `year:<1990`, `plays:0`, `track:`, `disc:`, `bitrate:`,
  `time:>5:00`; dates `added:30d` (in the last 30 days), `played:>1y` (not in the last year;
  units d/w/mo/y); keys `key:8A` or `key:Am`, and `key:~8A` for every key that mixes with 8A.
  Any scope can be negated (`-genre:techno`).
- **Stats** (sidebar): listening time, plays, different tracks and skips for the last 7 days,
  30 days, 12 months or all time; top 10 artists, albums and tracks by time listened (click an
  artist to open their page, double-click anything to play it); listening by hour of day and
  average per weekday; a GitHub-style calendar of the last 12 months; and the most skipped
  tracks. Every listen is logged with the time actually spent playing (pauses and waiting for
  a network share left out) and how it ended: finished, **skipped** (moved on before the last 10 s, or
  last 10% of a short track) or stopped. Listens under a second aren't kept. Plays from before
  the log existed count their track's length, and the view says so. Skip counts are searchable
  (`skips:>2`) and there's an optional Skips column. Clear History also clears the log.
- **Artists** (sidebar, right-click a track or album ▸ Go to Artist, or click the artist in the
  now-playing bar): every artist and album artist in the library (spellings that differ only in
  case, accents or a leading "The" are merged), filtered by the search field. An artist's page
  shows their albums in the library (and ones they appear on), their most played tracks, and,
  looked up without an account or key:
  - **MusicBrainz**: the matching artist (by name; when several share it, the one whose
    discography overlaps the library most; **Not them?** picks another and is remembered), type,
    country, years, genres and links, plus the **discography** (albums and EPs, or everything)
    with each release marked **In library** (title match ignoring case, punctuation and edition
    notes like "(Deluxe Edition)") or offered as **Search Soulseek** / add to the Soulseek
    **Wishlist**. "Missing only" narrows it to the gaps.
  - **Wikipedia**: the summary and photo (through the artist's Wikidata link).
  - **ListenBrainz**: similar artists; the ones in your library are highlighted and open their
    page, the others offer a Soulseek search or wishlist entry.

  Responses are cached for two weeks in `~/Library/Caches/susurrus/ArtistInfo` (a stale copy is
  used when offline), and MusicBrainz requests are spaced a second apart as it asks
  (`Metadata/ArtistInfoService.swift`).
- **Go to Current Track** (⌘L, or click the title in the now-playing bar) selects and centers the
  playing track, switching to All Tracks if the current list doesn't have it.
- Track list: right-click the header to show/hide columns (extra ones: Album Artist, Composer,
  Grouping, Comment, #, Disc, Last Played, Kind, Bit Rate, Sample Rate, Size); type to jump to a
  row in the sorted column (title otherwise).
- **Missing files**: every file is checked in the background a minute after launch, and the files
  on a volume whenever it mounts or unmounts (File ▸ Check for Missing Files to run it now). Each
  folder is listed once rather than every file asked for: one round trip per folder on a share. Missing tracks are
  dimmed with a ⚠; tracks on an unmounted volume are dimmed with a drive icon instead (one check
  per volume, not per file). Files that moved but still resolve through their bookmark get their
  path fixed silently. **Locate File…** (Track menu or right-click) relinks a missing track and
  also finds its missing neighbours in the chosen file's folder.
- **Remove from Library…** (⌥⌘⌫, right-click, or File ▸ Remove Missing Tracks from Library…)
  deletes tracks from susurrus's database after a confirmation. The files are never touched.

**Editing** (saved to the susurrus database; optionally also written into the files, see below)
- **Get Info** (⌘I) for one or many tracks; mixed values (shown as "Mixed", the rating too) stay
  untouched unless changed, and emptying a Mixed field clears it on every track.
- The right-click menu is the same in the track list, an album's tracks (Albums, artist pages) and
  Stats; album covers share their own. Track menu commands act on what's selected in the list on
  screen, so switching views clears the selection.
- Space plays and pauses anywhere in the window except while typing; ⌘F goes to the search field,
  which shows on the panes it filters (tracks, albums, artists, browser).
- Ratings: click stars in the table, Track ▸ Rating, or ⌘0–⌘5.
- Playlists: new (⌘N, with the name ready to type), from selection (⇧⌘N), folders, rename, delete, drag tracks onto a
  playlist, drag playlists into folders, reorder by dragging rows (in playlist order),
  remove (⌘⌫).
- **Smart playlists** (⌥⌘N): native rule editor with a live match count.
- **Undo/Redo** (⌘Z/⇧⌘Z) for Get Info edits, ratings, and every playlist change: add, remove,
  reorder, rename, move, create, edit smart rules, and delete (a deleted folder comes back with
  all its playlists). Removing tracks from the library and background BPM detection aren't
  undoable.
- **Detect BPM** (Track menu or right-click): fills in the BPM of selected tracks that have none
  (or re-detects them, when every selected track already has one), a few files at a time in the
  background with progress in the window subtitle. Results are saved like Get Info edits, so
  they're written into the files too when that's on. There's a BPM column in the track list.

  Lightweight on purpose (`Library/BPMDetector.swift`): it reads ~30 s from the middle of the
  file's audio — for MP3 and FLAC just that byte range (≈1.2 MB / ≈3 MB, cut at a frame
  boundary, past any embedded cover art), since AudioToolbox would otherwise read the whole file
  to seek, which is slow over a network share — mixes it to mono at ~11 kHz, and takes the
  strongest periodicity of a spectral-flux onset envelope (~10 ms of CPU per track; reads took
  ~1 s each from a slow network share). Tempos are folded into 70–140 BPM, the convention nearly
  all existing BPM tags in the test library followed. On 319 randomly picked tagged tracks it
  agreed with the tag (within 2%) on 80%, and on 84% if half/double/3:2 time counts; 6% had no
  clear beat and are left empty.
- **Detect Key** works the same way and fills a Key column (Camelot and standard notation,
  sorted round the Camelot wheel; editable in Get Info). It reads a minute from the middle of the
  file, builds a chromagram (55 Hz–1.8 kHz) and picks the major or minor key whose
  Krumhansl–Kessler profile fits best (`Library/KeyDetector.swift`). Keys are read from and
  written to ID3 `TKEY` and FLAC `INITIALKEY`; MP4 files have no standard key item, so keys are
  read from them but not written. It's checked against generated chord progressions, not yet
  against a tagged library, so treat it as a first guess.
- **Look Up Album on MusicBrainz…** (⇧⌘L, Track menu, or right-click a track or album) matches
  the selected tracks (one track stands for its album) to a MusicBrainz release. It searches by
  the artist and album the tags agree on, or the folder name ("Artist - Album (2003) [FLAC]"),
  fetches the track lists of the closest few releases, and pairs each file with a release track
  by title, length and track number (from the tags or a "1-03 Title" file name). A release whose
  tracks all pair up with lengths within 5 s gets a ✓; otherwise you see how far off it is and
  which files didn't fit. A pasted MusicBrainz release link picks one by hand. Pick what to
  apply (titles, artists, album and year, track and disc numbers, cover): tags are saved like
  Get Info edits (undoable), the year is the release group's first one, and a Various Artists
  release marks the tracks as a compilation (`Library/ReleaseMatcher.swift`).
- **Covers** come from the [Cover Art Archive](https://coverartarchive.org) (at most 1200 px;
  bigger ones are scaled down). A fetched cover shows at once (it's kept in
  `~/Library/Application Support/susurrus/Covers` and outranks embedded art), and with "Write
  tags to files" on it's embedded in the files too (see below). **Find Missing Covers** (Track
  menu or right-click, or File ▸ Find Missing Covers for All Albums) looks for each album with
  no cover (embedded, fetched, or a cover.jpg/folder.jpg/front.jpg next to the files, which
  susurrus now also shows) and takes the cover of the MusicBrainz release group with exactly
  that title by that artist, in the background with progress in the subtitle. With "Write tags to
  files" on it first asks whether to embed the covers too, since that rewrites every track of each
  album that gets one.

**Import and export** (File menu; nothing here reads audio, it all comes from the database)
- **M3U playlists**: **Export Playlist…** (File menu, or right-click a playlist) saves a playlist,
  a smart playlist's current tracks, or everything in a folder as M3U8 (`#EXTM3U` with
  `#EXTINF` length and "Artist - Title" lines), with paths **relative to the playlist file** or
  **absolute** (relative paths fall back to absolute for files on another volume). **Import
  Playlist…** (or drag `.m3u` / `.m3u8` files onto the window) makes a new playlist named after
  the file: entries are matched to library tracks by path (also when the case or accent
  encoding differs, `file://` URLs, relative and Windows-style paths), files that exist but
  aren't in the library are added, and a summary lists how many matched, were added and
  weren't found. Imported from a folder's right-click menu, it lands in that folder.
- **Import from Apple Music…** reads a library exported from Music or iTunes (File ▸ Library ▸
  Export Library…, a `Library.xml`; dropping one on the window works too). Tracks are matched by
  path, and a preview shows what would change before anything does, with the option to add the
  files that are on disk but not in the library. It only fills gaps or brings values forward:
  ratings only where susurrus has none (ratings inherited from the album are ignored), the
  higher play count (adding them would count plays from before the switch twice), the later
  last played and the earlier date added. Playlists and folders are recreated inside a new
  **Apple Music** folder; the whole-library and media-kind lists (Library, Music, Downloaded,
  Podcasts…) are skipped. Skip counts stay susurrus's own (they come from its listen log).
  Everything goes into susurrus's database only, never into the files, and one **Undo** puts it
  all back (tracks it added stay in the library, as with Add to Library).
- **Export Rekordbox XML…** (or right-click a playlist ▸ Export for Rekordbox…) writes the
  whole library or the chosen playlists and their tracks in Rekordbox's `DJ_PLAYLISTS` format:
  tags, size, length, BPM, key (as Rekordbox writes it: Am, F#, Ebm), rating (51 per star),
  play count, date added and a `file://localhost/` location, with the playlist folders as
  they are in the sidebar (smart playlists as their current tracks). Tracks that have been on a
  mixer deck also get their beat grid (a `TEMPO` with the fitted tempo and first beat); the
  grids are remembered in `BeatGrids.json` next to the library, so the library isn't analysed
  on export. Load it in Rekordbox under Preferences ▸ Advanced ▸ rekordbox xml.
- Exports are written to a temp file next to the target and renamed over it, so a failed export
  never leaves half a file.

**Playback**
- Gapless playback; shuffle (⌥⌘S), repeat off/all/one (⌘R).
- **Up Next** panel (⌥⌘U): Play Next (⌥↩), Add to Queue (⌥⇧↩), reorder, remove, jump.
- Play counts and last-played are recorded once half a track (or 4 minutes) has actually been
  heard: seeking ahead, or resuming a track restored past its middle, doesn't count one.
- 10-band **equalizer** with presets (⌥⌘E).
- Two-deck **mixer** (⇧⌘M) for blending tracks by hand: load a deck from the track menu (⌥⌘1 / ⌥⌘2)
  or by dragging a track onto it. Equal-power crossfader, auto crossfade over 4–32 s (⇧⌘X),
  3-band EQ with kills, channel faders, tempo ±8% with hold-to-nudge and BPM match, cue point,
  and a loudness overview to click-seek in. Knobs, faders, tempo and the crossfader also follow
  the scroll wheel. **Continue in Mixer** moves the playing track onto a deck at the same spot.
  The mixer and the queue player take turns: starting one pauses the other. There's one output,
  so no headphone pre-listen.
  - **Beats** (⌃⌘B): both decks close up, one above the other, scrolling past a shared playhead
    with each track's beat grid drawn on, and how far apart the beats are while both play. The
    grid is fitted to the track's onsets when the deck loads it (tempo to 0.01 BPM, starting from
    the tag). Paused, drag a strip to put a beat under the playhead before setting the cue.
  - Each deck shows its key as it sounds at the current tempo (±8% can move it a semitone), with
    a warning when it clashes with the other deck's. Tracks without a BPM or key get the ones the
    deck worked out.
  - The **Mixer** menu plays and cues each deck from the keyboard (⌃⌘1 / ⌃⌘2, add ⌥ to cue) and
    moves the crossfader (⌃⌘← / ⌃⌘→).
  - Deck plays count and show up in History and Stats. Auditioning a track or mixing it out
    early isn't counted as a skip.
- Output device picker and AirPlay button in the now-playing bar.
- Media keys, Control Center / Now Playing widget, headphone buttons.
- Menu bar mini-player; the app keeps running when the window is closed.
- **Help ▸ Report a Bug…** opens a new GitHub issue in the browser, filled in with what you wrote
  and, if you want, diagnostics: versions, Mac model, library size and formats, whether the music
  is on a local disk or a share, a few settings, the last 40 errors, and the latest crash
  report's summary. Paths and the Mac's user and computer names are taken out, the diagnostics
  can be edited before sending, and susurrus itself sends nothing. The errors come from a small
  log in `~/Library/Logs/susurrus/events.log` that survives a crash.
- Queue and position are restored (paused) on the next launch; nothing is read from the share
  until Play. A paused player lets the audio device go after 20 s, so the Mac and Bluetooth or
  AirPlay speakers can sleep. After a change of output (headphones unplugged, an AirPlay switch)
  the track carries on from where it was.

**Soulseek** (phases 1–4: search + downloads + sharing + messages)
- Native Soulseek client (sidebar ▸ Network ▸ Soulseek): connect with a username/password set in
  Settings ▸ Soulseek (saved with Return or Save; the password lives in the keychain; a brand-new
  username is auto-registered by the network on first login) and search the network. A dropped
  connection is retried after about 5 s, then less and less often (at most every 5 minutes), and
  at once when the Mac wakes or the network comes back; after the account logs in elsewhere
  susurrus says so and stays offline. A search with no results for 45 s says so, with Search
  Again and Add to Wishlist. Results stream in from peers with format,
  bitrate/bit depth, length, size, free-slot and speed columns.
- **Downloads**: double-click a result (or right-click — multi-select works, and "Download
  Folder" grabs a whole album) to queue it with the peer. The **Downloads tab** (next to Search,
  with a live count of active transfers) shows each file's state: connecting, waiting on the
  uploader, place in their queue, transferring with progress, done, or failed (with the peer's
  reason, e.g. "File not shared.") — plus an Uploads section for files others fetch from you.
  Files land in Settings ▸ Soulseek's download folder (default `~/Music/Soulseek`), inside their
  remote folder name so albums stay together (a "CD1"/"Disc 2" folder keeps its album folder:
  `Album/CD1/`). Partial files collect in the hidden `.incomplete` folder, one per user and file,
  resume from where they stopped (Retry in the row's context menu) and restart if one is bigger
  than the file; finished files never replace an existing one and are quarantined like a
  browser's downloads, and finished folders are **imported into the library automatically**
  (and, once matched, moved to the library folder; see below). Cancel All and Cancel Folder ask
  first.
- The protocol (message layouts, zlib-wrapped search results, the direct + server-relayed peer
  connection dance, and the QueueUpload → TransferRequest → raw-byte `F` connection transfer
  flow) follows Nicotine+ 3.3.10's `doc/SLSKPROTOCOL.md`, implemented from scratch in
  `Sources/Susurrus/Soulseek/` on Network.framework + BSD sockets — no dependencies. The peer
  listener uses BSD sockets because `NWListener` fails (EINVAL) on Macs with certain network
  filters; without a reachable port everything still works through server-relayed connections.
  A peer is dialed and asked to connect back at the same time, and whichever arrives first is
  used, so firewalled peers are reached in seconds.
- **Sharing**: pick a shared folder in Settings ▸ Soulseek. The share is built from the library's
  tracks in that folder (with their bitrate, length and bit depth), so it's up at once without
  reading the share; files the library doesn't have are found by a walk of the folder in the
  background the first time, once a day, or on Rescan, and remembered in
  `~/Library/Application Support/susurrus/Soulseek/Share.json`. susurrus joins the distributed
  network as a leaf (adopts a parent, takes no children), answers matching searches directly to
  the searcher, serves browse requests, and uploads queued files over `F` connections — two
  slots, a queue with position replies, resume offsets honored. Search matching is whole words,
  every one must match, with `-word` exclusions, like other clients; very long searches aren't
  answered.
- **Filters** above Search/Wishlist/Browse results: filter words (`-word` excludes), a format
  menu (Lossless, 320/256/192 kbps or better — lossless always passes), free-slot only, and
  **Group by folder**, which folds results into one row per user + remote folder (total size and
  length, "Mixed" when formats differ) that downloads the whole folder.
- **Block users** (right-click a result or an upload): their results are hidden, and they get no
  search results, an empty share list, no user info, and "Banned" for upload requests; their
  messages are dropped. Settings ▸ Soulseek
  lists them with Unblock.
- **Browse** tab (or right-click a result/transfer ▸ Browse *user*'s Files): fetches the user's
  whole share (peer code 4 → 5, zlib file list, up to 96 MB compressed; bare file names are joined
  to their folder).
  Folders on the left with a filter, files on the right; right-click a folder to download it, or
  it and its subfolders.
- **Wishlist** tab: saved searches (add there, or with the ☆ next to the search field). While
  connected, one is re-run per interval, round robin, with the server's `WishlistSearch` (code
  103) at the interval it sends (code 104, default 12 minutes). New results are counted per
  search (and on the tab) until you look; results are kept for the session.
- **Messages** tab: private conversations, latest first, with unread counts on each one, on the
  tab and on the sidebar's Soulseek row, and a dot for whether the user is online, away or
  offline (the server's `WatchUser` / `GetUserStatus`, codes 5 and 7). Start one from the
  username field there, or right-click a result, a transfer or a browsed user ▸ **Message
  *user***. Messages go through the server (`MessageUser`, code 22), which holds them for
  offline users; every message received is acknowledged (`MessageAcked`, code 23) so it isn't
  sent again, and ones that waited for you arrive at login marked as sent while you were
  offline. Blocked users' messages are dropped. History is kept in
  `~/Library/Application Support/susurrus/Soulseek/Messages.json`.
- **User info** (right-click ▸ Show Info, or Info in a conversation): a sheet with the user's
  status, the server's stats (`GetUserStats`, code 36: average speed, uploads, files and
  folders), and what the user reports about themselves (peer `UserInfoRequest` → `UserInfoResponse`,
  codes 15 → 16: description, picture, upload slots, queue, free slot), with Browse Files,
  Message and Block. susurrus answers the same request with the description from Settings ▸
  Soulseek, its two upload slots, its queue and whether a slot is free (blocked users get no
  answer).
- **Tagging finished downloads** (Settings ▸ Soulseek, on by default): once a download folder
  has no transfers left, it's matched to a MusicBrainz release like Look Up Album ("CD1"/"Disc 2"
  subfolders count as one album). Only when every file pairs with a track and the lengths agree
  are the tags fixed and written into the downloaded files (even with "Write tags to files"
  off; they're susurrus's own downloads), the cover embedded and saved as cover.jpg. Then, by
  **Matched Albums**:
  - **Move to the library folder** (the default): the folder picked there, else the library's
    first watched folder. Once the album's tags and cover are in the downloaded files (and none
    of it is playing), it's copied into "Artist/Album (Year)" there, files renamed "03 Title.ext"
    ("1-03 Title.ext" on multi-disc releases), along with the rest of the folder (cue sheets,
    logs, images; disc folders flattened). Each copy's size is checked, the library is pointed at
    the copies (play counts, ratings and playlists stay), and then the download is deleted, its
    folder too unless audio that didn't match is left in it. So each file crosses to a network
    share once, finished. The copy collects in a hidden folder and appears in one step, so a
    rescan never sees half an album, and a taken "Artist/Album (Year)" gets a " (2)". Albums are
    moved one at a time, shown in the activity button (with Stop). While the library folder isn't
    there (its share isn't mounted), they wait, saved in `Album moves.json` next to the library,
    and move once it mounts or at the next launch. A move that fails for another reason leaves the
    album in the download folder and says why.
  - **Sort into Artist/Album (Year) here**: the same names, inside the download folder.
  - **Leave as they are.** (Before there was a choice, "Move them into Artist/Album (Year)
    folders" decided between these two, and it still does for anyone who switched it.)

  Anything less certain is left alone with a notification; right-click a finished download ▸
  **Look Up Album on MusicBrainz…** (or use it on the album's tracks anywhere in the library) to
  pick the release yourself, which files it the same way: files in the download folder count as
  downloads wherever the lookup starts.
- **Notifications** (Settings ▸ Soulseek, on by default) when a download folder finishes and is
  imported, and when a saved search turns up new results; a separate switch covers private
  messages (one per sender, so a burst at login doesn't flood). They need the app bundle (not
  `swift run`).
- **Upload speed limit** (Settings ▸ Soulseek): one cap for all uploads together, paced in small
  chunks so the rate stays even. **Connect when susurrus starts** keeps the share and wishlist
  going without a search first.

## Writing tags to files

Off by default: **Settings ▸ Library ▸ Write tags to files** (asks for confirmation the first
time). With it on, Get Info edits and ratings are queued and written into the files in the
background, one file at a time, with progress in Settings and the window subtitle. Play counts
stay in susurrus's database (rewriting a file after every play isn't worth it).

| Format | Tags | Rating | Cover |
| --- | --- | --- | --- |
| MP3 | ID3v2.2 / v2.3 / v2.4 (keeps the file's version; untagged files get v2.3) | `POPM`, MusicBee values (½★ = 13 … 4½★ = 242, 5★ = 255); existing POPM frames keep their email and play counter | `APIC` (`PIC` in v2.2), front cover; other pictures kept |
| FLAC | Vorbis comments | `RATING` 0–100 (20 per star) | `PICTURE` block, front cover; other pictures kept |
| M4A | iTunes `ilst` items | not written: no rating field that other players agree on | `covr` (replaces every picture) |

WAV/AIFF, unsynchronised or compressed ID3 tags, and fragmented MP4 are reported and skipped.

Every write is checked before the original is touched (`Library/TagWriting/TagFileWriter.swift`):
the new file is written to a hidden temp copy next to the original, read back from disk, and must
parse with the new values, keep every frame/comment/item that wasn't edited byte for byte, and
keep the audio data identical (MP4: every chunk offset still points at the same bytes; MP3/M4A:
AVFoundation reads the same duration).

When the new MP3/FLAC tags fit in the space the old tag takes up (its padding absorbs the
change, which is the usual case), only the tag is read and only the byte ranges that changed are
written back in place, then read back and compared (the old bytes are put back if they differ).
The audio is never written to. Over a slow network share (~1.3 MB/s) that took writes from about a
minute per file to a few seconds. In-place writes are capped at 64 KB in all: a bigger change takes
the temp-copy path, so a connection that drops mid-write can't leave a tag half old and half new.
To keep them small, FLAC comments that grow move into the padding (their old place becomes
padding), so the cover doesn't move; an ID3 frame that changes size moves to the end of the tag,
so the first such edit of a field that sits before a large cover goes through the temp copy and
later edits of it are small. If the original's size or modification date changed
meanwhile it's skipped. Otherwise permissions, creation date and extended attributes (Finder
tags) are copied over and the copy is renamed over the original (atomic). The track that's
playing is written once it stops playing.

**Why hand-written writers instead of a library.** Options considered, all buildable with only the
Command Line Tools:
- *Vendored TagLib* (C++ target + C wrapper): covers every format, but it means tens of thousands of lines of C++ to
  vendor and keep updated, LGPL/MPL licensed, and its C API can't reach POPM.
- *Pure-Swift ID3 packages* (e.g. ID3TagEditor): MP3 only, and they rebuild the tag from the
  frames they understand, dropping anything else (TXXX ReplayGain, iTunSMPB gapless info, PRIV…).
- *AVFoundation*: reads tags but can only write them via passthrough export of MP4, which rebuilds
  the whole file.

The formats susurrus writes need only a few hundred lines each when the code edits the frames it
owns and copies everything else verbatim, which is also what makes the byte-for-byte verification
above possible. So: small writers in `Sources/Susurrus/Library/TagWriting/` (`ID3Tag`, `FLACTag`,
`MP4Tag`), no dependencies.

## Playback from a network share

Files on the Mac's own disks and external drives are played in place. Files on a network
volume (SMB, AFP, NFS) can arrive slowly (the share susurrus was developed against measured
0.2–3 MB/s), so for those:
- A track you start plays **straight from the share** if it's MP3/AAC/WAV/AIFF (needs ~40 KB/s),
  so it starts as soon as the share responds, also when its copy is still under way (the copy
  finishes in the background). If it takes over 8 s the bar says "Waiting for the network share…".
- **Scrubbing shows a spinner while the share catches up**: after a seek in a streamed track (or
  resuming after a seek while paused, or a restored position), a short probe segment is
  scheduled first; the loading wheel next to the title spins until that probe's audio has
  actually played (and the "Waiting for the network share…" note appears if it takes over 8 s).
- **FLAC is copied locally first**: AudioToolbox scans FLAC files end to end for packets, which
  over the network stalled playback.
- The **next track is copied** to `~/Library/Caches/susurrus/Playback` (shared with the mixer, up
  to 1 GB, oldest out first, cleared on launch) in the background — after the current stream has
  had 20 s to settle — and chained onto the audio node in the last ~12 s, so transitions are
  gapless and queue edits are free. Copies run 1 MB at a time on threads of their own and stop
  once their track is no longer current, next or on a deck.
- If three files in a row won't open (the share is gone), playback goes back to where that began
  and waits there, paused, with the queue and position kept; the bar says why.

## Layout

| Path | What |
| --- | --- |
| `Sources/Susurrus/Library/` | SQLite wrapper, store (+ editing, scanning and file stamps, history, listen log, removal, saved tag writes), the one table of track columns, text folding (`TextKey`), blocking file work off the shared thread pool (`BlockingIO`), listening stats, artist index and discography matching, MusicBrainz release matching, moving albums to the library folder (copies, checks, the saved queue), smart playlist predicates, tag reader, albums, artwork, BPM and key detection, search scopes, duplicate and missing-file checks |
| `Sources/Susurrus/Library/TagWriting/` | ID3 / FLAC / MP4 tag writers, safe file replacement, background write queue and its saved backlog |
| `Sources/Susurrus/Playback/` | Player (queue, gapless, shuffle/repeat), two-deck mixer and track analysis (waveforms, beat grid), listens and play counts, shared file cache, EQ, output devices, Now Playing |
| `Sources/Susurrus/Exchange/` | M3U playlists, Apple Music / iTunes `Library.xml` reader and import plan, Rekordbox XML writer, path matching, atomic export writes, remembered beat grids |
| `Sources/Susurrus/Metadata/` | MusicBrainz / Wikipedia / ListenBrainz client for artist pages (rate limit, disk cache), MusicBrainz release search and Cover Art Archive covers |
| `Sources/Susurrus/Soulseek/` | Soulseek client: wire codec, messages, sockets, deadline-aware waiters, transfer files, client actor (server + peer connections), UI model, share index, private conversations (saved to disk) |
| `Sources/Susurrus/LegacyMigration.swift` | Takes over casting's folders, settings and Soulseek password on the first launch |
| `Sources/Susurrus/AppModel*.swift` | App state, selection, actions and undo, scanning, library housekeeping, import and export, Look Up Album, covers and tidying Soulseek downloads (sorting them, or moving them to the library folder), notices and background activity |
| `Sources/Susurrus/Updater.swift` | Sparkle in-app updates (Check for Updates…, automatic checks) |
| `Sources/Susurrus/Reporting/` | Bug reports: event log, diagnostics, redaction, crash report summaries, the GitHub issue link |
| `Sources/Susurrus/UI/` | Track table (NSTableView), shared track and album menus, sidebar, albums, browser, Up Next, Get Info, smart editor, EQ, mixer, import and export sheets, activity button and notices, Soulseek (+ messages and user info), settings, menu bar |
| `Sources/ObjCSupport/` | Catches NSExceptions (predicate evaluation, audio graph connections) |
| `Tests/SusurrusTests/` | 278 tests (plus one against the live MusicBrainz and Cover Art Archive, run with `SUSURRUS_LIVE_TESTS=1`): listening stats, the listen log (store, v2→v3 upgrade, player skip/pause/stop tracking), discography matching, artist index, smart playlist predicates, albums/artwork, library editing, history/removal/saved tag writes and the v1→v2 upgrade, search scopes, duplicates, missing-file checks, tag reading and writing (on generated files), BPM detection (generated drum patterns, WAV and FLAC excerpts), beat grids (click tracks) and keys (chord progressions), player, mixer, taking over casting's folders and settings, import and export (M3U round trips and other apps' playlists, a generated `Library.xml` and the import plan, the Rekordbox XML shape), bug reports (redaction, issue links, crash summaries, event log), release matching (tagged and untagged files, multi-disc, near misses, edits, folder names) and covers in MP3/FLAC/M4A tags, moving matched downloads to the library folder (renamed copies, size checks, disc folders flattened, what's left in the download folder, waiting for a folder that isn't there, applying a release to a download), fetched and folder covers, Soulseek codec + loopback client tests (search, wishlist, browse, download, resume, denial, blocking, serving searches + uploads, upload speed limit, private messages and acks, offline messages, user info and stats) against a mock server, and saved conversations |

## Known issues

- ID3v1 tags at the end of MP3s aren't updated. (Tag writes still queued at quit are saved in
  the database and picked up at the next launch, unless Write tags to files was turned off. They're
  saved in batches off the main thread, a cover queued for many tracks is kept once in `Queued
  Covers` next to the library, and when the queue empties a database with 64 MB or more unused is
  compacted.)
- The smart playlist match count can take a few seconds on the full library.
- Ogg/Opus aren't playable (AVFoundation can't decode them; none are in the current library).
- Output-device switching mid-track (headphones unplugged, AirPlay) is handled and covered by
  tests that simulate the engine stopping, but not yet tested on real hardware changes.
