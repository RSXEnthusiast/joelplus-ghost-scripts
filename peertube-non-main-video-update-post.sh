#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# peertube-to-ghost.sh
#
# 1. Checks a list of PeerTube channels for new videos (vs a seen-file)
# 2. Adds each new video to a PeerTube playlist
# 3. Posts a single "digest" article to Ghost (one bookmark card per new
#    video + a link to the playlist), then publishes + emails it.
#
# Modes:
#   (no args)   Normal run: add to playlist, publish + email digest, mark seen.
#   --test      Create a Ghost DRAFT only. No playlist writes, no email,
#               no seen-file writes. Safe dry run.
#   --init      Mark every currently-visible video as seen WITHOUT touching
#               the playlist or Ghost. Run this once on first setup so you
#               don't flood yourself with a backlog.
#
# Assumptions (see the write-up in chat):
#   - Monitored channels live on PEERTUBE_URL (local). Remote channels need
#     an extra federation/search step that is NOT implemented here.
#   - PLAYLIST_ID refers to a playlist on PEERTUBE_URL. If left empty, the
#     script will create one named PLAYLIST_NAME on PLAYLIST_CHANNEL_ID.
#
# Schedule (Sunday 5:00pm) via crontab -e:
#   0 17 * * 0  /home/joel/scripts/ghost-scripts/peertube-to-ghost.sh >> /home/joel/scripts/ghost-scripts/peertube-to-ghost.log 2>&1
# =============================================================================

TEST_MODE=0
INIT_MODE=0
if [[ "${1:-}" == "--test" ]]; then
  TEST_MODE=1
elif [[ "${1:-}" == "--init" ]]; then
  INIT_MODE=1
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: $0 [--test|--init]"
  exit 1
fi

# ---------------------------------------------------------------------------
# CONFIG (loaded from .env next to this script — see .env.example)
# ---------------------------------------------------------------------------
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_SOURCE_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# PeerTube instance (no trailing slash) and the channels to watch.
# Channel handles are the local channel "name" (the part before @ in a handle),
# e.g. for joel_channel@joeltube.com you put "joel_channel".
PEERTUBE_URL="${PEERTUBE_URL:-}"
IFS=',' read -ra PEERTUBE_CHANNELS <<< "${PEERTUBE_CHANNELS:-}"
for i in "${!PEERTUBE_CHANNELS[@]}"; do
  PEERTUBE_CHANNELS[$i]="$(echo "${PEERTUBE_CHANNELS[$i]}" | xargs)"
done

# PeerTube credentials. A user account that can edit the target playlist is
# required.
PEERTUBE_USERNAME="${PEERTUBE_USERNAME:-}"
PEERTUBE_PASSWORD="${PEERTUBE_PASSWORD:-}"

# Target playlist.
#   DATED_PLAYLIST=1 -> create a fresh playlist every run, named with the run
#                       date (needs PLAYLIST_CHANNEL_ID). PLAYLIST_ID is ignored.
#   DATED_PLAYLIST=0 -> use the single persistent playlist in PLAYLIST_ID
#                       (or create one named PLAYLIST_NAME if PLAYLIST_ID empty).
DATED_PLAYLIST="${PEERTUBE_DATED_PLAYLIST:-1}"
PLAYLIST_NAME_PREFIX="${PEERTUBE_PLAYLIST_NAME_PREFIX:-New videos}"  # dated mode: text before the date
PLAYLIST_NAME_SEP="${PEERTUBE_PLAYLIST_NAME_SEP:-—}"                 # dated mode: separator (em dash)
PLAYLIST_DATE_FMT="${PEERTUBE_PLAYLIST_DATE_FMT:-%B %-d, %Y}"        # dated mode: strftime, e.g. "July 6, 2026"

