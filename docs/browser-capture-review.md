# Browser Capture → depth → side-by-side → glasses

This is the path from a chosen window to a picture on the glasses, and the defects that path had. The glasses output is one session: the source is the player or the capture, not both.

The headless check is `other/browser-capture-selftest.sh`. It does not open a window. The manual checklist at the end is the real-Mac pass.

## Flow

1. **Choose a source.** Video → Choose Capture Window lists displays, then layer-0 windows that have a title. `SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false)` keeps full-screen windows that live on another Space. IINA's own capture window, chooser, and the player window while it is on the glasses are left out.

2. **Open the stream.** `SCStream` is configured at the window's pixel size (clamped to 3840×2160, even), `32BGRA`, queue depth 8, cursor off, 30 fps on macOS 13+. A window uses `SCContentFilter(desktopIndependentWindow:)`. A display uses `SCContentFilter(display:excludingWindows:)`. Audio, when on, is a second output on its own queue (48 kHz stereo, IINA excluded). Samples are copied before the callback returns.

3. **Frames.** The screen callback runs on the capture queue, not the main thread. Status comes from the sample-attachment CFDictionary without bridging that array to Swift. `.blank` shows the protected-video message and redraws. `.idle` or a missing image redraws. Any other status with an image is copied into a pixel buffer this process owns (`CVPixelBufferCreate` + `memcpy`), then handed to the renderer. A 30 fps timer redraws if ScreenCaptureKit goes quiet.

4. **Texture lifetime.** The copy is the only buffer the renderer locks. `CVMetalTextureCacheCreateTextureFromImage` makes a `bgra8Unorm` texture. The cache is flushed after `submitFrame`, which has already waited for the GPU. The ScreenCaptureKit buffer is not released again. The first frame logs mean luma (`first frame luma`) so a black protected source can be told apart from a drawable that was never sized.

5. **Depth and side-by-side.** Capture and the player each have a compositor, because the player pass runs on the OpenGL thread. Both call `Immersive3DController.submitFrame` → `immersiveStereo`. Capture forces the pass on (`colorIsBottomUp == false` means "this texture is the picture"). Until a depth map exists, a flat 0.5 depth texture is used, so the first frames are still side-by-side. A capture texture is sampled in full by each eye (`colorIsPicture`). A player texture is the glasses framebuffer, so a 16:9 picture on 3840×1080 is the center band and each eye samples that band.

6. **One glasses output.** `GlassesSession` is the state. `Play on Glasses` (menu item, the submenu display, the panel Exit button, and Send Capture to Glasses) calls the same transition.
   - Capture running, glasses off → pin the capture window borderless on the glasses. The player window stays put.
   - Capture not running → pin the player, as before.
   - Already on the glasses → leave.
   - Capture starts while a glasses display is connected → the capture takes the output. If the player was there, it is returned and restored when capture stops.
   - Capture stops → the capture window returns to the 960×540 preview, unless the player was displaced and should come back.
   - A screen-parameter change updates the recorded display and the existing pin runs again (2D/3D size change included).

7. **Drawable size.** `GlassesDrawable.pixels` is `points × backingScaleFactor`, rounded, and refuses anything under 32 pixels on a side. Glasses use the screen frame. The preview uses the view bounds, or 960×540 points when the view has no size yet. The size is locked while the window is on the glasses so a zero layout cannot replace it. `CAMetalLayer.drawableSize` is set on the main thread before present, and again from `layout` if the layer was not ready. Present blits on the main thread, does not wait for the GPU, and releases the in-flight slot in the command-buffer completion, including on error. Idle frames present the last texture when it still matches that size.

8. **Window follow.** Every 0.5 s, same idea as OBS `find_window`, but the list includes other Spaces. The current id wins while it is on screen. A matching title can replace it when full screen grows the window. If the id is gone, or the window has left the screen, the largest window with the same bundle id (Chrome: `com.google.Chrome`) is used, on any Space, even when the title changed. If that app has no window, the stream switches to the display the window overlapped. When a window of that app comes back, the stream leaves the display and follows the window again.

9. **Audio.** On macOS 13+, `capturesAudio` PCM is copied inside the callback and played by `AVAudioEngine` on the player's Core Audio device, following mpv volume, mute, and `auto` or `coreaudio/…`. Samples wait until the presented video timestamp catches up and drop when they are more than about 200 ms late. Mute Source App is the public macOS 14.2 process tap. It is off on macOS 13. A display fallback keeps the last source pid, so mute is not dropped just because the filter became a display.

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

## Residual risks

- CI has no glasses and no Screen Recording prompt. The self-test checks the session, the pixel math, the window follow, and one synthetic frame through `immersiveStereo` at 3840×1080. It does not present to a `CAMetalLayer` or capture a real window.
- Flat depth is used until the depth model returns a map. The picture is side-by-side with little parallax until then. A protected window stays black on purpose.
- Display fallback changes the filter to the whole screen. Window audio may not match that filter. Mute still targets the last app pid.
- The follow timer skips a tick when start or stop holds the session lock.
- Idle re-present holds one of the two frame slots. A main thread that does not drain presents can fill both until the one-second reclaim.
- Taking the glasses from the player and giving them back calls the mirror restore and the mirror split around that handoff.

## Manual test

On a Mac with Screen Recording allowed, and the glasses connected:

1. Start a capture of a Chrome window that is showing a normal page (not DRM). The preview should show it. The log should contain `output drawable` at the preview pixel size (960×540 points times the scale) and `glasses send` at that size, plus `first frame luma` well above 0.
2. Press **Play on Glasses** (Video menu). The capture window, not the player, should go borderless on the glasses at the screen pixel size (3840×1080 or 1920×1080). The log should contain `glasses source capture` and `output drawable` at that size. Both eyes should show the whole window, not a center crop and not black.
3. Press **Play on Glasses** again. The capture should return to the preview. The player window should not have moved.
4. Quit the capture. Start it again with the glasses still connected. The capture should land on the glasses without another click.
5. Put YouTube full screen in Chrome. The log should not stop at `no app+title match`. It should follow the largest Chrome window, or log `capturing display` for the screen Chrome was on, and the glasses should keep showing the video. Leave full screen and confirm the window is followed again.
6. With nothing capturing, **Play on Glasses** should still move the player, and Exit should restore it.
7. Start a capture while the player is already on the glasses. The player should leave and the capture should take the display. Stop the capture. The player should come back.
8. A DRM video should log a low `first frame luma` and the protected-window message. The glasses stay black. That is the intended result.
