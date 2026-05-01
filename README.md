# joelplus-ghost-scripts
Any scripts I've written to extend Ghost functionality for Joel+

### check-youtube-post.sh

This file will check YouTube for a new community post. If it finds one, it will crosspost that post to Ghost.

Features:
* Use --test with the file to instead make a draft post to Ghost, and not add the file to the list of seen posts.
* Stores seen posts in a text file so it won't make duplicate posts.
* Will detect the type of YouTube post, and reflect that in the title on Ghost.
* Will tag the Ghost post as YT Community Post.
* Extracts the first line of text for the sub-title in Ghost.
* Embeds the YouTube post as a nice bookmark card in Ghost.
* Extracts the first image of the YouTube post to use as the cover image in Ghost.
* Notifies members on Ghost via email by first publishing a draft, then changing the post to public.

Known Limitations:
* There is no --init tag or anything like that. The first time the sript runs, it will create a new Ghost post for all found YouTube Community Posts.
  * For now, I would suggest simply commenting out the portion of the script that creates a post on Ghost.
* It doesn't do a full crosspost to Ghost, as replicating polls and such would be impossible. It just grabs specific information, and links to the original post.

Steps to set it up:
* At the top are variables. Change them to match your channel.
* Change the channel ID to your YouTube channel ID.
  * This is not simply your @ handle. You can use a free online channel ID finder to find yours.
* Change the script directory to match where the script is.
* Change the ghost url to match your Ghost instance.
* Get a Ghost API key from Ghost Admin Panel -> Integrations -> Custom Integrations -> Add Custom Integration. Replace this in the file.
* Replace the newsletter slug with the one from your newsletter.
  * If you are using the default, then you probably don't need to change it.
  * If you want to check, you can by using the inspector network panel and poking around the newsletter admin setting until the slug pops up.
* Change the tag to whatever you want.
* Change the URLs for the bookmark cards. The icon should be a youtube logo and the thumbnail should be a default thumbnail image.
* Add a cron job to run the script in the background.