PLAYLIST_ID="${PEERTUBE_PLAYLIST_ID:-}"
PLAYLIST_NAME="${PEERTUBE_PLAYLIST_NAME:-New videos}"          # non-dated mode: name when creating
PLAYLIST_CHANNEL_ID="${PEERTUBE_PLAYLIST_CHANNEL_ID:-}"  # numeric channel id, required to CREATE a playlist

# Visibility of created playlists: Public, Unlisted, or Private (case-insensitive).
# Maps to PeerTube's numeric privacy enum (1=Public, 2=Unlisted, 3=Private).
PLAYLIST_VISIBILITY_RAW="${PEERTUBE_PLAYLIST_VISIBILITY:-Public}"
case "$(echo "$PLAYLIST_VISIBILITY_RAW" | tr '[:upper:]' '[:lower:]')" in
  public)   PLAYLIST_PRIVACY=1 ;;
  unlisted) PLAYLIST_PRIVACY=2 ;;
  private)  PLAYLIST_PRIVACY=3 ;;
  *) echo "ERROR: PEERTUBE_PLAYLIST_VISIBILITY must be Public, Unlisted, or Private (got '$PLAYLIST_VISIBILITY_RAW')." >&2
     exit 1 ;;
esac

# How many recent videos to inspect per channel each run (newest first).
FETCH_COUNT="${PEERTUBE_FETCH_COUNT:-100}"
# Skip currently-live streams? (1 = skip lives that haven't finished)
SKIP_LIVES="${PEERTUBE_SKIP_LIVES:-1}"

# Ghost
GHOST_URL="${GHOST_URL:-}"
GHOST_ADMIN_KEY="${GHOST_ADMIN_KEY:-}"
GHOST_NEWSLETTER_SLUG="${GHOST_NEWSLETTER_SLUG:-default-newsletter}"
# Who gets the emailed digest. The post's own visibility is set by
# PEERTUBE_GHOST_VISIBILITY (default paid); this controls the newsletter send only:
#   status:-free  -> paid (+comped) members only  [matches "paid members only"]
#   all           -> everyone; free members get a paywalled teaser + upgrade CTA
#   status:free   -> free members only
GHOST_EMAIL_SEGMENT="${PEERTUBE_GHOST_EMAIL_SEGMENT:-status:-free}"
GHOST_TAG="${PEERTUBE_GHOST_TAG:-Sunday Sidecar}"
GHOST_VISIBILITY="${PEERTUBE_GHOST_VISIBILITY:-paid}"
# ref= tag appended to outbound links for analytics
LINK_REF="${PEERTUBE_LINK_REF:-joelplus.com}"

for var in PEERTUBE_URL PEERTUBE_USERNAME PEERTUBE_PASSWORD GHOST_URL GHOST_ADMIN_KEY; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: $var is not set. Copy .env.example to .env (next to this script) and fill it in." >&2
    exit 1
  fi
done
if [[ "${#PEERTUBE_CHANNELS[@]}" -eq 0 || -z "${PEERTUBE_CHANNELS[0]}" ]]; then
  echo "ERROR: PEERTUBE_CHANNELS is not set. Copy .env.example to .env (next to this script) and fill it in." >&2
  exit 1
fi

# State
SEEN_FILE="$SCRIPT_SOURCE_DIR/seen-peertube-video-ids.txt"

touch "$SEEN_FILE"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

html_escape() {
  python3 -c 'import html,sys; print(html.escape(sys.stdin.read().strip(), quote=True))'
}

# Pull a value out of a JSON object on stdin, e.g. json_get "['data'][0]['id']"
json_get() {
  python3 -c "import json,sys; print(json.load(sys.stdin)$1)"
}

