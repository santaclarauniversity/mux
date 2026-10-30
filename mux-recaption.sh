#!/usr/bin/env bash
#
# mux-recaption.sh — replace a Mux asset's caption track with a VTT/SRT you host.
#
# Finds any conflicting text track on the asset (the AI-generated one, or one
# already using the target name), deletes it, then uploads yours in its place.
#
#   ./mux-recaption.sh <asset-id> <caption-url>
#
# Requires: mux CLI (brew install muxinc/tap/mux) and jq.

set -euo pipefail

LANG_CODE="en"
TRACK_NAME="English"
TEXT_TYPE="subtitles"
CLOSED_CAPTIONS=0
ASSUME_YES=0
DRY_RUN=0
WAIT=0
WAIT_TIMEOUT=300

usage() {
  cat <<'EOF'
Usage: mux-recaption.sh [options] <asset-id> <caption-url>

Replaces an asset's caption track with the file at <caption-url>.

Options:
  -l <code>   Language code (default: en)
  -n <name>   Track name (default: English)
  -t <type>   Text type: subtitles or captions (default: subtitles)
  -c          Mark the new track as SDH (--closed-captions)
  -w          Wait for the new track to finish ingesting
  -T <secs>   Wait timeout in seconds (default: 300)
  -y          Skip the confirmation prompt
  -d          Dry run — show what would happen, change nothing
  -h          Show this help

Examples:
  ./mux-recaption.sh AbC123 https://assets.scu.edu/mux/captions/ignat.vtt
  ./mux-recaption.sh -w -y AbC123 https://assets.scu.edu/mux/captions/ignat.vtt
  ./mux-recaption.sh -l es -n "Español" AbC123 https://assets.scu.edu/mux/captions/ignat.es.vtt
EOF
}

while getopts ":l:n:t:T:cwydh" opt; do
  case "$opt" in
    l) LANG_CODE="$OPTARG" ;;
    n) TRACK_NAME="$OPTARG" ;;
    t) TEXT_TYPE="$OPTARG" ;;
    T) WAIT_TIMEOUT="$OPTARG" ;;
    c) CLOSED_CAPTIONS=1 ;;
    w) WAIT=1 ;;
    y) ASSUME_YES=1 ;;
    d) DRY_RUN=1 ;;
    h) usage; exit 0 ;;
    :) echo "Error: -$OPTARG needs an argument." >&2; exit 2 ;;
    \?) echo "Error: unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi

ASSET_ID="$1"
CAPTION_URL="$2"

case "$TEXT_TYPE" in
  subtitles|captions) ;;
  *) echo "Error: -t must be 'subtitles' or 'captions'." >&2; exit 2 ;;
esac

for cmd in mux jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: '$cmd' is not installed or not on PATH." >&2
    exit 1
  }
done

# --- look at the asset -------------------------------------------------------

echo "Fetching asset $ASSET_ID..."
raw=$(mux assets get "$ASSET_ID" --json) || {
  echo "Error: could not fetch asset. Check the ID and that 'mux login' has run." >&2
  exit 1
}
asset=$(jq '(.data // .)' <<<"$raw")

status=$(jq -r '.status // "unknown"' <<<"$asset")
if [ "$status" != "ready" ]; then
  echo "Error: asset status is '$status'. Tracks can only be added once it's ready." >&2
  exit 1
fi

# A track conflicts if it shares the target name (Mux enforces uniqueness per
# track type) or if it's the auto-generated track for the same base language.
base_lang="${LANG_CODE%%-*}"
conflict_tsv=$(jq -r --arg lang "$base_lang" --arg name "$TRACK_NAME" '
  .tracks[]?
  | select(.type == "text")
  | select(
      (.name // "") == $name
      or (((.language_code // "") | split("-")[0]) == $lang
          and (.text_source // "") == "generated_vod")
    )
  | [.id, (.name // "-"), (.language_code // "-"), (.text_source // "-")]
  | @tsv
' <<<"$asset")

conflicts=()
while IFS= read -r line; do
  [ -n "$line" ] && conflicts+=("$line")
done <<<"$conflict_tsv"

echo
echo "  Asset:    $ASSET_ID"
echo "  New file: $CAPTION_URL"
echo "  Track:    $TRACK_NAME ($LANG_CODE, $TEXT_TYPE)"
if [ "${#conflicts[@]}" -eq 0 ]; then
  echo "  Removing: nothing — no conflicting text track found"
else
  echo "  Removing:"
  for row in "${conflicts[@]}"; do
    id=$(cut -f1 <<<"$row")
    name=$(cut -f2 <<<"$row")
    lang=$(cut -f3 <<<"$row")
    src=$(cut -f4 <<<"$row")
    echo "            $id  \"$name\"  $lang  ($src)"
  done
fi
echo

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run — nothing changed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Proceed? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|Yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# --- swap the track ----------------------------------------------------------

for row in ${conflicts[@]+"${conflicts[@]}"}; do
  id=$(cut -f1 <<<"$row")
  echo "Deleting track $id..."
  mux assets tracks delete "$ASSET_ID" "$id" --force
done

echo "Creating track from $CAPTION_URL..."
create_args=(
  assets tracks create "$ASSET_ID"
  --url "$CAPTION_URL"
  --type text
  --text-type "$TEXT_TYPE"
  --language-code "$LANG_CODE"
  --name "$TRACK_NAME"
)
[ "$CLOSED_CAPTIONS" -eq 1 ] && create_args+=(--closed-captions)

create_raw=$(mux "${create_args[@]}" --json)
new_track_id=$(jq -r '(.data // .).id // empty' <<<"$create_raw")

if [ -z "$new_track_id" ]; then
  echo "Track created, but no ID came back. Raw response:" >&2
  echo "$create_raw" >&2
  exit 1
fi
echo "Created track $new_track_id"

# --- optionally wait for ingest ---------------------------------------------

if [ "$WAIT" -eq 1 ]; then
  echo -n "Waiting for ingest"
  elapsed=0
  track_status="unknown"
  while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    track_status=$(mux assets get "$ASSET_ID" --json \
      | jq -r --arg id "$new_track_id" \
          '(.data // .).tracks[]? | select(.id == $id) | .status // "unknown"')
    case "$track_status" in
      ready)
        echo " ready."
        break
        ;;
      errored)
        echo
        echo "Error: Mux failed to ingest the file. Check that the URL is publicly" >&2
        echo "reachable and that the VTT/SRT is well-formed." >&2
        exit 1
        ;;
      *)
        echo -n "."
        ;;
    esac
  done
  if [ "$track_status" != "ready" ]; then
    echo
    echo "Still '$track_status' after ${WAIT_TIMEOUT}s — check again with:" >&2
    echo "  mux assets get $ASSET_ID" >&2
  fi
fi

playback_id=$(jq -r '.playback_ids[0].id // empty' <<<"$asset")
if [ -n "$playback_id" ]; then
  echo
  echo "Verify: https://stream.mux.com/$playback_id/text/$new_track_id.vtt"
fi
