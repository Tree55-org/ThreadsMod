# Save a Threads video

Patchlet `075-video-download` adds **Save video** to the native post menu for supported videos. Tap it, choose **Choose location**, then choose a filename and folder in [Android's save picker](https://developer.android.com/training/data-storage/shared/documents-files). The feature saves an MP4; it does not block the author or report the post.

Downloads use the video URL already carried by the displayed post. They run inside Threads 55 and do not require an external download service, account login elsewhere, or broad storage permission. Only reviewed Meta CDN HTTPS hosts are accepted. Expired links, unsupported media, failed downloads, or videos over 256 MiB produce a fixed failure message; no download is retried automatically.

This resolution supports direct video posts with a progressive MP4 rendition. It selects the valid rendition with the largest bounded pixel area when dimensions are available. Image posts, video carousels, and posts with only adaptive-streaming manifests are not supported by this hook.

Keep the save screen open until it confirms success. Cancellation and screen destruction stop the worker. A failed save tries to remove the incomplete destination; if the chosen provider refuses deletion, or Android terminates the process during copying, remove that file through your file manager. Private cache leftovers are cleaned on the next explicit save. Android's picker can also expose cloud providers; choosing one authorizes writing the video there.

This feature is under review. The currently published September 6 APK predates it. A rebuilt SignedReview candidate is a work artifact, and neither static checks nor the isolated save-screen probe prove live-feed selection or a real video download. Exact candidate paths, hashes, and completed checks are recorded in the resolution evidence when available.

Implementation and ownership: [patchlet 075](../patchlets/features/075-video-download/PATCHLET.md). Rebuilding follows the [patchlet workflow](08-AI-DRIVEN-PATCHLETS.md). New Threads APKs require a fresh exact-SHA menu/video resolution; a filename or version name alone never grants compatibility.