truncate_300() {
  python3 -c 'import sys; print(sys.stdin.read().strip()[:300])'
}

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Ghost admin JWT (same scheme as the YouTube script) -------------------
make_ghost_token() {
  local key_id key_secret now exp header payload unsigned signature
  IFS=':' read -r key_id key_secret <<< "$GHOST_ADMIN_KEY"
  now="$(date +%s)"
  exp="$((now + 300))"
  header="$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$key_id" | base64url)"
  payload="$(printf '{"iat":%s,"exp":%s,"aud":"/admin/"}' "$now" "$exp" | base64url)"
  unsigned="${header}.${payload}"
  signature="$(printf '%s' "$unsigned" \
    | openssl dgst -binary -sha256 -mac HMAC -macopt "hexkey:$key_secret" \
    | base64url)"
  printf '%s.%s\n' "$unsigned" "$signature"
}

# ---------------------------------------------------------------------------
# PEERTUBE AUTH
# ---------------------------------------------------------------------------
# OAuth2 password grant:
#   GET  /api/v1/oauth-clients/local  -> client_id, client_secret
#   POST /api/v1/users/token          -> access_token
PT_TOKEN=""
pt_login() {
  [[ -n "$PEERTUBE_USERNAME" && -n "$PEERTUBE_PASSWORD" ]] \
    || die "PEERTUBE_USERNAME / PEERTUBE_PASSWORD are not set."

  local creds client_id client_secret token_resp
  creds="$(curl -fsS "$PEERTUBE_URL/api/v1/oauth-clients/local")" \
    || die "Could not fetch PeerTube oauth client."
  client_id="$(printf '%s' "$creds"    | json_get "['client_id']")"
  client_secret="$(printf '%s' "$creds" | json_get "['client_secret']")"

  token_resp="$(curl -fsS -X POST "$PEERTUBE_URL/api/v1/users/token" \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "response_type=code" \
    --data-urlencode "username=$PEERTUBE_USERNAME" \
    --data-urlencode "password=$PEERTUBE_PASSWORD")" \
    || die "PeerTube login failed (check username/password)."

  PT_TOKEN="$(printf '%s' "$token_resp" | json_get "['access_token']")"
  [[ -n "$PT_TOKEN" ]] || die "No access_token returned by PeerTube."
}

# Resolve a channel handle/name to the numeric id the playlist API requires.
pt_resolve_channel_id() {
  [[ "$PLAYLIST_CHANNEL_ID" =~ ^[0-9]+$ ]] && return 0
  local resolved
  resolved="$(curl -fsS "$PEERTUBE_URL/api/v1/video-channels/$PLAYLIST_CHANNEL_ID" \
    | json_get "['id']")" \
    || die "Could not resolve channel '$PLAYLIST_CHANNEL_ID' to a numeric id."
  [[ "$resolved" =~ ^[0-9]+$ ]] \
    || die "Channel '$PLAYLIST_CHANNEL_ID' did not resolve to a numeric id (got '$resolved')."
  echo "Resolved channel '$PLAYLIST_CHANNEL_ID' -> id $resolved" >&2
  PLAYLIST_CHANNEL_ID="$resolved"
}

