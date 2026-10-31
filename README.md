# Angle Monitor

SwiftUI prototype for a live portrait level and a Picture in Picture experiment. It reads device motion at a requested 60 Hz, computes front/back inclination relative to a saved gravity direction, renders a fresh landscape 640×360 HUD frame at 30 fps, and submits the frames to `AVSampleBufferDisplayLayer`. The app and live PiP share switchable HUD designs B and C.

## Open and build

Open `AngleMonitor.xcodeproj` in Xcode and select the shared **AngleMonitor** scheme. The project targets iOS 17 or later. Connect and unlock an iPhone, accept the Trust prompt, then select an Apple Development Team under **Signing & Capabilities** so Xcode can install the app. Device motion and live PiP behavior require a physical iPhone.

The local build check on Xcode 26.0.1 with the iOS 26.0 SDK succeeded for the generic iPhoneOS target with code signing disabled. To repeat the unsigned compile check:

```sh
xcodebuild -project AngleMonitor.xcodeproj \
  -scheme AngleMonitor \
  -configuration Debug \
  -sdk iphoneos26.0 \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

An unsigned build cannot be installed on an iPhone. Select a development team in Xcode before running on the device.

Once installed, the app can be launched from the iPhone home screen without the Mac connected. Free Personal Team profiles expire seven days after issuance; if the app can no longer launch after expiration, reconnect to the Mac and rebuild/run it with automatic signing to renew and reinstall. The profile inspected on 2026-10-17 expires on **2026-10-24 at 00:09 JST**. See [Apple's Personal Team account limitations](https://developer.apple.com/help/account/basics/about-your-developer-account).

The project sets iOS 17 as a provisional minimum. Change the deployment target if the test device requires a different supported target.

The target declares the `audio` background mode required by Apple's Picture in Picture configuration. The app activates a `.playback` audio session only while requesting PiP, with audio mixing enabled; the HUD itself generates no audio.

## Prototype flow

### Design selection

Use the segmented **デザインB / デザインC** control below the portrait instrument. B preserves the scrolling central cyan ladder and fixed red reference. C uses fixed cyan rulers on the outer left/right, a thin solid white horizontal 0° reference behind the number, and a thick red line with arrow ends moving between the rulers behind the number. Positive values move the C pointer upward, negative values downward, and zero aligns it exactly with the white line. The fixed C ruler spans ±20°; beyond that its pointer stays at the edge with an overflow chevron while the central number continues to show the actual angle.

Selection immediately updates both the portrait instrument and subsequent frames on the existing PiP layer. It is saved in `UserDefaults` (`hudDesign`) for the next launch; the first run of this version defaults to C. Changing design does not reset the sensor baseline or replace the PiP controller/layer.

The central number uses the same sign palette in B, C, the portrait view and PiP: **positive = amber** (RGB 1.0, 0.72, 0.25), **negative = cyan**, and **near zero = green** (the existing `abs(angle) < 1°` threshold). The numeric plus/minus sign remains visible. Updated on-device sample-buffer images in `docs/validation` confirm the positive/negative colors.

Readability update (2026-10-18): the numeric font is another 25% larger in B and C. B has a wider readout area; narrow layouts condense the number horizontally to retain its height without clipping or covering C's outer rulers. Red lines are 1.5 times their previous thickness (landscape video: B fixed reference 7→10.5 px; C moving pointer 6→9 px). Red references are drawn below the numeric glyphs, with no opaque text background, so the line remains visible through character counters and gaps. The shared renderer applies these changes to the portrait instrument and PiP frames. The signed build was installed and launched on iPhone; exported video frames and portrait previews were visually checked for clipping. Live foreground generation remained at 30 fps with no dropped frames in the observed logs.

Further readability adjustment (2026-10-18): numeric font increased another 10%. C’s red pointer now extends almost to both outer rulers; B’s red wings extend farther inward. Both use a brighter red (RGB 1.0, 0.36, 0.35), beneath transparent numeric glyphs.

Device validation (2026-10-17): signed build installed on iPhone, live logs confirmed B→C switching in the video pipeline and steady 30 fps after startup. The app preferences file contained `hudDesign=C`. Actual sample-buffer frames in `docs/validation/hud-C-{0,1,2,3}.png` cover 0°, +12.4°, −12.4°, and +45°; `hud-C-portrait.png` covers the portrait layout, and `hud-B-1.png` confirms B rendering. Pixel checks verified unchanged ruler pixels, a fixed white reference, exact red/white coincidence at zero, and correct positive/negative pointer direction. Launch a Debug build with `--export-hud` to regenerate `hud-B-*` and `hud-C-*` files in the app Documents directory, including portrait previews.

### Motion and PiP

1. Launch the app and check the displayed pitch.
2. Press **0°にリセット** in the pose you want to use as the reference.
3. Tilt the phone forward and backward; the signed angle and indicator should move.
4. Press **PiP開始**, then move to Safari or another app.
5. Record whether the PiP remains visible and whether its angle continues changing.

The app is configured for the user's confirmed upright portrait use. It measures the screen normal's inclination to gravity, rather than extracting X twist from a full 3D attitude. Positive follows a forward rotation about the device X axis from its upright reset pose. In-screen lateral lean and world-vertical heading changes do not alter that inclination. Reset stores the projected gravity direction and sign; this basis never changes automatically during sideways movement. Re-zero with the phone standing upright after installing this measurement change.

## Cross-axis contamination fix (2026-10-17)

The previous fix prevented unbounded revolution accumulation, but its tests did not establish correct forward pitch during combined lateral and heading motion. That was insufficient: from an upright reference, turning heading by 90° and leaning sideways by 60°, without any forward tilt, produced **−60°** using the relative-quaternion X-twist method. A quaternion twist component is not a gravity-referenced inclinometer reading. The prior "bounded" tests passed while still allowing this wrong result.

`RelativePitchFilter` now uses Core Motion's processed `gravity` vector. In upright mode its inclination direction is formed from `hypot(g.x, g.y)` and the signed `g.z`; the relative angle to the saved zero direction is calculated using cross/dot products. Heading and lateral lean therefore cannot be mistaken for forward inclination in the upright physical-pose model. The app explicitly chooses upright mode and keeps it fixed. It uses `.xArbitraryZVertical` because magnetic heading is not needed. The filter still normalizes its state, rejects invalid vectors/timestamps, and does not integrate a turn counter. Raw user acceleration is logged for diagnosis, not added to gravity as if it were tilt. A nearly sideways reset cannot establish the intended upright sign, so it is refused with a visible instruction; an established zero continues through sideways movement.

The former 360°-accumulation bug was also real: an unnormalized filter state could remain at 360° after the input returned to zero. Normalizing the internal state fixed that arithmetic issue but did not fix the independent cross-axis error. The current implementation addresses both by measuring gravity-based inclination with a bounded relative filter.

Run the checks against the same filter compiled into the app:

```sh
swiftc AngleMonitor/RelativePitchFilter.swift Tests/RelativePitchFilterChecks.swift -o /private/tmp/AngleMonitorMotionChecks
/private/tmp/AngleMonitorMotionChecks
```

Result: **406,345 assertions passed**. Ground-truth orientations are constructed from independent physical rotation matrices, then world gravity is transformed into device coordinates. Tests cover known forward inclinations −80°…+80°, multiple zero inclinations, lateral lean −175°…+175°, multiple headings, inverted poses, fixed mode, invalid data, 30,000 repeated side/heading samples and 30,000 noisy-gravity samples. Crucially, these checks compare the expected pitch, not just a numerical range. The exact former −60° cross-axis counterexample now gives **0°**, as required.

The signed build is installed on the connected iPhone. Diagnostic launch argument `--trace-motion` logs gravity axes, raw/filtered inclination, measuring mode and user acceleration twice per second for hands-on comparison.

**User-reported device confirmation, 2026-10-17:** after holding the iPhone upright and resetting zero, the user tilted it laterally, changed its heading and returned it to the original pose. They confirmed that the reading remained near 0° and returned near 0° without a persistent offset. This confirms the reported lateral/heading case in hands-on use. The original strong/repeated-vibration environment and five-minute background stability remain separate validation items.

This is inclination, not a full-turn rotation tracker. Absolute screen-normal inclination is within ±90° before applying the zero offset; turning fully past horizontal folds the reading rather than counting revolutions. As with other gravity-based inclinometers, strong sustained acceleration can still affect the system's gravity estimate. See [Apple's gravity documentation](https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity) and [the nonmagnetic reference frame](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xarbitraryzvertical).

## Background verification record

**2026-10-17: PiP startup verified on an iPhone 13 Pro Max.** The signed build was installed and launched using `devicectl`. Device logs confirmed that the sample-buffer layer reached ready/rendering, `isPictureInPicturePossible` became true after the start action, and AVKit delivered `pictureInPictureControllerDidStartPictureInPicture`.

The startup failure had a reproducible clock mismatch: a newly created control timebase started at zero, while sample PTS used host uptime (22,459.86 seconds in the reproduction). Frames were therefore scheduled roughly six hours ahead. The timebase is now aligned to host time before its rate is set to 1. The corrected on-device clock difference was approximately 0.000020 seconds. Playback-session activation also now occurs before waiting for PiP eligibility, rather than after eligibility, avoiding a startup dependency cycle.

Observed device log:

```text
[AngleMonitor] video clock delta seconds: 1.9583851099014282e-05
[AngleMonitor] PiP possible=true, layer=準備完了 / 再生中
[AngleMonitor] requesting PiP start
[AngleMonitor] PiP did start
```

Live sensor updates while another app is foregrounded and five-minute PiP stability remain open validation items. PiP video presentation and Core Motion background execution are separate behaviors; successful PiP startup alone does not establish that the sensor continues running.

### HUD rendering verification (2026-10-17)

Smoothness update: sensor samples now go directly to the video pipeline instead of passing through a 10 Hz UI timer. Video generation and sample durations use 30 fps. The portrait instrument observes motion directly; a separate 2 Hz timer updates diagnostic text only. The renderer reuses a bounded pixel-buffer pool, checks layer backpressure before drawing, and logs frame rate, dropped frames, render time and sensor age every five seconds. Smoothing uses elapsed sensor time with a 75 ms time constant. Numeric font size and its available width are 20% larger in both layouts.

Short device validation after PiP start and backgrounding recorded 30.0 fps and zero dropped frames in successive five-second windows. Observed maximum frame render times were 3.3–11.9 ms, below the 33.3 ms frame budget; sampled sensor ages were 2.4–15.5 ms. These short observations do not replace the pending five-minute stability test.

The portrait instrument and landscape video now share `LevelRenderer.drawHUD`. Cyan graduations move together past the fixed red centre reference; their zero tick uses `centreY + angle × pixelsPerDegree`, so both references share exactly the same height at reset. The longer cyan zero tick is drawn continuously in front of the numeric readout and is 1.5 times the major graduation thickness (6 versus 4 pixels in the video).

Text is drawn with Core Text directly into the video CGContext. The previous UIKit string drawing did not have a current UIGraphics context, so the numeric reading never reached the PiP frames. The pixel-buffer coordinate system is now flipped once for the entire HUD, keeping glyphs and graduations aligned and upright.

Actual 640×360 video frames generated on the iPhone (not design mockups) are saved in `docs/validation/hud-0.png` (0°), `hud-1.png` (+12.4°), and `hud-2.png` (−12.4°). These were exported from the same `CMSampleBuffer` generation path used by PiP, inspected, and the signed build installed on the connected iPhone. To regenerate them in a Debug build, launch with `--export-hud`; files are written to the app's Documents directory. These are fixed-angle diagnostic frames, separate from the live sensor validation.

On a device, note the iOS version and model, then repeat the plan at 1, 5, and 15 minutes. Capture sensor and frame timestamp freshness independently, along with PiP/app state, after Home, Safari, screen lock, and return to the app. Do not claim the core requirement met unless the displayed live reading demonstrably tracks actual motion for at least five minutes in another app.

## Current limitations

- Minimal proof-of-concept UI; tune pitch axis/sign and smoothing on the actual phone.
- Sample-buffer timing, AVKit behavior, and picture geometry require an Xcode/iPhone run.
- The inline sample-buffer layer is attached to the preview view, and PiP start waits for AVKit's observable `isPictureInPicturePossible` state before requesting presentation.
- iOS may suspend app work after backgrounding. The prototype does not add an unrelated background mode to try to prevent that.
- A PiP session can show the last submitted image if rendering or sensor updates stop. Compare the on-screen timestamps and repeat physical movement to detect this.

Latest display adjustment (2026-10-18): numeric font increased another 8%; C pointer extends slightly past the outer rulers, and B wings are longer. Reference red is now RGB (1.0, 0.45, 0.43). The number remains above the red line with transparent counters and gaps.

Display adjustment (2026-10-18): C’s fixed zero reference remains white and is now 4.5 pt in portrait / 6 px in video; its moving red stroke is another 15% thicker. Central numeric font in both designs increased another 8%. No motion filtering changes were made.

## Vibration suppression mode

Use **振動抑制モード：オン／オフ** below the design selector. The setting is saved across launches (default off). On uses a 0.35 s exponential smoothing time constant and a 0.2° held-target deadband; off retains the original 0.075 s smoothing. Both the portrait instrument and live video consume the same filtered angle, so the readout and pointer agree. Switching preserves the zero reference and current output; resetting zero clears the held target. This suppresses small rapid fluctuations at the cost of response delay; it does not guarantee rejection of sustained vehicle acceleration or large shocks. Real vehicle vibration effectiveness remains unverified.

## Absolute inclination plus mounting correction

The filter now explicitly calculates an absolute gravity inclination and adds a stored mounting correction, then applies the selected smoothing. Upright screen is 0°, forward/back inclination is ±90°; sign follows the selected upright mounting orientation. This is not a direct readout of `CMAttitude.pitch`: its Euler folding around the upright pose would reintroduce ambiguous behavior. The existing lateral-lean-resistant gravity projection is retained. The diagnostic rows show the absolute inclination and correction separately. Startup still calibrates at the first valid upright sample; the mounting correction button replaces this value and resets the filtered display to zero. Correction is session-local and is not persisted. The corrected output is mathematically equivalent to the previous relative angle calculation; this change alone improves neither accuracy nor vehicle acceleration rejection. Calibrate on level ground for a vehicle-level reference.

### Absolute angle display mode

**絶対角度モード：オン／オフ** toggles between uncorrected gravity inclination and mounting-corrected output. On displays fixed-device-axis inclination with the upright screen at 0° (signed ±90°, not mathematical `abs()` and not standard Euler Pitch). It bypasses mounting correction and does not require successful upright calibration; zero-setting is disabled. Off restores the retained mounting correction. Mode switching seeds smoothing from the new angle on the next sensor sample to avoid blending two coordinate references. Vibration suppression applies to both modes. The mode preference persists across launches and defaults off.
