# Mux workspace

This folder is where all Mux video work happens: uploading videos, setting titles, and managing caption tracks.
Everything is done through the official Mux CLI (`mux`, installed via `brew install muxinc/tap/mux`) plus `jq`.

## Environment

- Run `mux whoami` first to confirm which environment is active.
- The usual target is org **Santa Clara University** (`qelud4`), environment **SCU.EDU assets** (`87bj9p`), which is **production**.
  Anything created here is live, so double check titles and settings before creating assets.
- If auth fails, run `mux login`.
  An access token env file may also exist in `~/Downloads`; never print or commit its contents.

## House conventions for new assets

Match what existing assets in the environment already use unless told otherwise:

- Playback policy: `public`
- Video quality: `basic`
- Captions: an uploaded text track named `English`, language `en`, text type `subtitles` (not Mux auto-generated captions).
- Static MP4 renditions: not added by default.
  Some older assets (including some vertical ones) have a `720p` static rendition; ask before adding one.
- Titles are set in `meta.title`.
  Older assets use a `YYMM_Department_Name` style (for example `2603_PNP_Sam_Pluta`), but use whatever title the user asks for.

To see current conventions, inspect recent assets:

```sh
mux assets list --limit 10 --json | jq '[(.data // .)[] | {id, status, title: .meta.title, vq: .video_quality, playback: .playback_ids, tracks: [.tracks[]? | {type, name, text_source, language_code}], mp4: .static_renditions}]'
```

## Uploading videos

### 1. Get the source files locally

Source videos usually live in an SCU shared Google Drive folder.
Those files are private to SCU accounts (not link-shared), so Mux cannot pull them by URL.
The Google Drive connector can list the folder and check sizes, but it cannot practically download large videos (it returns base64).
`gcloud` on this machine has no Drive-scoped token either.
The working approach is to ask the user to download the MP4s to `~/Downloads`, then compare local file sizes against the Drive listing.

### 2. Create the assets

```sh
mux assets create --upload "Name_vertical_final.mp4" -p public --video-quality basic -y --json
```

Gotcha: with `--upload`, the JSON output is a list of **direct uploads**, not assets:

```json
[{ "file": "Name_vertical_final.mp4", "uploadId": "HG8V...", "status": "waiting" }]
```

Resolve each upload ID to its asset ID:

```sh
mux uploads get <upload-id> --json | jq -r '(.data // .) | .asset_id'
```

### 3. Set the title

```sh
mux assets update <asset-id> --title "Dylan's Perspective on Jesuit Education"
```

The title can be set while the asset is still `preparing`.

### 4. Wait for processing

Assets go `preparing` -> `ready`.
Short clips (15-30 s, 40-80 MB) were ready within about a minute.
Poll with a background loop rather than blocking:

```sh
mux assets get <asset-id> --json | jq -r '(.data // .) | "\(.meta.title) | \(.status) | \(.duration) | \(.aspect_ratio) | \(.resolution_tier)"'
```

Sanity check that the duration matches the last caption cue and the aspect ratio is what you expect (for example `9:16` for vertical video).

## Captions

Mux only ingests caption tracks from a **public URL**; there is no local file upload for tracks.

- The user hosts caption files at `https://assets.scu.edu/mux/captions/<filename>`.
  They upload these themselves, so ask them to do it and wait for confirmation.
- Mux accepts `.srt` directly; no VTT conversion needed.
- SRT exports from the editor start with a UTF-8 BOM; Mux handles it fine.
- Before attaching, confirm each hosted file returns 200 and has the same content as the local copy.
  The `assets_scu_edu` repo has `* text=auto` in `.gitattributes`, so the editor's CRLF line endings are served as LF; compare ignoring line endings:

```sh
curl -s -o /tmp/check.srt -w '%{http_code}\n' "https://assets.scu.edu/mux/captions/<file>.srt" && diff <(tr -d '\r' < <local>.srt) <(tr -d '\r' < /tmp/check.srt) && echo same
```

- After a push, the hosted file took about 10 minutes to go live.

### Cropping a full-event SRT to an edited cut

If the video is an excerpt of a longer event, the SRT's last cue will be well past the video's duration.
To find the excerpt, have Mux auto-transcribe the asset into a temporary track (`mux assets tracks generate-subtitles <asset-id> <audio-track-id> --name "English (auto, temp)"`), download its VTT, and match its words against the full SRT to get the source range and time offset.
Then shift and renumber the SRT cues in that range, keeping the original text.
`mux-recaption.sh` removes the temporary auto-generated track when it adds the real one.

### Attaching or replacing captions with `mux-recaption.sh`

`./mux-recaption.sh` in this folder adds a caption track and removes any conflicting text track first (one with the same name, or the auto-generated track for the same language).
It requires the asset to be `ready`.

```sh
./mux-recaption.sh -w -y <asset-id> https://assets.scu.edu/mux/captions/<file>.srt
```

- `-w` waits for the track to finish ingesting; `-y` skips the confirmation prompt; `-d` is a dry run.
- Defaults match house conventions (`English`, `en`, `subtitles`).
- See `./mux-recaption.sh -h` for language, name, and SDH options.

### Verifying captions

The script prints a verify URL.
Fetch it and check that it starts with `WEBVTT`, has the same number of cues as the source SRT, and has the right first line of text:

```sh
curl -s "https://stream.mux.com/<playback-id>/text/<track-id>.vtt"
```

## Useful CLI facts

- Add `--json` to any command for machine-readable output; responses may or may not be wrapped in `.data`, so use `jq '(.data // .)'`.
- `mux assets create --wait` polls for up to 5 minutes.
- `mux assets tracks create` requires `--url`, `--type`, and `--language-code`.
- `mux assets delete` skips its prompt with `--force` (not `-y`).
- Mux cannot swap the video file under an existing asset; replacing a video means a new asset with a new playback ID, so embeds must be updated.
- `mux <command> --help` is accurate and worth checking before guessing flags.
