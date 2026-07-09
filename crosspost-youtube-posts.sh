#!/usr/bin/env bash
set -euo pipefail

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

CHANNEL_ID="${YOUTUBE_CHANNEL_ID:-}"
SEEN_FILE="$SCRIPT_SOURCE_DIR/seen-youtube-post-ids.txt"

GHOST_URL="${GHOST_URL:-}"
GHOST_ADMIN_KEY="${GHOST_ADMIN_KEY:-}"
GHOST_NEWSLETTER_SLUG="${GHOST_NEWSLETTER_SLUG:-default-newsletter}"
GHOST_TAG="${YOUTUBE_GHOST_TAG:-YT Community Posts}"
GHOST_VISIBILITY="${YOUTUBE_GHOST_VISIBILITY:-public}"

# Newsletter audience. Defaults to match the post's visibility so the email
# reaches the same people who can see the post (paid -> paid members only,
# otherwise -> all members). Override independently with
# YOUTUBE_GHOST_EMAIL_SEGMENT (all / status:free / status:-free).
case "$GHOST_VISIBILITY" in
  paid) DEFAULT_EMAIL_SEGMENT="status:-free" ;;
  *)    DEFAULT_EMAIL_SEGMENT="all" ;;
esac
GHOST_EMAIL_SEGMENT="${YOUTUBE_GHOST_EMAIL_SEGMENT:-$DEFAULT_EMAIL_SEGMENT}"

BOOKMARK_ICON="${YOUTUBE_BOOKMARK_ICON:-https://joelplus.com/YT-Icon.png}"
BOOKMARK_THUMBNAIL="${YOUTUBE_BOOKMARK_THUMBNAIL:-https://joelplus.com/default-thumbnail-thing}"

for var in CHANNEL_ID GHOST_URL GHOST_ADMIN_KEY; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: $var is not set. Copy .env.example to .env (next to this script) and fill it in." >&2
    exit 1
  fi
done

# Bare host of the Ghost instance (e.g. "joelplus.com"), used to detect
# community posts that link back to the site and to tag outbound YouTube URLs.
GHOST_DOMAIN="${GHOST_URL#*://}"
GHOST_DOMAIN="${GHOST_DOMAIN%%/*}"

touch "$SEEN_FILE"

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

html_escape() {
  python3 -c 'import html,sys; print(html.escape(sys.stdin.read().strip(), quote=True))'
}

json_get() {
  python3 -c "import json,sys; print(json.load(sys.stdin)$1)"
}

truncate_300() {
  python3 -c 'import sys; print(sys.stdin.read().strip()[:300])'
}

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

if [[ "$TEST_MODE" -eq 1 ]]; then
  echo "TEST MODE: posts will be created as drafts only. No publishing, no emails."
fi

HTML="$(curl -L -s "https://www.youtube.com/channel/${CHANNEL_ID}/posts")"

HTML_TMP="$(mktemp)"
printf '%s' "$HTML" > "$HTML_TMP"