# Resolve / create the target playlist. Sets:
#   PLAYLIST_ID (numeric-or-uuid id used for the add endpoint)
#   PLAYLIST_SHORT (short uuid, for the public URL)
#   PLAYLIST_DISPLAY (display name)
PLAYLIST_SHORT=""
PLAYLIST_UUID=""
PLAYLIST_DISPLAY=""
pt_ensure_playlist() {
  if [[ "$DATED_PLAYLIST" -eq 1 || -z "$PLAYLIST_ID" ]]; then
    pt_resolve_channel_id
  fi
  if [[ "$DATED_PLAYLIST" -eq 1 ]]; then
    local dated_name
    dated_name="$PLAYLIST_NAME_PREFIX $PLAYLIST_NAME_SEP $(date +"$PLAYLIST_DATE_FMT")"

    [[ -n "$PLAYLIST_CHANNEL_ID" ]] \
      || die "DATED_PLAYLIST=1 requires PLAYLIST_CHANNEL_ID (numeric channel id)."
    echo "Creating playlist \"$dated_name\" ..."
    local resp
    resp="$(curl -fsS -X POST "$PEERTUBE_URL/api/v1/video-playlists" \
      -H "Authorization: Bearer $PT_TOKEN" \
      -F "displayName=$dated_name" \
      -F "privacy=$PLAYLIST_PRIVACY" \
      -F "videoChannelId=$PLAYLIST_CHANNEL_ID")" \
      || die "Playlist creation failed."
    # Use the uuid, not the numeric id: PeerTube only allows numeric-id lookups
    # for Public objects (to stop enumeration of Unlisted/Private ones) -- the
    # uuid works for every privacy level, for both this read-back and the
    # add-to-playlist calls below.
    PLAYLIST_ID="$(printf '%s' "$resp" | json_get "['videoPlaylist']['uuid']")"

  elif [[ -z "$PLAYLIST_ID" ]]; then
    [[ -n "$PLAYLIST_CHANNEL_ID" ]] \
      || die "PLAYLIST_ID is empty and PLAYLIST_CHANNEL_ID is unset, so a playlist can't be created."
    echo "Creating playlist \"$PLAYLIST_NAME\" ..."
    local resp
    resp="$(curl -fsS -X POST "$PEERTUBE_URL/api/v1/video-playlists" \
      -H "Authorization: Bearer $PT_TOKEN" \
      -F "displayName=$PLAYLIST_NAME" \
      -F "privacy=$PLAYLIST_PRIVACY" \
      -F "videoChannelId=$PLAYLIST_CHANNEL_ID")" \
      || die "Playlist creation failed."
    PLAYLIST_ID="$(printf '%s' "$resp" | json_get "['videoPlaylist']['uuid']")"
  fi

  # Read back canonical ids + display name (works for both created and existing).
  local meta
  meta="$(curl -fsS "$PEERTUBE_URL/api/v1/video-playlists/$PLAYLIST_ID" \
    -H "Authorization: Bearer $PT_TOKEN")" \
    || die "Could not read playlist $PLAYLIST_ID."
  PLAYLIST_SHORT="$(printf '%s'   "$meta" | json_get "['shortUUID']")"
  PLAYLIST_UUID="$(printf '%s'    "$meta" | json_get "['uuid']")"
  PLAYLIST_DISPLAY="$(printf '%s' "$meta" | json_get "['displayName']")"
}

# Add a video (by numeric id) to the playlist. Returns 0 on success (or if
# already present), non-zero otherwise.
pt_add_to_playlist() {
  local video_id="$1" status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$PEERTUBE_URL/api/v1/video-playlists/$PLAYLIST_ID/videos" \
    -H "Authorization: Bearer $PT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"videoId\": $video_id}")"
  # 200 = added. 409 = already in playlist (treat as success).
  [[ "$status" == "200" || "$status" == "409" ]]
}

# ---------------------------------------------------------------------------
# COLLECT NEW VIDEOS
# ---------------------------------------------------------------------------
# For each channel, list newest videos and emit one JSON row per video.
# Rows are collected into NEW_ROWS (only videos not already in $SEEN_FILE).
declare -a NEW_ROWS=()

