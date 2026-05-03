# Joel Kalich's Scripts for [Ghost](https://ghost.org/)

Scripts for extending [Ghost](https://ghost.org/) functionality on [Joel+](https://joelplus.com).

## Scripts

### `crosspost-youtube-posts.sh`

Checks YouTube for new Community posts and cross-posts them to Ghost.

#### Features

- Supports `--test` mode:
  - Creates a draft Ghost post only.
  - Does not add the YouTube post ID to the seen-posts file.
- Stores seen YouTube post IDs in a text file to prevent duplicate posts.
- Detects the YouTube post type and reflects it in the Ghost post title.
- Tags Ghost posts with a specified tag.
- Uses the first line of the YouTube post text as the Ghost subtitle.
- Embeds the YouTube post as a Ghost bookmark card.
- Extracts the first YouTube post image and uses it as the Ghost feature image.
- Notifies Ghost members via email by publishing a draft, then changing the post to published.

#### Known limitations

- There is no initialization mode yet.
  - On the first real run, the script may create Ghost posts for all detected YouTube Community posts.
  - For now, temporarily comment out the Ghost post creation section if you need to mark existing posts as seen without publishing them.
- It does not fully replicate YouTube Community posts inside Ghost.
  - Polls, quizzes, and other interactive post types are represented by metadata and a link to the original post.

### Setup

1. Edit the variables at the top of the script.
2. Set your YouTube channel ID.
   This is not your `@handle`. Use a YouTube channel ID finder if needed.
3. Set `SCRIPT_DIR` to the directory where the script lives.
4. Set `GHOST_URL` to your Ghost instance URL.
5. Create a Ghost Admin API key:
   `Ghost Admin → Settings → Integrations → Custom Integrations → Add Custom Integration`
   Then copy the Admin API key into the script.
6. Set your Ghost newsletter slug.
   If you use the default newsletter, the default value may already work.
7. Set the Ghost tag used for cross-posted YouTube posts.
8. Update the bookmark card URLs.
   Recommended:
   - Icon: YouTube logo
   - Thumbnail: default fallback image
9. Add a cron job to run the script automatically.