mapfile -t POST_ROWS < <(
  python3 - "$HTML_TMP" "$GHOST_DOMAIN" <<'PY'
import html as html_lib
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    html = f.read()

ghost_domain = sys.argv[2].lower()

matches = list(re.finditer(r'postId":"([^"]+)"', html))
seen = set()

def detect_post_type(block, image_candidates):
    b = block.lower()

    quiz_markers = [
        "quizrenderer",
        "quizquestion",
        "correctanswer",
        "correct_answer",
    ]

    poll_markers = [
        "pollrenderer",
        "pollstatusrenderer",
        "pollchoice",
        "pollchoiceborder",
        "pollheader",
    ]

    image_poll_markers = [
        "imagepoll",
        "image_poll",
        "postimagepoll",
        "pollimage",
        "pollthumbnail",
    ]

    if any(marker in b for marker in quiz_markers):
        return "quiz"

    is_poll = any(marker in b for marker in poll_markers)

    if is_poll:
        if any(marker in b for marker in image_poll_markers):
            return "image_poll"

        large_image_count = len([x for x in image_candidates if x[0] >= 200 * 100])
        if large_image_count >= 2:
            return "image_poll"

        return "poll"

    return "post"

for idx, match in enumerate(matches):
    post_id = match.group(1)

    if post_id in seen:
        continue
    seen.add(post_id)

    start = match.start()
    end = matches[idx + 1].start() if idx + 1 < len(matches) else len(html)
    block = html[start:end]

    first_line = "YouTube Community Post"

    text_match = re.search(r'"contentText":\{"runs":(\[.*?\])\}', block)
    if text_match:
        try:
            runs = json.loads(text_match.group(1))
            text = "".join(run.get("text", "") for run in runs)
            if text.strip():
                first_line = text.strip().splitlines()[0]
        except Exception:
            pass

    candidates = []

    for m in re.finditer(r'"url":"(https:[^"]+)"(?:[^{}]{0,300}?"width":(\d+))?(?:[^{}]{0,300}?"height":(\d+))?', block):
        raw_url = m.group(1)

        try:
            url = json.loads(f'"{raw_url}"')
        except Exception:
            url = raw_url.replace("\\u0026", "&").replace("\\/", "/")

        url = html_lib.unescape(url)

        width = int(m.group(2) or 0)
        height = int(m.group(3) or 0)

        if not (
            "ytimg.com" in url
            or "ggpht.com" in url
            or "googleusercontent.com" in url
        ):
            continue

        if any(bad in url.lower() for bad in ["favicon", "avatar"]):
            continue

        if width and height and (width < 200 or height < 100):
            continue

        score = width * height
        candidates.append((score, url))

    image_url = ""
    if candidates:
        candidates.sort(reverse=True)
        image_url = candidates[0][1]

    post_type = detect_post_type(block, candidates)

    has_ghost_domain_link = bool(ghost_domain) and ghost_domain in block.lower()

    print(json.dumps({
        "post_id": post_id,
        "first_line": first_line,
        "image_url": image_url,
        "post_type": post_type,
        "has_ghost_domain_link": has_ghost_domain_link,
    }, ensure_ascii=False))
PY
)

rm -f "$HTML_TMP"

if [[ "${#POST_ROWS[@]}" -eq 0 ]]; then
  echo "No YouTube Community posts found."
  exit 1
fi

TOKEN="$(make_ghost_token)"
NEW_COUNT=0

for (( i=${#POST_ROWS[@]}-1; i>=0; i-- )); do
  ROW="${POST_ROWS[$i]}"

  POST_ID="$(printf '%s' "$ROW" | json_get "['post_id']")"
  RAW_FIRST_LINE="$(printf '%s' "$ROW" | json_get "['first_line']")"
  POST_IMAGE_URL="$(printf '%s' "$ROW" | json_get "['image_url']")"
  POST_TYPE="$(printf '%s' "$ROW" | json_get "['post_type']")"
  HAS_GHOST_DOMAIN_LINK="$(printf '%s' "$ROW" | json_get "['has_ghost_domain_link']")"

  if grep -Fxq "$POST_ID" "$SEEN_FILE"; then
    continue
  fi

  if [[ "$INIT_MODE" -eq 1 ]]; then
    echo "INIT: marking $POST_ID as seen (no Ghost post created)"
    echo "$POST_ID" >> "$SEEN_FILE"
    continue
  fi

  RAW_FIRST_LINE="${RAW_FIRST_LINE:-View this YouTube Community post.}"
  POST_IMAGE_URL="${POST_IMAGE_URL:-}"
  POST_TYPE="${POST_TYPE:-post}"

  case "$POST_TYPE" in
    poll)
      TITLE="New YouTube Community Poll"
      TYPE_LABEL="Poll from Joel Kalich"
      ;;
    image_poll)
      TITLE="New YouTube Community Image Poll"
      TYPE_LABEL="Image poll from Joel Kalich"
      ;;
    quiz)
      TITLE="New YouTube Community Quiz"
      TYPE_LABEL="Quiz from Joel Kalich"
      ;;
    *)
      TITLE="New YouTube Community Post"
      TYPE_LABEL="Post from Joel Kalich"
      ;;
  esac

  if [[ "$HAS_GHOST_DOMAIN_LINK" == "True" ]]; then
    echo "Ignoring post because it links to $GHOST_DOMAIN: https://www.youtube.com/post/$POST_ID"
    echo "$POST_ID" >> "$SEEN_FILE"
    continue
  fi

  EXCERPT="$(printf '%s' "$RAW_FIRST_LINE" | truncate_300)"
  EXCERPT_HTML="$(printf '%s' "$EXCERPT" | html_escape)"

  POST_URL="https://www.youtube.com/post/${POST_ID}?ref=${GHOST_DOMAIN}"
  POST_URL_HTML="$(printf '%s' "$POST_URL" | html_escape)"
  TYPE_LABEL_HTML="$(printf '%s' "$TYPE_LABEL" | html_escape)"

  THUMBNAIL_FOR_CARD="$BOOKMARK_THUMBNAIL"
  if [[ -n "$POST_IMAGE_URL" ]]; then
    THUMBNAIL_FOR_CARD="$POST_IMAGE_URL"
    echo "Detected $POST_TYPE with YouTube image for cover: $POST_IMAGE_URL"
  else
    echo "Detected $POST_TYPE with no YouTube image: $POST_URL"
  fi

  THUMBNAIL_FOR_CARD_HTML="$(printf '%s' "$THUMBNAIL_FOR_CARD" | html_escape)"

  HTML_BODY="
