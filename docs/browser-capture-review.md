# Browser Capture → depth → side-by-side → glasses

This is the path from a chosen window to a picture on the glasses, and the defects that path had. The glasses output is one session: the source is the player or the capture, not both.

The headless check is `other/browser-capture-selftest.sh`. It does not open a window. The manual checklist at the end is the real-Mac pass.

## Flow

1. **Choose a source.** Video → Choose Capture Window lists displays, then layer-0 windows that have a title. `SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false)` keeps full-screen windows that live on another Space. IINA's own capture window, chooser, and the player window while it is on the glasses are left out.

2. **Open the stream.** `SCStream` is configured at the window's pixel size (clamped to 3840×2160, even), `32BGRA`, queue depth 3, cursor off, 30 fps on macOS 13+. A window uses `SCContentFilter(desktopIndependentWindow:)`. A display uses `SCContentFilter(display:excludingWindows:)`. ScreenCaptureKit audio stays off. Samples are copied before the callback returns. The sample queue only keeps the newest copy; the depth pass runs on a draw queue and drops frames that arrived while it was busy.

3. **Frames.** The screen callback runs on the capture queue, not the main thread. Status comes from the sample-attachment CFDictionary without bridging that array to Swift. `.blank` shows the protected-video message and redraws. `.idle` or a missing image redraws. Any other status with an image is copied into a pixel buffer this process owns (`CVPixelBufferCreate` + `memcpy`), then handed to the renderer. A 30 fps timer redraws if ScreenCaptureKit goes quiet.

4. **Texture lifetime.** The copy is the only buffer the renderer locks. `CVMetalTextureCacheCreateTextureFromImage` is +1 and `CVMetalTextureGetTexture` is not. The holder is released before the cache is flushed, and the flush is every 30th frame, not every frame. Flushing while the holder is alive frees the texture the holder releases next. The ScreenCaptureKit buffer is not released again. The first frame logs mean luma (`first frame luma`). `capture latency` is the milliseconds from that copy to the present, logged about once a second.

5. **Depth and side-by-side.** Capture and the player each have a compositor, because the player pass runs on the OpenGL thread. Both call `Immersive3DController.submitFrame` → `immersiveStereo`. Capture forces the pass on (`colorIsBottomUp == false` means "this texture is the picture"). Until a depth map exists, a flat 0.5 depth texture is used, so the first frames are still side-by-side. A capture texture is sampled in full by each eye (`colorIsPicture`). A player texture is the glasses framebuffer, so a 16:9 picture on 3840×1080 is the center band and each eye samples that band.

6. **One glasses output.** `GlassesSession` is the state. `Play on Glasses` (menu item, the submenu display, the panel Exit button, and Send Capture to Glasses) calls the same transition.
   - Capture running, glasses off → pin the capture window borderless on the glasses. The player window stays put.
   - Capture not running → pin the player, as before.
   - Already on the glasses → leave.
   - Capture starts while a glasses display is connected → the capture takes the output. If the player was there, it is returned and restored when capture stops.
   - Capture stops → the capture window returns to the 960×540 preview, unless the player was displaced and should come back.
   - A screen-parameter change updates the recorded display and the existing pin runs again (2D/3D size change included).

7. **Drawable size.** `GlassesDrawable.pixels` is `points × backingScaleFactor`, rounded, and refuses anything under 32 pixels on a side. Glasses use the glasses screen's full pixel size, stored when the capture is pinned. A resize or screen change while the window is moving does not read `window.screen`: a Space animation reports the Mac's built-in display (3024×1964 at 2x) or a partial frame (3840×1027), and those are ignored. The drawable is written only when no present is in flight, because changing `drawableSize` releases the drawable the main autorelease pool still owns. If the texture and the drawable differ, the frame is scaled onto the drawable instead of skipped. Present does not wait for the GPU, and the in-flight slot is released in the command-buffer completion, including on error.

8. **Window follow.** Every 0.5 s. The current window id stays selected while it is in the list, including when `isOnScreen` is false because full screen moved it to another Space. Untitled and tiny windows are placeholders and are never chosen. The filter changes only after the current id has been missing for more than 1.5 seconds, and it does not change again on the next tick. The replacement prefers a title that contains the previous title, then the largest real window of that app. If none is left, the display the window was on is captured. The shareable content and the filter are kept alive until `updateContentFilter` returns, and the filter is not updated when the id did not change.

