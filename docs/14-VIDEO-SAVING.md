# Save a Threads video

Patchlet `075-video-download` adds **Save video** to the native post menu for supported videos. Tap it, choose **Choose location**, then choose a filename and folder in [Android's save picker](https://developer.android.com/training/data-storage/shared/documents-files). The feature saves an MP4; it does not block the author or report the post.

Downloads use the video URL already carried by the displayed post. They run inside Threads 55 and do not require an external download service, account login elsewhere, or broad storage permission. Only reviewed Meta CDN HTTPS hosts are accepted. Expired links, unsupported media, failed downloads, or videos over 256 MiB produce a fixed failure message; no download is retried automatically.

This resolution supports direct video posts with a progressive MP4 rendition. It selects the valid rendition with the largest bounded pixel area when dimensions are available. Image posts, video carousels, and posts with only adaptive-streaming manifests are not supported by this hook.

Keep the save screen open until it confirms success. Cancellation and screen destruction signal the worker to stop; a document provider may ignore cancellation or cleanup. A failed save tries to remove the incomplete destination; if the chosen provider refuses deletion, or Android terminates the process during copying, remove that file through your file manager. Private cache leftovers are cleaned on the next explicit save. Android's picker can also expose cloud providers; choosing one authorizes writing the video there.

This feature is included in [mod build 2](https://github.com/Tree55-org/ThreadsMod/releases/tag/threads55-444.0.0.45.85-mod2), published locally to `dist/` on 2026-10-10. Validation includes 229 offline harness assertions, static signed-APK gates, and four Activity screens in an isolated no-permission emulator probe. These checks do not prove native menu selection in a live feed, real CDN downloads, document-provider writes, or playback. The published APK has not been installed or started on a device. Exact review and Release evidence is recorded in the [resolution evidence](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md); signed updater metadata has not been deployed.

Implementation and ownership: [patchlet 075](../patchlets/features/075-video-download/PATCHLET.md). Rebuilding follows the [patchlet workflow](08-AI-DRIVEN-PATCHLETS.md). New Threads APKs require a fresh exact-SHA menu/video resolution; a filename or version name alone never grants compatibility.
