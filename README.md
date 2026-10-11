# IINA Immersive 3D

A GPLv3 fork of [IINA](https://github.com/iina/iina) v1.5.0 for an Apple Silicon Mac and TCL NXTWEAR S glasses. It adds a live 2D-to-3D mode: each decoded frame gets a monocular depth map, a Metal shader shifts the picture into a full-frame side-by-side pair, and **Play on Glasses** puts that pair on the glasses display. It also adds an IPTV window for your own M3U playlists and Xtream Codes logins.

Upstream IINA, Collider LI's copyright, and the GPLv3 `LICENSE` are unchanged. See `NOTICE`. Depth weights are not in git. Nothing here comes from VITURE SpaceWalk.

The rest of this file, below the Immersive 3D section, is IINA's own readme.

## What was and was not verified

This tree was written on a Linux cloud VM, so it was not launched there. No Core ML conversion was executed, and no M2 timing was measured. The Swift and Metal below are integrated into the v1.5.0 project file. Xcode 15.2 cannot compile that project: the asset catalogs use template format 7.0, which needs Xcode 16 or newer. The **macOS Release** workflow is the compile, on a hosted Apple Silicon runner. Treat a compiler error as a bug in this fork.

The IPTV window, the guide grid, Keychain access, and HTTP catalog calls were not run. A Python transcription of the M3U line rules, the XMLTV timestamp offset, the listing window, now/next selection, the Xtream stream-URL assembly, and the catch-up URL rules (Xtream `/timeshift/…`, M3U `default` / `append` / `shift` / Flussonic / `xc`, placeholder order, and the archive-day window) was executed against sample strings. A second transcription checked `get_vod_info` / `get_series_info` field priority, trailer and year parsing, TMDB gap-fill (empty fields only), and the resume thresholds. Those scripts are not part of the app, and they are not a substitute for compiling the Swift.

## Download a prebuilt app

macOS 13.7 with Xcode 15.2 cannot compile this tree. [Actions → macOS Release](https://github.com/iansutherland74/iina-immersive-3d/actions/workflows/macos-release.yml) builds a Release `IINA.app` for Apple Silicon on GitHub's `macos-26` runner. The job selects the latest stable Xcode 16 or newer with `sudo xcode-select`. It runs on every push to `main`, and it can be started by hand (`workflow_dispatch`).

1. Open the newest successful **macOS Release** run on `main`.
2. Download the **`IINA-macos-arm64.zip`** artifact. The workflow zips `IINA.app` with `ditto` and uploads that zip as the artifact, so one unzip produces the app.
3. Unzip it.

The app is ad-hoc signed (`CODE_SIGN_IDENTITY=-`), not notarized. A normal double-click of a downloaded copy is blocked by quarantine. Right-click `IINA.app`, choose **Open**, then **Open** again. Or clear the quarantine flag:

```console
xattr -dr com.apple.quarantine /path/to/IINA.app
```

### macOS 13.7

`Configs/Deployment.xcconfig` sets `MACOSX_DEPLOYMENT_TARGET` to 12, and `Info.plist` publishes that as `LSMinimumSystemVersion`. macOS 13.7.8 is above 12, so the system allows the app to start. The arm64 `libmpv` that `other/download_libs.sh` fetches from iina.io declares a minimum of macOS 11.0, so dyld will load it on 13.7. A float16 model converted for macOS 13 (the 364×280 package) loads on 13.7. Apple's published Depth Anything package is an ios17 specialization and needs macOS 14 or later. Compiling with the Xcode 26 SDK does not raise the deployment target. Each run prints `vtool -show-build` for `IINA` and the bundled libraries.

## Build and run on an M2 Mac

1. Install the latest public Xcode from the App Store, and open it once so the command-line tools are in place.
2. In this directory, fetch the arm64 mpv libraries and yt-dlp (online playback uses that yt-dlp, the same way upstream IINA does):

   ```console
   ./other/download_libs.sh --arch arm64
   ```

3. Put a depth model in place. Depth Anything V2 Small is the default; see the next section. The app launches without a model, and asks for one when Immersive 3D is turned on.
4. Open `iina.xcodeproj`. Select the **IINA** scheme and **My Mac**. The deployment target is macOS 12. A macOS 13 depth conversion needs **macOS 13 or later**. Apple's published package needs **macOS 14 or later**.
5. Run. The first build compiles the new `iina/Immersive3D` sources (`Immersive3DController.swift`, `DepthEstimator.swift`, `Immersive3DCompositor.swift`, `Immersive3D.metal`) and the IPTV sources under `iina/IPTV` (`IPTVModels.swift`, `IPTVParsers.swift`, `IPTVLibrary.swift`, `IPTVGuideView.swift`, `IPTVTitles.swift`, `IPTVPosterView.swift`, `IPTVWindowController.swift`, `IPTVLiveOverlay.swift`, `IPTVBrowseOverlay.swift`). `GlassesEyeControls.swift` lives next to the other Immersive 3D sources. `other/download_libs.sh` also builds whisper.cpp v1.7.6 into `deps/lib/libiina_whisper.dylib` (Metal, with Core ML compiled in when that build succeeds). It does not download speech models.

Product name and bundle id stay `IINA` / `com.colliderli.iina`, so this build uses the same Application Support folder as a stock IINA install. Quit a stock IINA before launching this one if both are installed.

## Depth models

The picker is **Settings → Video → Depth Model**, and the same choice is **Video → Depth Model** while a window is open. Changing it reloads the network. `IINA_DEPTH_MODEL=/path/to/file.mlpackage` overrides the picker for that launch.

Both models are open source (Apache-2.0). The player looks in `~/Library/Application Support/com.colliderli.iina/Models/` and uses the first file that exists, in this order:

| Choice | Preferred package | Then |
| --- | --- | --- |
| Depth Anything V2 Small (default) | `DepthAnythingV2SmallF16-364x280.mlpackage` | `DepthAnythingV2SmallF16.mlpackage`, then the F16P6 package |
| Depth Anything 3 Small | `DepthAnything3SmallF16-364x280.mlpackage` | `DepthAnything3SmallF16-504x504.mlpackage`, then `DepthAnything3SmallF16.mlpackage` |

Any other `.mlpackage` in that folder whose name starts with `DepthAnythingV2` or `DepthAnything3` is a last resort for that family.

### Depth Anything V2 Small (default)

Apple publishes a Core ML conversion. It is a **fixed 518×392** RGB input and a float16 grayscale depth **image**. That package is an **ios17** specialization and needs **macOS 14 or later**. The player compiles a `.mlpackage` with `MLModel.compileModel(at:)` on a background queue and caches the `.mlmodelc` next to it under `Models/`, recompiling when the package is newer. Fetch Apple's package (about 50 MB, not committed):

```console
python3 -m pip install --user huggingface_hub
./other/fetch_depth_model.sh
```

`--p6` fetches the smaller palettized package instead. Both Apple packages need macOS 14. A 364×280 model is a better real-time size, and it is the one that loads on macOS 13. Apple's package cannot be resized at runtime, so that size has to be converted from the Apache-2.0 checkpoint with a macOS 13 deployment target. The converted package takes an `image` input (364×280 RGB) and returns `depth` as a float16 `MLMultiArray` of shape `[1, 1, 280, 364]`, which the player reads with the array's strides:

```console
git clone https://github.com/DepthAnything/Depth-Anything-V2 /tmp/Depth-Anything-V2
curl -L -o /tmp/depth_anything_v2_vits.pth \
  https://huggingface.co/depth-anything/Depth-Anything-V2-Small/resolve/main/depth_anything_v2_vits.pth
python3 -m pip install --user torch coremltools
python3 other/convert_depth_anything_v2.py \
  --repo /tmp/Depth-Anything-V2 \
  --checkpoint /tmp/depth_anything_v2_vits.pth \
  --width 364 --height 280
```

That conversion script was **not run** here.

### Depth Anything 3 Small

[DA3-SMALL](https://huggingface.co/depth-anything/DA3-SMALL) (Apache-2.0, code at [ByteDance-Seed/depth-anything-3](https://github.com/ByteDance-Seed/depth-anything-3)) has no official Core ML build. `other/convert_depth_anything_3.py` exports the monocular relative-depth output with coremltools: ImageNet normalization inside the graph, one view, camera decoder and sky post-process left out, and the DualDPT auxiliary ray head left out when the module still matches the script. Default spatial size is the upstream **504×504**. Pass `--width 364 --height 280` for the smaller real-time attempt.

```console
git clone https://github.com/ByteDance-Seed/depth-anything-3 /tmp/depth-anything-3
python3 -m pip install --user -e /tmp/depth-anything-3
python3 -m pip install --user coremltools torch
python3 other/convert_depth_anything_3.py
```

**This conversion was not tested.** It was not run against the weights, and coremltools was not asked to lower the ViT. RoPE's data-dependent table length is patched to a constant before tracing; scaled-dot-product attention and `einops` still have to convert. If tracing fails, the script exits and prints the exception.

**Expected speed on an M2, not measured:** V2 Small stays the default because it is the smaller, already-converted network. DA3-SMALL is the same class of ViT-S (about 34M parameters for the depth path; the model card says 0.08B for the full checkpoint) but the 504×504 export has more pixels than Apple's 518×392 V2 package (254016 vs 203056) and a heavier dense head. Expect DA3 at 504² to update depth less often than V2 at 518×392, with the player holding the previous map between updates. A 364×280 DA3 export should be closer to the V2 real-time size, at a quality cost that was also not measured. Inference is off the video thread either way, so a slow model drops depth updates instead of stalling playback.

## Using Immersive 3D

Open a local file or an online URL (yt-dlp, already part of IINA). Then:

- **Video → Immersive 3D** turns conversion on. The frame is read after mpv has drawn it, including burned-in subtitles, and replaced with side-by-side stereo. Soft / Standard / Enhanced and the slider live under **Video → Depth Strength**.
- Files whose names contain `sbs`, `half-sbs`, `full-sbs`, or `side-by-side` are passed through unchanged while the source mode is Automatic. **Video → Source Is Side-by-Side** can force pass-through or force conversion.
- **Video → Play on Glasses** looks for a display named SmartGlasses or NXTWEAR, including when that display is the main screen. Otherwise it uses an external 3840×1080 or 1920×1080 display. The video window becomes a borderless window at shielding level (above normal windows). Its frame is that screen's full `NSScreen.frame` in global desktop coordinates, origin included — an extended SmartGlasses display is not at (0, 0); the measured 3D frame is (1512, −98) and 3840×1080. There is no menu-bar, notch, or title-bar inset, and the window uses `canJoinAllSpaces` / `fullScreenAuxiliary`. It draws at the screen's backing pixel size and stays pinned there when the resolution changes (`didChangeScreenParametersNotification`). On the measured NXTWEAR S, 2D mode is 1920×1080 at scale 1 and the picture is half side-by-side; after the long-press, 3D mode is 3840×1080 at scale 1 and each eye is drawn at 1920×1080 into its half. In side-by-side 3D, moving the mouse or trackpad on the glasses shows the player controls in both eye halves at the same place: play/pause, seek bar, volume, an Immersive 3D toggle, and, while a live channel is playing, channel-list and guide buttons. They hide after the usual control-bar timeout (and stay up while the pointer is on the bar, the same way IINA's controller does). The system pointer is hidden over that window and a cursor is drawn in each half, so a click lands on the control under that cursor. A flat 2D picture still leaves the controller hidden. A small panel says to long-press the right-side button until the display widens, and switches to the full-half message once it does. That panel also has play/pause, the strength slider, and Exit. **Settings → Video → Automatically set up glasses display** (on by default) uses `CGBeginDisplayConfiguration`, `CGConfigureDisplayMirrorOfDisplay(..., kCGNullDirectDisplay)`, and `CGCompleteDisplayConfiguration(..., .forSession)` to leave a mirrored pair as an extended desktop for this login session. Play on Glasses restores the original mirroring when it stops, and it checks again after a 2D/3D mode change because mirroring can come back. The arrangement is not written as the permanent display configuration.
- **Invert Depth** swaps near and far. **Flip 3D Picture Vertically** is there if the picture comes out upside down; the OpenGL framebuffer and the Metal shader do not agree on which row is the top, and that toggle is the escape hatch. It was not confirmed on hardware.

Depth runs at the model's fixed size (518×392 for Apple's package, or whatever size you converted). Similar frames reuse the last map, and successive maps are smoothed so the stereo does not flicker. Until the first map arrives, the shift uses a flat depth so the layout is already side-by-side.

## WebDAV

The WebDAV browser is a JavaScript plugin in `plugins/iina-plugin-webdav`. It is not compiled into IINA. **Plugins → WebDAV Browser** (or the WebDAV sidebar tab) lists a folder with `PROPFIND` and plays a video with `iina.core.open`, so **Immersive 3D** and **Play on Glasses** apply the same way they do for any other URL.

**Settings → Plugins → Install Local Package…** takes the `iina-plugin-webdav-1.0.0.iinaplgz` artifact from the macOS Release run. **Get Plugins…** installs a GitHub repository that has `Info.json` at its root, or a release asset ending in `.iinaplgz`. This plugin is a folder inside the player repository, so that GitHub install does not see it. Use the package file. The plugin asks for network access to any host, because the server address is typed in later.

FebBox's WebDAV address is `https://webdav.febbox.com` (create the account in the FebBox console; add the effective path if one is shown). Nextcloud is `https://host/remote.php/dav/files/USERNAME/`. A NAS can be `http://` on the local network; the sidebar says the password is then unencrypted. The username and server address are plugin preferences. The password goes to the Keychain through `iina.utils.keychainWrite`. If that write fails, the sidebar says so and the password stays in memory until IINA quits. It is not stored in the preference file.

Folders and video files are shown. Other files are left out. Play sets mpv `http-header-fields` to `Authorization: Basic …` and opens the file URL with no user and no password in it, so history does not receive the password. The header stays while that host is the current file and is restored when another host starts. Opening the same URL again from history does not send the password; play it from the sidebar. `iina.http.get` and `post` cannot send `PROPFIND`. `iina.http.request` does. The debug log hides the header value.

## Remote files

`plugins/iina-plugin-remote-files` is a second JavaScript plugin, also not compiled into the player. It keeps one saved list for WebDAV, FTP, FTPS, SMB, SFTP, Jellyfin, Emby, Plex, and DLNA. Each entry is a name, a protocol, an address, and a username. The password goes to the Keychain under that server's id (`remote-files`). If the Keychain write fails, the sidebar says so and the password stays in memory until IINA quits. It is not written into the server list. Details and the limits of each protocol are in `plugins/iina-plugin-remote-files/README.md`.

WebDAV browsing is a `PROPFIND` through `iina.http.request`. `get` and `post` cannot send that method. FTP and FTPS listings use `/usr/bin/curl` with the password in a temporary config file, not on the command line. SMB is listed by `/sbin/mount_smbfs` onto a folder in the plugin temp directory and played as that local path. The password is inside the mount script; `mount_smbfs` still has it in its arguments while the mount starts. SFTP is listed by `/usr/bin/sftp` with the password in an `SSH_ASKPASS` script, and played as `sftp://user:password@host/path` through mpv `loadfile`. Jellyfin and Emby use `AuthenticateByName`, library items, posters, and `/Videos/…/stream`. Plex uses a plex.tv sign-in or a pasted token, library metadata, posters, and the file part URL. DLNA is an SSDP description URL plus a ContentDirectory `Browse`. Discovery also browses Bonjour for Plex, Jellyfin, Emby, SMB, and SFTP.

Folders and videos are shown. Search filters the open folder by name. Sort is name (natural, so Episode 2 precedes Episode 10), date, or size. A matching subtitle next to the video (`Movie.srt`, `Movie.en.ass`, `Movie.vtt`, `Movie.ssa`) is added with mpv `sub-add` after the file loads. If none matches, an optional OpenSubtitles API key searches by file name. Jellyfin, Emby, and Plex rows do not include those sidecar files. **Play folder** starts the first video in name order, and the next one starts at the end unless **Next episode** is off. Resume (5 seconds or later, and not in the last 30 seconds or the last 5%), the last 40 plays, and favourites are plugin preferences. Jellyfin, Emby, and Plex also receive the position.

Install `iina-plugin-remote-files-1.1.0.iinaplgz` from the macOS Release artifacts with **Settings → Plugins → Install Local Package…**. **Get Plugins…** does not see this folder. FebBox's WebDAV address is `https://webdav.febbox.com`. Nextcloud is `https://host/remote.php/dav/files/USERNAME/`.

The plugin was not installed in IINA. No server was contacted, and the Keychain was not written. The listing, address, sort, resume, and shell-script checks were run locally.

## IPTV

**File → IPTV…** (Option-Command-I) opens a TV-style browser. It is not a sidebar tab. Playback goes through the normal player, so **Video → Immersive 3D** and **Play on Glasses** apply to these streams the same way they apply to any other URL.

While a live channel is playing, a TV overlay is drawn on the player window itself, including the glasses window, and the stream keeps running underneath it. It hides on its own. With the list and guide closed, **↑ / ↓**, **Page Up / Page Down**, the scroll wheel, and the remote next/previous keys change channel inside the current group (Page Up/Down jumps by 10). **0–9** tunes that channel number, from the top of the live list. **Delete** toggles the previous channel, unless a number is being typed, in which case it deletes a digit. **Return**, **Enter**, or a click opens the channel list for the current group (number, logo, name, now, and next). While that list or the guide is open it takes the keys: **↑ / ↓** and **Page Up / Page Down** move the highlight and scroll it into view, **← / →** change group in the list or move in time on the guide, the scroll wheel moves that same highlight, and hovering a row highlights it. **Return**, **Enter**, or a click plays the highlighted channel, or the highlighted programme live or from the start when catch-up is available. **Esc** or **Delete** closes the list or guide. **G** or the Guide button opens the full programme grid. On the glasses, a side-by-side picture (Immersive 3D, or a source that is already side-by-side) draws that same overlay into each eye half, at the same place in both halves, and the hover and click use the half under the pointer. The glasses window is borderless, so it is made key (`canBecomeKey` / `canBecomeMain`, `makeKeyAndOrderFront`) or the overlay would not see the keyboard. A flat 2D picture gets one overlay across the window. The player controls follow that same split when the pointer moves on the glasses. Navigation keys are logged as `IPTV key route` while a live session is playing.

**Settings → Subtitles → Live captions** turns on on-device speech to text for ordinary files, live IPTV, and VOD. Pick Base or Small, then **Download selected model** (about 150 MB or 500 MB, saved under Application Support, not part of the build). Source language can stay on auto-detect. Target **Same as speech** leaves the recognized words. **English** uses Whisper's own translate-to-English. Any other target uses the macOS 26 system translator when that language is installed, or an HTTPS API key stored in the Keychain (DeepL's free endpoint by default, or another JSON endpoint). The request sends the caption text only. On earlier macOS, without a key, a non-English target stays in the recognized language. Whisper does not translate into those languages by itself, and no separate local translation model is bundled.

libmpv does not give the app the player's decoded PCM. A lavfi `asplit` inside mpv cannot hand samples out, and switching the audio output to PCM would mute playback, so neither is used. The app decodes the same URL again with AVFoundation. A live stream is opened a second time. The URL is not written to the log. Low latency waits about 3 seconds of audio, balanced about 5, accuracy about 8, and the model then adds its own time. Base is the lighter load. Small uses more of an M2's CPU and GPU. This was not timed on a Mac.

Each line is stamped with the audio time Whisper reports, not with the moment the text comes back. Which clock to use is chosen automatically, and again whenever the channel or file changes. A file, a movie, or catch-up is read ahead of the playhead by about as long as Whisper is taking, so the line is ready before those words are spoken and playback is not delayed. An IPTV live channel, or any other stream that cannot be seeked, has no future audio to read. Captions then fill mpv's demuxer cache (`cache`, `cache-secs`, `demuxer-readahead-secs`) and hold playback until that buffer is about 4–6 seconds, or longer when the measured transcription takes longer. Nothing else has to be switched on. The live-TV banner shows **Subtitles synced, live +5s** (the number is the hold actually in use) and a small copy of that line stays up after the banner hides. The slider is the buffer; **Auto-tune** raises it to the measured time and the settings line shows the same delay. Picture and sound wait together. Depth is estimated from the frame mpv has already drawn, so the stereo picture waits with them. It does not run on a separate live clock. **Delay live TV** (on by default) is the way to leave a live channel at the live edge; the line then appears when recognition finishes, a few seconds after the words. Turning captions off drops the hold and seeks that channel back to the live edge.

Flat playback adds the line with mpv `sub-add` (and `osd-overlay` if that add fails). The subtitle file uses those audio times, so mpv shows the line when the playhead reaches it. On a live channel with the delay turned off, the latest line is shown as soon as it is ready. Side-by-side on the glasses draws the cue whose audio time matches the playhead, at the bottom of each eye. mpv's own subtitles are part of the picture the stereo shader shifts, so they are hidden while that per-eye line is showing and restored afterwards. An optional Core ML encoder named `ggml-base-encoder.mlmodelc` or `ggml-small-encoder.mlmodelc` next to the ggml file is used when it is present. Otherwise the build runs on Metal, or on the CPU if Metal could not be compiled for the macOS 13 deployment target. The library itself is built for macOS 13 and is loaded only when captions are turned on.

While live TV, a movie, or an episode is the current IPTV playback, **M** or **Home** opens a library menu on that same overlay: **Live TV**, **Movies**, **Series**, **Continue watching**, **Favourites**, and **Search**. It uses the cached catalog, `get_vod_info` / `get_series_info`, the artwork cache, and `progress.json`. Movies and series are a category rail plus a poster grid. A title opens a details page with backdrop, poster, plot, cast, rating, year, duration, **Play**, **Resume** when progress qualifies, **Trailer** when a link exists, and **Favourite**. **Play** starts at the beginning and clears that title's saved progress. **Resume** seeks after the file loads. On a series, **Episodes** opens a season list and an episode list (thumbnail, plot, duration, resume or watched). Return on an episode resumes when progress qualifies, otherwise it starts from the beginning. At the end of an episode a next-episode card counts down for 10 seconds; **Return** plays it immediately and **Esc** cancels. **Esc** or **Delete** steps back one screen and then closes the menu. Arrows, Page Up/Down, the scroll wheel, hover, and click follow the same rules as the live list: the highlight moves and scrolls into view, and the overlay takes those keys until it closes. In side-by-side 3D the menu, grid, details, and episode list are drawn into both eye halves. Type to search; there is no text field. **M** is left alone when nothing IPTV is playing. The separate IPTV window is unchanged.

Live channels are a programme guide. Categories are the middle column (All, Favourites, then each `group-title` or Xtream category). Each channel row has a favourite star, the logo, the name, and the current programme and the next one. A channel that can catch up also has a blue clock. When the current programme started inside that channel's archive window, a blue counterclockwise arrow sits on the Now line: that is **Restart current programme**. To the right, time runs across the grid and each listing is a block. The grid keeps seven days before the current hour and 24 hours after it, and it opens scrolled to now, so you scroll left for earlier listings. Search matches channel names, categories, EPG ids, and programme titles, and a matching listing is highlighted on the grid. Xtream **Movies** and **Series** use a poster grid in those same categories, with a **Continue watching** row when a film or episode is partway through. Click a poster to open details; **Back** returns to the grid. M3U sources stay on the guide. An empty source list, an empty category, and a failed load each have their own message. A missing logo or poster stays as a placeholder.

**What a click does.** The channel name, the logo, the current (accent-coloured) block, and a future block play the live stream. A past block on an archive channel, drawn blue with a rewind mark, plays that programme from the start through the provider's timeshift URL. A past block that cannot be caught up is faded; clicking it explains why and does not tune the live stream. Clicking empty space to the left of now, where no listing is drawn, does the same. The restart arrow plays the current programme from its start. Refresh a source that was saved before catch-up existed; older catalog caches have no archive fields until then.

**Add Source** takes either kind:

- **M3U / M3U8.** Paste a playlist URL or choose a local `.m3u` / `.m3u8` file. The parser reads `#EXTM3U` for `url-tvg`, `x-tvg-url`, and `tvg-url`, `#EXTGRP`, and `#EXTINF` attributes `tvg-id`, `tvg-logo`, `tvg-name`, and `group-title` (quoted or not). A comma inside quotes is part of the attribute, not the title. Relative stream URLs are resolved against the playlist URL or the file URL. A duration-only `#EXTINF:-1,Name` line is fine.
- **Xtream Codes.** Server URL (a missing scheme becomes `http://`, and a trailing `/player_api.php` is removed), username, and password. The client calls `player_api.php` for authentication and then `get_live_categories`, `get_live_streams`, `get_vod_categories`, `get_vod_streams`, `get_series_categories`, and `get_series`. Stream addresses are `{server}/live/{user}/{password}/{id}.m3u8`, `{server}/movie/{user}/{password}/{id}.{ext}`, and `{server}/series/{user}/{password}/{episode-id}.{ext}`. A non-empty `direct_source` is used when it is itself a URL. `auth` may be a number or a string. Category and stream ids may be numbers or strings. List rows already carry plot, rating, genre, cast, director, release date, TMDB id, cover, backdrop, trailer, and duration when the provider sends them. Refresh a source saved before those fields existed; an old catalog cache will not show them until then.

**Movies and series.** Opening a poster calls `get_vod_info` (`vod_id`) or `get_series_info` (`series_id`). The password is in that request and is not written into the details cache. The page shows the backdrop, poster, title, year, rating, duration, genre, plot, director, and cast, then **Play**, **Resume** when there is something to resume, and **Trailer** when the provider sent an `http`/`https` link or an 11-character YouTube id (`0` is ignored). **Play** starts at the beginning and clears saved progress for that film or episode. **Resume** seeks after the file has loaded. On a series, **Play** starts episode 1 from the beginning and **Resume** continues the episode that is in progress. Seasons are a popup; each episode row has a thumbnail, title, plot, duration, and its own Play / Resume. `episodes` may be a map of season number to a list, or one flat list. Episode plot and thumbnail are read from the episode and from its nested `info`. A continue-watching episode opens its series when that series is still in the catalog. An episode with no parent series in the catalog is shown from the fields already stored on it, and `get_vod_info` is not called.

**Continue watching.** mpv watch-later stays off for IPTV, because that file would contain the password URL. Progress is a separate file, `~/Library/Application Support/com.colliderli.iina/IPTV/progress.json`, keyed by source UUID and item id. A position under 5 seconds is not stored. Resume is offered at 30 seconds or later, and not when the position is within 30 seconds of the end or at 95% or more. The grid shows movies under Movies and episodes under Series, newest first. Removing a source deletes that source's progress and its detail files. Artwork is not deleted with the source.

**TMDB, optional.** **Settings → Network → TMDB API Key** stores a key in preferences, not the Keychain. Leave it blank and only the provider's data is used. A normal key is sent as the v3 `api_key` query. A key that starts with `ey` is sent as a bearer token and is not put in the query. The key is not logged. Lookup runs only when plot, poster, or backdrop is empty, first by numeric TMDB id, otherwise by title and year (`release_date` / `first_air_date`, or a trailing `(YYYY)`, `[YYYY]`, or ` YYYY` on the title). A search with the year that returns nothing is tried again without the year. Filled fields are overview, `w500` poster, `w1280` backdrop, rating, release date, genres, runtime, up to eight cast names, and the director (or `created_by` for a series). Existing Xtream values are not replaced. At most 12 episodes that are missing a plot or a still are filled from `/tv/{id}/season/{season}/episode/{episode}` (`w300` stills). A TMDB failure leaves the provider's page up and shows a short note. Details are cached for 12 hours in `IPTV/Details/<source-uuid>-<item-id>.json`. Changing the key changes a short hash stored with the cache, so the next open fetches again. The cache does not contain the key or the password-bearing request URL.

Posters, backdrops, logos, and episode stills are cached in memory and under `IPTV/Artwork/`, one file per image URL. A later request for the same URL reads the file and does not download it again.

**Programme guide.** Loaded with the channel list. An EPG URL on the source wins. Otherwise an M3U playlist's `url-tvg` is used, or Xtream's `xmltv.php?username&password`. Listings that overlap a window from 7 days ago through 26 hours ahead are kept. The grid draws that same 7 days, measured from the current hour, through 24 hours ahead. A channel whose `catchup-days` or `tv_archive_duration` is longer than 7 days still cannot show the older listings; they are dropped when the guide is parsed. Now and Next on each row are taken from that list and move forward as time passes, about once a minute, without fetching the file again. XMLTV stamps such as `20261011023000 +0100` are treated as local time at that offset. A programme `catchup-id` is kept and substituted into `{catchup-id}` templates.

**Catch-up.** A channel is archive-capable only when a mode is recognized and a positive day count is present (`catchup-days`, a header default, legacy `timeshift` or `tvg-rec`, or Xtream `tv_archive_duration`). There is no app-wide default day count. Values on `#EXTM3U` (`catchup` or `catchup-type`, `catchup-days`, `catchup-source`, `catchup-correction`) apply to entries that omit them. `catchup-type` is an alias of `catchup`.

- **Xtream `tv_archive`.** `1` or `true` (number or string) plus `tv_archive_duration` in days. Playback is `{server}/timeshift/{user}/{password}/{minutes}/{YYYY-MM-DD:HH-MM}/{streamId}.ts`. Minutes are the programme length divided by 60, and at least 1. The date and time are the Mac's local clock. The password is read from the Keychain when you click; it is not stored on the channel. This path does not depend on the M3U `xc` pattern, and it always uses `.ts`.
- **`shift`**, and legacy `timeshift="N"` when no catch-up mode is set. Appends `?utc={utc}&lutc={lutc}`, or `&utc={utc}&lutc={lutc}` when the stream URL already has a query. `timeshift="N"` supplies N days when the entry has no `catchup-days`. A header `catchup-days` is used only when the entry has neither. If a mode is already set, `timeshift` only supplies days.
- **`default`.** `catchup-source` is the whole timeshift URL. If it is absent, the same `utc` / `lutc` query is appended. Kodi's addon has a separate query-format setting for this case and disables catch-up when that setting is empty; this player uses the `utc` / `lutc` pair instead, because that is the usual value of that setting. Put a different query in `catchup-source` if the provider needs one.
- **`append`.** `catchup-source` is concatenated onto the stream URL. If it is absent, the same `utc` / `lutc` fallback is used.
- **`flussonic`**, **`flussonic-hls`**, **`flussonic-ts`**, **`fs`.** Built from the live URL. `…/index.m3u8` becomes `…/timeshift_rel-{offset:1}.m3u8`. Another `.m3u8` name such as `mono.m3u8` becomes `…/mono-timeshift_rel-{offset:1}.m3u8`. `mpegts` becomes `…/timeshift_abs-${start}.ts`. A query that contains `=` is kept. If that pattern does not match, `flussonic-ts` and `fs` use `timeshift_abs-${start}.ts`, and `flussonic` / `flussonic-hls` use `timeshift_rel-{offset:1}.m3u8`. If neither pattern matches, the channel has no archive.
- **`xc`.** From a live URL shaped like `http://host/user/pass/id`, `http://host/live/user/pass/id`, or the same with `.m3u8` or `.m3u`. The result is `http://host/timeshift/user/pass/{duration:60}/{Y}-{m}-{d}:{H}-{M}/id` plus `.ts` when the live URL had no extension, or the original `.m3u8` / `.m3u`. A live URL that already ends in `.ts` does not match. The user and password are copied from the playlist URL, which may already contain them.
- **`vod`.** An explicit `catchup-source` is used as the template for past programmes inside the day window. With no source, the template is `{catchup-id}`. A `plugin://` address is not played. Future programmes are not started as catch-up.

Placeholders, in an order that keeps compound tokens intact: `{utc:FORMAT}`, `${start:FORMAT}`, `{utcend:FORMAT}`, `${end:FORMAT}`, `{lutc:FORMAT}`, `${now:FORMAT}`, and `${timestamp:FORMAT}` (FORMAT's `Y` `m` `d` `H` `M` `S` are zero-padded local date fields, and other characters are copied); then `{duration:N}` and `{offset:N}` (integer division by N, N a positive integer, result at least 0); then `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}` for the programme start; then bare `{utc}`, `${start}`, `{utcend}`, `${end}`, `{lutc}`, `${now}`, `${timestamp}`, `{duration}`, and `${offset}`; then `{catchup-id}`. `{Y}` and the other calendar fields use the Mac's local timezone, not UTC. Bare `{utc}` is Unix seconds. `{lutc}`, `${now}`, and `${timestamp}` are the real current time. `{offset:N}` and `${offset}` are that current time minus the corrected start, and never negative.

`catchup-correction` is a number of hours, including negative, on the entry or the header. It is subtracted from the programme start before the URL is filled, and it does not move the times drawn in the guide. A value of `-4` therefore writes timestamps four hours later than the guide. That is the same sign as Kodi's pvr.iptvsimple (the attribute is stored as hours, then subtracted). `{lutc}` / `${now}` / `${timestamp}` are not shifted. `tvg-shift` is not applied to these URLs.

The timeshift URL is handed to mpv the same way as a live URL: history, the opening line, and the failed-open field use `iptv://<source-uuid>/<item-id>` and the channel or programme title, not the password. An M3U `xc` or `catchup-source` template is stored in the catalog cache and can contain a password when the playlist URL already did. Kodi's `|` protocol options on a URL are not interpreted.

**Passwords.** Xtream passwords are written to the macOS Keychain, service **`IINA IPTV Account`**, account equal to the source UUID. They are not stored in `library.json`, `progress.json`, or the details cache. Editing a source and leaving the password blank keeps the Keychain item. Removing a source deletes that item, the cached catalog, that source's watch progress, and that source's detail files. Artwork stays, because it is keyed by image URL rather than by source. The generated `xmltv.php` URL contains the password, so that URL is rebuilt from the Keychain when needed and is not written into the catalog cache. The `get_vod_info` / `get_series_info` request URL is likewise not stored.

Xtream still requires the password in the stream path. mpv is given that real URL. IINA does not put it in playback history or Recent Documents. History stores `iptv://<source-uuid>/<item-id>` plus the channel title. Opening that history entry will not replay the stream. While the stream is opening and playing, log lines, the on-screen "opening" message, the failed-open field, and the plugin `url` property use the title or the `iptv://` stand-in. `save-position-on-quit` is turned off for that playback and restored for the next ordinary file, because a watch-later file would otherwise contain the path. After the file ends, the in-memory stand-in is dropped. mpv's own process still has the real URL for as long as it is playing.

Saved sources and favourites live in `~/Library/Application Support/com.colliderli.iina/IPTV/library.json`. Cached catalogs are `cache-<uuid>.json` in that folder. An M3U cache contains the stream URLs from the playlist, so a playlist that already embeds credentials will be copied there. An Xtream `direct_source` is cached too. Neither file is UserDefaults.

`Info.plist` sets `NSAllowsArbitraryLoads` so the catalog, guide, and logo requests can use the HTTP servers IPTV hosts usually are. `NSAllowsArbitraryLoadsInWebContent` is not set: on macOS that key makes `NSAllowsArbitraryLoads` ignored. The assrt.net exception (`NSExceptionAllowsInsecureHTTPLoads` and `NSIncludesSubdomains`) stays. The arbitrary-loads exception applies to the whole app, not only IPTV. mpv was already able to play HTTP URLs without it.

## Known gaps

- The Release app is compiled by the macOS Release workflow. It has not been launched. Metal, Core ML, and the OpenGL `IOSurface` share are unchecked on a Mac.
- At 1920×1080 the glasses image is half side-by-side inside that frame. At 3840×1080 each eye is a full 1920×1080 half. The window is the screen frame, not a floating player window.
- The copy into the stereo pass is 8-bit BGRA, so HDR is flattened for the 3D view.
- Subtitles drawn by mpv are part of the picture that gets shifted.
- Depth is about a frame behind the picture, and it is a horizontal shift plus a short hole search, not a full inpaint.
- Already-SBS detection is the filename, not the pixels.
- Play on Glasses leaves music mode alone; exit music mode first. If the window is already in AppKit fullscreen, the command leaves fullscreen and then moves to the glasses.
- Square 504×504 DA3 inference stretches the frame for the depth pass. A 16:9-friendly alternative that is still a multiple of 14 is `--width 364 --height 210`, which the loader will pick up because the name starts with `DepthAnything3`.
- A device test showed the live list and guide on screen, with no response to Up/Down or selecting a channel. The key-routing change after that test was not tried again on the glasses. Channel up/down, with the list closed, follows the current group; the number keys use the position in the full live list. The per-eye control bar and cursor were not shown on the glasses either.
- The movies and series overlay (M / Home, poster grid, details, seasons, next-episode card) was not shown on the glasses or with a playlist. It reuses the catalog, title, artwork, and progress code paths; those paths were not run here.
- Live captions were not run on a Mac. The delay, the M2 load, Metal, Core ML, the second audio decode, lookahead, the live cache hold, and both-eye drawing were not measured. No Whisper model was downloaded here, and no translation API was called.
- IPTV was not compiled or opened. No playlist was fetched, no Xtream server was contacted, no TMDB host was contacted, and the Keychain was not written. The M3U, XMLTV-offset, stream-URL, catch-up, title-field, TMDB-merge, and resume-threshold checks were a Python transcription of those rules, then deleted.
- An `iptv://` history row does not play again. Resume-from-history and watch-later are off for these streams.
- The guide was not compiled or shown. It keeps listings from 7 days ago through 26 hours ahead, not every programme in a multi-week XMLTV file, and not catch-up older than that even when `catchup-days` is larger. Quoted `#EXTINF` values are not unescaped (`\"` stays as two characters). A junk token before an attribute is skipped. Catch-up URL assembly was checked as a Python transcription of the rules above, then deleted; the Swift was not compiled, and no provider was contacted.
- The poster grid and the details page were not compiled or shown. Series episodes come from `get_series_info` when the details page opens, not with the first catalog request. Movies and series do not use the EPG columns. An episode opened from Continue watching keeps its series only when that series is still in the catalog; otherwise the page uses the fields already stored on the episode.
- The WebDAV plugin was not installed in IINA and was not pointed at FebBox, Nextcloud, or a NAS. No PROPFIND was sent and the Keychain was not written. The sample listing parser was run locally. Playback through Immersive 3D and Play on Glasses was not tried.
- The remote-files plugin was not installed in IINA. No WebDAV, FTP, FTPS, SMB, SFTP, Jellyfin, Emby, Plex, DLNA, or OpenSubtitles host was contacted, and the Keychain was not written. Subtitle auto-load, resume seek, posters, discovery on a network, and both-eye playback were not tried. SMB listing depends on `mount_smbfs` and a UNIX `ls`; SFTP listing depends on password `SSH_ASKPASS` and a UNIX `ls`. Jellyfin, Emby, and DLNA show 200 children and do not page further. The sample parsers and the helper-script syntax checks were run locally.

---

<p align="center">
<img height="256" src="https://github.com/iina/iina/raw/master/iina/Assets.xcassets/AppIcon.appiconset/icon_512x512.png">
</p>

<h1 align="center">IINA</h1>

<p align="center">IINA is the <b>modern</b> video player for macOS.</p>

<p align="center">
<a href="https://iina.io/">Website</a> ·
<a href="https://github.com/iina/iina/releases">Releases</a> ·
<a href="https://t.me/IINAUsers">Telegram Group</a>
</p>

---
[![Crowdin](https://badges.crowdin.net/iina/localized.svg)](https://crowdin.com/project/iina)
## Features

* Based on [mpv](https://github.com/mpv-player/mpv), which provides the best decoding capacity on macOS
* Designed with modern versions of macOS (11.0+) in mind
* All the features you need for video and music: subtitles, playlists, chapters…and much, much more!
* Force Touch, picture-in-picture and advanced Touch Bar support
* Customizable user interface including multiple color schemes and on screen controller (OSC) layout positioning
* Standalone Music Mode designed for audio files
* Video thumbnails
* Online subtitle searching and intelligent local subtitle matching
* Unlimited playback history
* Convenient and interactive settings for video/audio filters
* Fully customizable keyboard, mouse, trackpad, and gesture controls
* mpv configuration files and script system for advanced users
* Command line tool and browser extensions provided
* In active development

## Downloading

You can get IINA through several sources. For the latest stable and beta releases, visit the [GitHub release page](https://github.com/iina/iina/releases) or the [IINA official website](https://iina.io/). If you want to try out the latest features and improvements before they are officially released, you can download the nightly builds from our [Nightly Download Page](https://iina.io/nightly/).

> [!IMPORTANT]
> Nightly builds are generated by GitHub automatically for every commits, which might be buggy and unusable. If you find a bug, please follow the [contributing section](#Contributing) and file an issue.

## Building

IINA uses mpv for media playback. To build IINA, you can either fetch copies of these libraries we have already built (using the instructions below) or build them yourself by skipping to [these instructions](#building-mpv-manually).

### Using the pre-compiled libraries

1. Download pre-compiled libraries by running

```console
./other/download_libs.sh
```

> [!TIP]
> - By default the shell script downloads universal binaries. You can download arch-specific binaries using `--arch <ARCH>` (`universal`, `arm64` or `x86_64`)
> - Files are downloaded in parallel (5 concurrent downloads by default). You can change this using `--parallel <N>` (from 1 to...)
> - If you want to build an older IINA version you must change `DYLIBS_DOWNLOAD_PATH` in the script to download the corresponding dylibs. For example, `https://iina.io/dylibs/1.2.0/universal/fileList.txt`.

2. Open iina.xcodeproj in the [latest public version of Xcode](https://apps.apple.com/app/xcode/id497799835). *IINA may not build if you use any other version.*

3. Build the project.

### Building mpv manually

1. Build your own copy of mpv. You can use our [official build scripts](https://github.com/iina/deps-buildscripts) to build mpv and all other dependencies.

2. Run `other/parse_doc.rb`. This script will fetch the latest mpv documentation and generate `MPVOption.swift`, `MPVCommand.swift` and `MPVProperty.swift`. Copy them from `other/` to `iina/`, replacing the current files. This is only needed when updating libmpv. Note that if the API changes, the player source code may also need to be changed.

3. Link the *yt-dlp* dependency to deps/executable

   ```console
   mkdir -p deps/executable
   ln -s $(which yt-dlp) deps/executable/youtube-dl
   ```

4. Open `iina.xcodeproj` in the [latest public version of Xcode](https://apps.apple.com/app/xcode/id497799835). *IINA may not build if you use any other version.*

5. Remove all references to `.dylib` files from the Frameworks group in the sidebar and add all the `.dylib` files in `deps/lib` to that group by clicking  "Add Files to iina..." in the context menu.

6. Add all the imported `.dylib` files into the "Copy Dylibs" phase under "Build Phases" tab of the iina target.

7. Make sure the necessary `.dylib` files are present in the "Link Binary With Libraries" phase under "Build Phases". Xcode should have already added all dylibs under this section.

8. Build the project.

## Contributing

IINA is always looking for contributions, whether it's through bug reports, code, or new translations.

* If you find a bug in IINA, or would like to suggest a new feature or enhancement, it'd be nice if you could [search your problem first](https://github.com/iina/iina/issues); while we don't mind duplicates, keeping issues unique helps us save time and consolidates effort. If you can't find your issue, feel free to [file a new one](https://github.com/iina/iina/issues/new/choose).

* If you're looking to contribute code, please read [CONTRIBUTING.md](CONTRIBUTING.md) — it has information on IINA's process for handling contributions, and tips on how the code is structured to make your work easier.

* If you'd like to translate IINA to your language, please visit [IINA's instance of Crowdin](https://translate.iina.io/). You can create an account for free and start translating. Please do not send a pull request to this repo directly, Crowdin will automatically sync new translations with our repo. If you want to translate IINA into a new language that is currently not on the list, feel free to open an issue.

## IINA Plugins List

### Official Plugins
- **[Online Media](https://github.com/iina/plugin-online-media)** (`iina/plugin-online-media`) - Enhances online streaming and downloading.
- **[OpenSubtitles](https://github.com/iina/plugin-opensub)** (`iina/plugin-opensub`) - Search and download subtitles.
- **[User Scripts](https://github.com/iina/plugin-userscript)** (`iina/plugin-userscript`) - Run custom JavaScript snippets.

### Community Plugins
- **[AirPlay](https://github.com/ozykhan/iina-airplay)** (`ozykhan/iina-airplay`) - Cast the current file to an Apple TV over AirPlay; IINA stays the remote.
- **[Anime4K](https://github.com/yorkyang2333/iina-anime4k)** (`yorkyang2333/iina-anime4k`) - Apply Anime4K shaders for real-time anime upscaling.
- **[Auto Skip](https://github.com/pangziqiang/iina-auto-skip)** (`pangziqiang/iina-auto-skip`) - Automatically skip intro and outro sections with visual drag-to-set overlay.
- **[Bilingual Audio](https://github.com/glechic/iina-bilingual-audio)** (`glechic/iina-bilingual-audio`) - Play two audio tracks with left/right channel separation for bilingual viewing.
- **[Bookmarks](https://github.com/wyattowalsh/iina-plugin-bookmarks)** (`wyattowalsh/iina-plugin-bookmarks`) - Save and manage video timestamps.
- **[CineMode](https://github.com/D0CA/iina-cinemode)** (`D0CA/iina-cinemode`) - Fullscreen pause overlay and skip intro; optional Stremio next-episode shortcut.
- **[Clickable Subtitles](https://github.com/kerim/iina-clickable-subtitles)** (`kerim/iina-clickable-subtitles`) - Click subtitles to define words (macOS Look Up).
- **[Danmaku](https://github.com/xjbeta/iina-plugin-danmaku)** (`xjbeta/iina-plugin-danmaku`) - Overlay comments/danmaku on video.
- **[Danmaku Cosmos](https://github.com/karappo-yu/iina-plugin-danmaku-cosmos)** (`karappo-yu/iina-plugin-danmaku-cosmos`) - Niconico/Bilibili danmaku with CSS/Canvas dual rendering, Comment Art support.
- **[Detached Playlist](https://github.com/HowDidTheCatGetSoFat/iina-detached-playlist)** (`HowDidTheCatGetSoFat/iina-detached-playlist`) - Show the playlist in a separate floating window.
- **[Episode Info](https://github.com/Zain-Imam/iina-episode-info)** (`Zain-Imam/iina-episode-info`) - TMDB episode/movie info overlay on pause, with built-in subtitle search.
- **[File Viewer](https://github.com/qktechies/iina-plugin-file-viewer)** (`qktechies/iina-plugin-file-viewer`) - bookmark folders, browse directory contents, and play video files directly within IINA.
- **[Hold to Speed](https://github.com/Tommy12356F/iina-hold-to-speed)** (`Tommy12356F/iina-hold-to-speed`) - Hold Space to play at 2× speed, just like YouTube.
- **[Jellyfin](https://github.com/mhajder/iina-jellyfin)** (`mhajder/iina-jellyfin`) - Browse and play media from Jellyfin servers.
- **[Jump to Frame](https://github.com/bbeny123/iina-jump-to-frame)** (`bbeny123/iina-jump-to-frame`) - Navigate video by specific frame number.
- **[Keystone](https://github.com/lenadweb/iina-plugin-keystone)** (`lenadweb/iina-plugin-keystone`) - Vertical and horizontal keystone correction for projectors, adjusted live from the sidebar or keyboard.
- **[ListenBrainz Scrobbler](https://git.notfire.cc/notfire/iina-listenbrainz)** - Scrobble your music to ListenBrainz.
- **[Multiple Clips](https://github.com/karthisnk/multi-cutter-iina)** (`karthisnk/multi-cutter-iina`) - multiple clip of a video using ffmpeg, with Batch Clipping, Vertical Clip, Format Selection, Preview Clip.
- **[PiP Toggle for IINA](https://github.com/nastarandarjani/iina-pip-toggle)** (`nastarandarjani/iina-pip-toggle`) - Simple plugin to toggle Picture-in-Picture (PiP) to fullscreen.
- **[Playlist Pro](https://github.com/CatCodeDanix/iina-playlist-pro)** (`CatCodeDanix/iina-playlist-pro`) - Seamless management of local and online playlists.
- **[Playlist Searchbox](https://github.com/icsarisakal/iina-playlist-searchbox)** (`icsarisakal/iina-playlist-searchbox`) - Search the current playlist by song title and artist.
- **[PolyScript](https://github.com/SammoMichael/polyplugin-release)** (`SammoMichael/polyplugin-release`) - Dual subtitles, hover dictionary, and AI-assisted translation for language learning.
- **[recorder](https://github.com/5thDimensionalVader/recorder-iina)** (`5thDimensionalVader/recorder-iina`) - to clip a video using ffmpeg.
- **[Skip Intro](https://github.com/pparanoiidd/iina-skip-intro)** (`pparanoiidd/iina-skip-intro`) - Detect and skip intros, recaps and credits.
- **[SubTandem](https://github.com/janwee-sha/SubTandem)** (`janwee-sha/SubTandem`) - A powerful plugin for real-time AI-powered bilingual subtitle translation.
- **[Thumbnails](https://github.com/aminozuur/iina-thumbnails)** (`aminozuur/iina-thumbnails`) - An IINA plugin that shows clickable thumbnails for each video.
- **[Trakt Scrobbler](https://github.com/i3p9/iina-trakt-scrobbler)** (`i3p9/iina-trakt-scrobbler`) - Trakt.tv scrobbler plugin for IINA.
- **[VR2D](https://github.com/fetzu/iina-plugin-vr2d)** (`fetzu/iina-plugin-vr2d`) - Watch 3D VR videos (180°/360°, side-by-side or over-under) flat, with pan, zoom and automatic detection.


> 💡 **Want to build your own plugin?**
>
> Explore the existing plugins listed here to learn how they work. If you create a new plugin or improve an existing one, feel free to contribute back by adding it to this list via a pull request.