9. **Audio.** Default is off, and a normal file is left alone: the toggle does nothing until a capture is running, and it never changes mpv's device on its own. Muting Chrome also mutes what ScreenCaptureKit can read, so there is no mute control and `capturesAudio` stays off. **Route browser sound through IINA (no echo, synced)** installs the bundled HAL plugin `IINA Capture Audio` (stereo, 48 kHz) into `/Library/Audio/Plug-Ins/HAL` with one admin prompt, then restarts `coreaudiod`. While a capture is running, IINA writes the current default output to Application Support, pins every mpv instance to `coreaudio/<that uid>`, and only then sets the system default output to `IINACaptureAudio_UID`. The browser plays into the plugin and the speakers stay quiet. IINA reads the plugin's input and plays it on the saved device when the picture has caught up (`capture latency`), dropping samples more than about 200 ms late. Stop, quit, and the next launch after a crash put that saved output back. **Uninstall IINA Capture Audio…** removes only that plugin. The driver is built and ad-hoc signed in CI and copied into `IINA.app` before the zip; CI does not install it or restart `coreaudiod`. Its `AudioServerPlugIn` vtable is the one `coreaudiod` on macOS 13.7 uses (184-byte interface, IO-cycle info 224 bytes, `mOutputTime` at offset 144). The plugin minimum OS is 12.0. CI runs `otool -l` on every Mach-O in the app, including this plugin and `libiina_whisper.dylib`, and fails the build if any `LC_BUILD_VERSION` minos is newer than 13.0.

10. **Teardown.** Stop cancels the follow and redraw timers, stops audio and the tap, and `stopCapture` with `ignoreStop` set so that stop is not treated as a crash. Three failed restarts give up and tell the session the capture stopped. Quit calls `stopAll`, which leaves the glasses session and orders the capture window out, then `exitGlasses` for the player.

## Defects

| Severity | Defect | What happened |
| --- | --- | --- |
| High | Play on Glasses was not a capture source | The menu moved the player window. Capture had a second flag and a second window. Pressing Play on Glasses never sized or presented the capture drawable, which is why the log had no `output drawable` or `glasses send`. |
| High | Capture did not take connected glasses | Starting a capture left the picture on the preview even when a glasses display was already there. |
| High | Full-screen YouTube dropped the track | The id and the title both change. Follow required the title to match, then logged `tracked window N is gone; no app+title match` and kept the dead filter. |
| High | Full-width side-by-side cropped the capture | `contentRect` assumes the color texture is a 3840×1080 framebuffer with the picture pillarboxed. A capture texture is the window. Each eye sampled the center band of that window. |
| Medium | Two booleans for one output | `glassesActive` and `onGlasses` could disagree, and both windows could be pinned. Screen changes updated them separately. |
| Medium | Drawable size had no single formula | A zero view used to become 2×2 (`880cd67` stopped that clamp). Play on Glasses still never asked for a glasses-sized drawable. Sizes under 32 pixels are now refused. |
| Medium | Stream give-up left the session on capture | Three restart failures tore the stream down and did not tell the glasses session. |
| Medium | In-flight slot could stick | Fixed in `880cd67`: the slot is released in the command-buffer completion, including errors, and a slot busy for more than a second is reclaimed. A late completion is ignored if the slot was reused. |
| Low | Present-skip logs could flood | Skips are logged at most once a second. |
| Low | First-frame luma was a private string | The number is logged with `privacy: .public`. |
| High | Full-screen follow flipped every half second | Window 145 left the current Space, so `isOnScreen` was false, and the largest other Chrome window was an untitled placeholder (2003). The next tick did the same in reverse. Each flip called `updateContentFilter`. The current id now stays while it exists. Placeholders are ignored. A missing id waits more than 1.5 seconds, and the follow does not switch back. |
| High | The drawable followed the Mac screen during the Space change | `window.screen` mid-animation is the built-in display (3024×1964 at 2x) or a partial glasses frame (3840×1027). Resize re-pinned to that screen. The glasses pixel size is locked, interim sizes are ignored, and a texture that does not match the drawable is scaled onto it. |
| High | `objc_release` during the main autorelease pool pop | Changing `drawableSize` while `nextDrawable()`'s drawable was still in the pool freed it, and the pool released it again. The cache was also flushed while the `CVMetalTexture` holder was alive. Drawable size now changes only when no present is in flight, the holder is released before a flush, and the filter update keeps the shareable content alive until the callback returns. The self-test runs that texture path under AddressSanitizer and under `NSZombieEnabled`. |
| High | Capture audio echoed the browser | IINA played the captured stream while Chrome still played it. Muting Chrome also mutes the capture, so that is not a fix on macOS 13. ScreenCaptureKit audio stays off. The bundled loopback takes the system output while a capture is running, the player stays on the previous device, and that device is restored on stop, quit, and the next launch. |

