# ExhaustStudio 650 — Setup Guide

## 1. Project structure

```
exhaust_studio/
├── pubspec.yaml                    ← dependencies (includes gal for gallery export)
├── lib/
│   ├── main.dart                   ← app entry point & home screen
│   └── waveform_screen.dart        ← FFmpeg log-stream waveform visualiser
└── android/
    └── app/src/main/kotlin/…/
        └── MainActivity.kt         ← Android entry point (MethodChannel hooks)
```

---

## 2. Place MainActivity.kt

Copy `android/app/src/main/kotlin/com/example/exhaust_studio/MainActivity.kt`
into your project at the path that matches your actual package name.

The default Flutter package path is `com/example/exhaust_studio`.
If you created the project with a custom org, adjust the `package` declaration
at the top of the file to match.

---

## 3. AndroidManifest.xml — permissions & application flags

Open `android/app/src/main/AndroidManifest.xml`.

### 3a. Add inside `<manifest>` (before `<application>`):

```xml
<!-- Read videos from gallery (Android 13+) -->
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- Fallback read permission for Android ≤12 -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />

<!-- Write to public Movies folder for Android ≤9 (API 28 and below only) -->
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28" />
```

No `WRITE_EXTERNAL_STORAGE` is needed on Android 10+ — `gal` writes directly
through MediaStore scoped-storage APIs and triggers the gallery index
automatically.

### 3b. Add to the `<application>` tag (Android 10 / API 29 compatibility):

```xml
<application
    ...
    android:requestLegacyExternalStorage="true">
```

This flag is only active on Android 10 (API 29) — newer versions ignore it.
It prevents a scoped-storage edge case where MediaStore sometimes fails to
create a new album on the very first save on that specific OS version.

---

## 4. android/app/build.gradle — minSdk & ABI filters

Open `android/app/build.gradle` and update the `defaultConfig` block:

```groovy
android {
    defaultConfig {
        minSdkVersion 24        // ffmpeg_kit_flutter requires API 24 minimum
        targetSdkVersion 34
        ...
    }

    // ABI filters — include only the ABIs you ship to reduce APK size
    splits {
        abi {
            enable true
            reset()
            include "arm64-v8a", "armeabi-v7a", "x86_64"
            universalApk false   // set true if you need a fat APK for testing
        }
    }
}
```

### Size notes

| ABI filter set | Approx. added size (ffmpeg_kit .so) |
|---|---|
| arm64-v8a only | ~38 MB |
| arm64-v8a + armeabi-v7a | ~58 MB |
| All 4 ABIs (universal) | ~120 MB |

Use `splits.abi` in development and let the Play Store handle per-device APK
splitting in production (upload an AAB instead of APK).

---

## 5. Install dependencies

```bash
flutter pub get
```

This fetches all packages including:
- `ffmpeg_kit_flutter_video ^6.0.3` — Video LTS FFmpeg bundle
- `gal ^1.3.0` — Gallery export (MediaStore on Android, PHPhotoLibrary on iOS)

---

## 6. Build & run

```bash
flutter run --release   # release mode skips debug overhead — FFmpeg is faster
```

---

## 7. How sliders map to the FFmpeg filter chain

| Slider | Left (0%) | Right (100%) |
|---|---|---|
| Noise Cleanup | highpass=60Hz, lowpass=9000Hz | highpass=180Hz, lowpass=4000Hz |
| Exhaust Deepness | 200Hz EQ +0dB (flat) | 200Hz EQ +12dB |

The full `-af` chain is printed to the debug console on every run —
look for `[ExhaustStudio] Running FFmpeg:`.

---

## 8. Output location

Processed videos are saved to the device **Gallery** under the album:

```
ExhaustStudio
```

The `gal` package writes through MediaStore (`ContentResolver.insert`) on
Android 10+ and through PHPhotoLibrary on iOS. The file appears in the native
Gallery app instantly — no reboot or manual media-scan required.

On Android ≤9 (API 28), `gal` writes to the public Movies directory and
fires `ACTION_MEDIA_SCANNER_SCAN_FILE` internally.

---

## 9. Performance notes

- `-c:v copy` means the video track is **never decoded or re-encoded**.
  Only the audio stream is processed — a 2-minute 4K video typically
  exports in under 5 seconds on mid-range Android hardware.
- `ffmpeg_kit_flutter_video` (LTS bundle) ships all audio filters used in
  the pipeline (`highpass`, `lowpass`, `equalizer`, `acompressor`, `volume`,
  `alimiter`). No additional codec packs are needed.

---

## 10. Troubleshooting

### "minSdkVersion must be at least 24"
Set `minSdkVersion 24` in `android/app/build.gradle` (see step 4).

### APK too large (>150 MB)
Enable ABI splits (see step 4). For Play Store distribution upload an AAB
(`flutter build appbundle`) — Google Play delivers per-device splits automatically.

### Video doesn't appear in Gallery after processing
1. Confirm `android:requestLegacyExternalStorage="true"` is set on the
   `<application>` tag (step 3b) — required for Android 10 first-save.
2. Check that `READ_MEDIA_VIDEO` / `READ_EXTERNAL_STORAGE` permissions were
   granted at runtime (the app requests them before picking the source video).
3. On Android 11+ the MediaStore index can take 1–2 seconds to surface the
   file — wait a moment and pull-to-refresh in Gallery.
4. Run `flutter run` (debug) and check logcat for `GalPlugin` or `gal` tags
   to see the exact MediaStore URI that was written.

### `GalException` — "No access to the gallery"
Call `Gal.requestAccess(toAlbum: true)` before saving, or go to
**Settings → Apps → ExhaustStudio → Permissions → Photos / Media** and grant access.

### FFmpeg session returns non-zero exit code
The full FFmpeg log is surfaced in the WaveformScreen log readout and via
`debugPrint`. Run with `flutter run` (not `--release`) and search logcat for
`[ExhaustStudio]`.
Common causes: unsupported input codec, corrupt source file, or insufficient
storage space for the output.
