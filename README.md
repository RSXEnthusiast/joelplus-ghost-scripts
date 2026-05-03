# Joel Kalich's Scripts for [Ghost](https://ghost.org/)

Scripts for extending [Ghost](https://ghost.org/) functionality on [Joel+](https://joelplus.com).

## Scripts

### `crosspost-youtube-posts.sh`

Checks YouTube for new Community posts and cross-posts them to Ghost.

#### Features

- Supports `--test` mode:
  - Creates a draft Ghost post only.
  - Does not add the YouTube post ID to the seen-posts file.
- Supports `--init` mode:
  - Creates the seen posts file.
  - Populates file with existing YouTube posts.
  - Does not make any posts to Ghost.
- Stores seen YouTube post IDs in a text file to prevent duplicate posts.
- Detects the YouTube post type and reflects it in the Ghost post title.
- Tags Ghost posts with a specified tag.
- Uses the first line of the YouTube post text as the Ghost subtitle.
- Embeds the YouTube post as a Ghost bookmark card.
- Extracts the first YouTube post image and uses it as the Ghost feature image.
- Notifies Ghost members via email by publishing a draft, then changing the post to published.

#### Known limitations

- It does not fully replicate YouTube Community posts inside Ghost.
  - Polls, quizzes, and other interactive post types would be silly to replicate, so instead it just links to YouTube.

### Setup

**Edit the variables at the top of the script:**

1. Set your YouTube channel ID.
   This is not your `@handle`. Use a YouTube channel ID finder if needed.
2. Set `SCRIPT_DIR` to the directory where the script lives.
3. Set `GHOST_URL` to your Ghost instance URL.
4. Create a Ghost Admin API key:
   `Ghost Admin → Settings → Integrations → Custom Integrations → Add Custom Integration`
   Then copy the Admin API key into the script.
5. Set your Ghost newsletter slug.
   If you use the default newsletter, the default value may already work.
6. Set the Ghost tag used for cross-posted YouTube posts.
7. Update the bookmark card URLs.
   - Icon: YouTube logo
   - Thumbnail: default fallback image
8. Run the script in --init mode to populate post IDs.
9. Create a new YouTube community post.
10. Run the script in --test mode to ensure it makes a post to your Ghost instance.
11. Add a cron job to run the script automatically.