## Residual risks

- CI has no glasses and no Screen Recording prompt. The self-test checks the session, the pixel lock, the window follow (including the untitled-window flip), frame dropping, the audio policy, the route order (player first, then the system output, then restore, including a crash file), the loopback ring, the texture retain loop, a scaled 1920×1080 frame, and one synthetic frame through `immersiveStereo` at 3840×1080. It does not present to a `CAMetalLayer` or capture a real window. AddressSanitizer does not see ScreenCaptureKit.
- Flat depth is used until the depth model returns a map. The picture is side-by-side with little parallax until then. A protected window stays black on purpose.
- The HAL plugin is ad-hoc signed, the same as IINA.app. `coreaudiod` on Apple Silicon can refuse an ad-hoc plugin (library validation). This CI has no Developer ID. If the device does not appear after the admin prompt, that is why, and the picture capture still runs with the browser's own sound.
- Changing the system default output silences every app, not only the browser, until capture stops or IINA launches again after a crash. Alerts stay on the previous system device. Every mpv window is pinned to the active player's previous device for the capture and restored to that one device.
- CI compiles the plugin against the current SDK and checks that the vtable layout is still the macOS 13.7 layout. It does not copy the plugin into `/Library/Audio/Plug-Ins/HAL` and it does not restart `coreaudiod`. The whole app is rejected if any Mach-O minimum OS is newer than 13.0.
- The follow timer skips a tick when start or stop holds the session lock.
- Idle re-present holds one of the two frame slots. A main thread that does not drain presents can fill both until the one-second reclaim.
- Taking the glasses from the player and giving them back calls the mirror restore and the mirror split around that handoff.

## Manual test

On a Mac with Screen Recording allowed, and the glasses connected:

1. Start a capture of a Chrome window that is showing a normal page (not DRM). The preview should show it. The log should contain `output drawable` at the preview pixel size (960×540 points times the scale) and `glasses send` at that size, plus `first frame luma` well above 0.
2. Press **Play on Glasses** (Video menu). The capture window, not the player, should go borderless on the glasses at the screen pixel size (3840×1080 or 1920×1080). The log should contain `glasses source capture` and `output drawable` at that size. Both eyes should show the whole window, not a center crop and not black.
3. Press **Play on Glasses** again. The capture should return to the preview. The player window should not have moved.
4. Quit the capture. Start it again with the glasses still connected. The capture should land on the glasses without another click.
5. Put YouTube full screen in Chrome. The log must not flip every half second between the YouTube window and an untitled window. The picture should stay on the YouTube window. `output drawable` should stay at the glasses size (3840×1080 or 1920×1080) through the animation, not 3024×1964 or 3840×1027. A line `glasses present scale failed` or `present skipped texture` means the rescale path failed. `capture latency` should be present and should not climb while the picture sits still. Leave full screen and confirm the same window is still followed.
6. With **Route browser sound through IINA (no echo, synced)** off, sound comes from Chrome once. IINA does not play a delayed copy. There is no Mute control. Play a normal file with the toggle off, and again with the toggle on but capture stopped. The output device does not change either time.
7. Turn the toggle on. macOS asks once for an administrator password and installs **IINA Capture Audio**. Start a capture. Chrome goes quiet, IINA plays that sound on the previous output (glasses or headphones), lined up with the picture, and `capture latency` is logged. Other apps are quiet too. Stop the capture. The previous output comes back and Chrome is heard from itself again.
8. Start a capture with the toggle on, then force-quit IINA. Launch it again. The previous output is back before a video starts. **Uninstall IINA Capture Audio…** removes the plugin and asks for an administrator password.
9. With nothing capturing, **Play on Glasses** should still move the player, and Exit should restore it.
10. Start a capture while the player is already on the glasses. The player should leave and the capture should take the display. Stop the capture. The player should come back.
11. A DRM video should log a low `first frame luma` and the protected-window message. The glasses stay black. That is the intended result.