<figure class=\"kg-card kg-bookmark-card\">
  <a class=\"kg-bookmark-container\" href=\"${POST_URL_HTML}\">
    <div class=\"kg-bookmark-content\">
      <div class=\"kg-bookmark-title\">${TYPE_LABEL_HTML}</div>
      <div class=\"kg-bookmark-description\">${EXCERPT_HTML}</div>
      <div class=\"kg-bookmark-metadata\">
        <img class=\"kg-bookmark-icon\" src=\"${BOOKMARK_ICON}\" alt=\"\">
        <span class=\"kg-bookmark-author\">YouTube</span>
        <span class=\"kg-bookmark-publisher\">Joel Kalich</span>
      </div>
    </div>
    <div class=\"kg-bookmark-thumbnail\">
      <img src=\"${THUMBNAIL_FOR_CARD_HTML}\" alt=\"\" onerror=\"this.style.display = 'none'\">
    </div>
  </a>
</figure>"

  TITLE_JSON="$(printf '%s' "$TITLE" | json_escape)"
  HTML_JSON="$(printf '%s' "$HTML_BODY" | json_escape)"
  EXCERPT_JSON="$(printf '%s' "$EXCERPT" | json_escape)"
  TAG_JSON="$(printf '%s' "$GHOST_TAG" | json_escape)"
  VISIBILITY_JSON="$(printf '%s' "$GHOST_VISIBILITY" | json_escape)"

  if [[ -n "$POST_IMAGE_URL" ]]; then
    FEATURE_IMAGE_JSON="$(printf '%s' "$POST_IMAGE_URL" | json_escape)"
  else
    FEATURE_IMAGE_JSON="null"
  fi

  echo "Creating draft Ghost post for: $POST_URL"
  echo "Title: $TITLE"

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
    echo "TEST MODE: draft created only. Not publishing or emailing."
    echo "TEST MODE: not adding $POST_ID to $SEEN_FILE"
    NEW_COUNT=$((NEW_COUNT + 1))
    continue
  fi

  POST_GHOST_ID="$(printf '%s' "$CREATE_BODY" | json_get "['posts'][0]['id']")"
  UPDATED_AT="$(printf '%s' "$CREATE_BODY" | json_get "['posts'][0]['updated_at']")"
  UPDATED_AT_JSON="$(printf '%s' "$UPDATED_AT" | json_escape)"

  echo "Publishing and emailing Ghost post: $POST_URL"

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

  echo "$POST_ID" >> "$SEEN_FILE"
  NEW_COUNT=$((NEW_COUNT + 1))
done

if [[ "$NEW_COUNT" -eq 0 ]]; then
  if [[ "$INIT_MODE" -eq 1 ]]; then
    echo "INIT: no new post IDs found to mark."
  else
    echo "No new YouTube Community posts."
  fi
elif [[ "$TEST_MODE" -eq 1 ]]; then
  echo "TEST MODE: created $NEW_COUNT draft Ghost post(s). No emails sent."
elif [[ "$INIT_MODE" -eq 1 ]]; then
  echo "INIT: marked $NEW_COUNT YouTube post ID(s) as seen. No Ghost posts created."
else
  echo "Created and emailed $NEW_COUNT Ghost post(s)."
fi