collect_channel() {
  local handle="$1" resp
  resp="$(curl -fsS "$PEERTUBE_URL/api/v1/video-channels/$handle/videos?sort=-publishedAt&count=$FETCH_COUNT&start=0")" \
    || { echo "WARN: could not fetch channel '$handle', skipping." >&2; return 0; }

  # Parse the {total,data:[...]} payload into flat JSON rows (oldest-first so
  # that when we process them, playlist/seen order is chronological).
  local rows resp_tmp
  resp_tmp="$(mktemp)"
  printf '%s' "$resp" > "$resp_tmp"
  rows="$(SKIP_LIVES="$SKIP_LIVES" PT_URL="$PEERTUBE_URL" HANDLE="$handle" python3 - "$resp_tmp" <<'PY'
import json, os, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    data = json.load(f)

videos = data.get("data", [])
skip_lives = os.environ.get("SKIP_LIVES") == "1"
base = os.environ["PT_URL"].rstrip("/")
handle = os.environ["HANDLE"]

rows = []
for v in videos:
    if skip_lives and v.get("isLive"):
        continue
    thumb = v.get("thumbnailPath") or v.get("previewPath") or ""
    thumb = (base + thumb) if thumb.startswith("/") else thumb
    url = v.get("url") or f"{base}/w/{v.get('shortUUID') or v.get('uuid')}"
    channel = (v.get("channel") or {}).get("displayName") or handle
    rows.append({
        "uuid": v.get("uuid") or v.get("shortUUID"),
        "id": v.get("id"),
        "name": (v.get("name") or "Untitled").strip(),
        "url": url,
        "thumb": thumb,
        "published": v.get("publishedAt") or "",
        "channel": channel,
        "description": (v.get("description") or "").strip(),
        "isLive": bool(v.get("isLive")),
    })

# API gives newest-first; reverse to oldest-first for stable processing order.
for row in reversed(rows):
    print(json.dumps(row, ensure_ascii=False))
PY
)"
  rm -f "$resp_tmp"

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    local uuid
    uuid="$(printf '%s' "$row" | json_get "['uuid']")"
    grep -Fxq "$uuid" "$SEEN_FILE" && continue
    NEW_ROWS+=("$row")
  done <<< "$rows"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

if [[ "$TEST_MODE" -eq 1 ]]; then
  echo "TEST MODE: Ghost draft only."
fi

# Gather new videos across all channels.
for ch in "${PEERTUBE_CHANNELS[@]}"; do
  collect_channel "$ch"
done

if [[ "${#NEW_ROWS[@]}" -eq 0 ]]; then
  echo "No new PeerTube videos."
  exit 0
fi

echo "Found ${#NEW_ROWS[@]} new video(s)."

if [[ "${#NEW_ROWS[@]}" -gt 1 ]]; then
  mapfile -t NEW_ROWS < <(printf '%s\n' "${NEW_ROWS[@]}" | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
rows.sort(key=lambda r: (r.get("published") or "", r.get("id") or 0))
for r in rows:
    print(json.dumps(r, ensure_ascii=False))
')
fi

# --init: just record them as seen and stop.
if [[ "$INIT_MODE" -eq 1 ]]; then
  for row in "${NEW_ROWS[@]}"; do
    uuid="$(printf '%s' "$row" | json_get "['uuid']")"
    name="$(printf '%s' "$row" | json_get "['name']")"
    echo "INIT: marking seen -> $name"
    echo "$uuid" >> "$SEEN_FILE"
  done
  echo "INIT: marked ${#NEW_ROWS[@]} video(s) as seen."
  exit 0
fi

# We need PeerTube auth for playlist reads/writes (skipped in test mode's
# playlist-write, but we still resolve the playlist for its public URL).
pt_login
pt_ensure_playlist

# Process each new video: add to playlist (unless --test), keep the ones that
# succeed for the digest + seen-marking.
#
# ORDER NOTE: PeerTube surfaces the most-recently-added element at the TOP of a
# playlist, so to make the finished playlist read oldest->newest (chronological)
# we add videos in reverse (newest-first) -- the oldest video, added last, ends
# up on top. DIGEST_ROWS is still assembled oldest-first (we prepend) so the
# post's list + feature-image logic below are unaffected.
declare -a DIGEST_ROWS=()
for (( i=${#NEW_ROWS[@]}-1; i>=0; i-- )); do
  row="${NEW_ROWS[$i]}"
  name="$(printf '%s' "$row" | json_get "['name']")"
  vid_id="$(printf '%s' "$row" | json_get "['id']")"

  if pt_add_to_playlist "$vid_id"; then
    echo "Added to playlist -> $name"
    DIGEST_ROWS=("$row" "${DIGEST_ROWS[@]}")   # prepend -> keeps DIGEST_ROWS oldest-first
  else
    echo "WARN: failed to add '$name' (id $vid_id) to playlist; leaving it unseen to retry." >&2
  fi
done

if [[ "${#DIGEST_ROWS[@]}" -eq 0 ]]; then
  echo "No videos were successfully processed; nothing to post."
  exit 0
fi

# --- Build the Ghost digest post body --------------------------------------
COUNT="${#DIGEST_ROWS[@]}"
POST_DATE="$(date +"%B %-d, %Y")"          # e.g. "July 2, 2026"
TITLE="Sunday Sidecar // $POST_DATE"

# Feature image = newest video's thumbnail (last row = newest, since we
# processed oldest-first).
FEATURE_IMAGE="$(printf '%s' "${DIGEST_ROWS[-1]}" | json_get "['thumb']")"

PLAYLIST_WATCH_URL="$PEERTUBE_URL/w/p/$PLAYLIST_SHORT?ref=$LINK_REF"
# Use the shortUUID for the embed (matches PeerTube's "share > embed" markup).
PLAYLIST_EMBED_URL="$PEERTUBE_URL/video-playlists/embed/$PLAYLIST_SHORT"
PLAYLIST_WATCH_HTML="$(printf '%s'   "$PLAYLIST_WATCH_URL"   | html_escape)"
PLAYLIST_EMBED_HTML="$(printf '%s'   "$PLAYLIST_EMBED_URL"   | html_escape)"
PLAYLIST_DISPLAY_HTML="$(printf '%s' "$PLAYLIST_DISPLAY"     | html_escape)"

# 1) Playlist embed wrapped in Ghost's HTML-card comment markers. With
#    source=html, these markers make Ghost emit a native HTML card that renders
#    the iframe verbatim (theme scales it full-width 16:9). WITHOUT the markers,
#    a bare iframe becomes an "embed" card that crops to the wrong width.
#    NOTE: iframes are stripped by most email clients, so the embed is blank in
#    the emailed newsletter -- the video list below is the email fallback.
HTML_BODY="<!--kg-card-begin: html--><div style=\"position: relative; padding-top: 56.25%;\"><iframe title=\"${PLAYLIST_DISPLAY_HTML}\" width=\"100%\" height=\"100%\" src=\"${PLAYLIST_EMBED_HTML}\" style=\"border: 0px; position: absolute; inset: 0px;\" allow=\"fullscreen\" sandbox=\"allow-same-origin allow-scripts allow-popups allow-forms\"></iframe></div><!--kg-card-end: html-->"

# 2) Bold direct link to the full playlist (plain bold paragraph, not a heading).
HTML_BODY+="
<p><strong><a href=\"${PLAYLIST_WATCH_HTML}\">DIRECT LINK TO PLAYLIST</a></strong></p>"

# 3) The list of what's new (chronological). Also the email fallback for the
#    stripped embed above.
HTML_BODY+="
<h3><strong>List of Videos:</strong></h3>
<ul>"
for (( i=0; i<${#DIGEST_ROWS[@]}; i++ )); do
  row="${DIGEST_ROWS[$i]}"
  v_name="$(printf '%s' "$row" | json_get "['name']")"
  v_url="$(printf '%s'  "$row" | json_get "['url']")"
  v_chan="$(printf '%s' "$row" | json_get "['channel']")"
  v_name_html="$(printf '%s' "$v_name" | html_escape)"
  v_url_html="$(printf '%s'  "${v_url}?ref=${LINK_REF}" | html_escape)"
  v_chan_html="$(printf '%s' "$v_chan" | html_escape)"
  HTML_BODY+="
  <li><a href=\"${v_url_html}\">${v_name_html}</a> &mdash; ${v_chan_html}</li>"
done
HTML_BODY+="
</ul>"

EXCERPT="Watch all the non-main videos from the past week!"
TITLE_JSON="$(printf '%s' "$TITLE" | json_escape)"
HTML_JSON="$(printf '%s' "$HTML_BODY" | json_escape)"
EXCERPT_JSON="$(printf '%s' "$EXCERPT" | json_escape)"
TAG_JSON="$(printf '%s' "$GHOST_TAG" | json_escape)"
VISIBILITY_JSON="$(printf '%s' "$GHOST_VISIBILITY" | json_escape)"
if [[ -n "$FEATURE_IMAGE" ]]; then
  FEATURE_IMAGE_JSON="$(printf '%s' "$FEATURE_IMAGE" | json_escape)"
else
  FEATURE_IMAGE_JSON="null"
fi

# --- Create the draft ------------------------------------------------------
TOKEN="$(make_ghost_token)"
echo "Creating draft Ghost digest: $TITLE"

CREATE_RESPONSE="$(curl -s -w '\nHTTP_STATUS:%{http_code}\n' \
  -X POST "$GHOST_URL/ghost/api/admin/posts/?source=html" \
  -H "Authorization: Ghost $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"posts\": [{
      \"title\": $TITLE_JSON,
      \"html\": $HTML_JSON,
      \"custom_excerpt\": $EXCERPT_JSON,
      \"feature_image\": $FEATURE_IMAGE_JSON,
      \"tags\": [$TAG_JSON],
      \"status\": \"draft\",
      \"visibility\": $VISIBILITY_JSON
    }]
  }")"

CREATE_STATUS="$(printf '%s' "$CREATE_RESPONSE" | sed -n 's/^HTTP_STATUS://p')"
CREATE_BODY="$(printf '%s' "$CREATE_RESPONSE" | sed '/^HTTP_STATUS:/d')"

if [[ "$CREATE_STATUS" != "201" ]]; then
  echo "Ghost draft creation failed with HTTP $CREATE_STATUS"
  echo "$CREATE_BODY"
  exit 1
fi

if [[ "$TEST_MODE" -eq 1 ]]; then
  echo "TEST MODE: draft created. Not publishing, emailing, or marking seen."
  exit 0
fi

# --- Publish + email -------------------------------------------------------
POST_GHOST_ID="$(printf '%s' "$CREATE_BODY" | json_get "['posts'][0]['id']")"
UPDATED_AT="$(printf '%s'  "$CREATE_BODY" | json_get "['posts'][0]['updated_at']")"
UPDATED_AT_JSON="$(printf '%s' "$UPDATED_AT" | json_escape)"

echo "Publishing + emailing digest ..."
PUBLISH_RESPONSE="$(curl -s -w '\nHTTP_STATUS:%{http_code}\n' \
  -X PUT "$GHOST_URL/ghost/api/admin/posts/${POST_GHOST_ID}/?newsletter=${GHOST_NEWSLETTER_SLUG}&email_segment=${GHOST_EMAIL_SEGMENT}" \
  -H "Authorization: Ghost $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"posts\": [{
      \"updated_at\": $UPDATED_AT_JSON,
      \"status\": \"published\"
    }]
  }")"

PUBLISH_STATUS="$(printf '%s' "$PUBLISH_RESPONSE" | sed -n 's/^HTTP_STATUS://p')"
PUBLISH_BODY="$(printf '%s' "$PUBLISH_RESPONSE" | sed '/^HTTP_STATUS:/d')"

if [[ "$PUBLISH_STATUS" != "200" ]]; then
  echo "Ghost publish/email failed with HTTP $PUBLISH_STATUS"
  echo "$PUBLISH_BODY"
  exit 1
fi

# --- Only now mark the digest's videos as seen -----------------------------
for row in "${DIGEST_ROWS[@]}"; do
  uuid="$(printf '%s' "$row" | json_get "['uuid']")"
  echo "$uuid" >> "$SEEN_FILE"
done

echo "Done: added $COUNT video(s) to the playlist and emailed the digest."
