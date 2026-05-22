# Y1Bridge

Binder host for the Innioasis Y1 AVRCP pipeline. Hosts the
`IBTAvrcpMusic` Binder MtkBt resolves to via
`bindService(com.android.music.MediaPlaybackService)`, and serves the
synchronous state queries that drive MtkBt's Java-side mirror.

## Why this APK exists

MtkBt's `BTAvrcpMusicAdapter.checkAndBindPlayService` calls
`Context.bindService(Intent("com.android.music.MediaPlaybackService"))` to
find its AVRCP TG companion. The music app (`com.innioasis.y1`) cannot
declare this intent-filter in its manifest because it's signed with the OEM
platform key (required by `android:sharedUserId="android.uid.system"`) and
any change to `AndroidManifest.xml` invalidates `META-INF/MANIFEST.MF`'s
recorded SHA1-Digest. PackageManager rejects the APK at `/system/app/` scan
with "no certificates at entry AndroidManifest.xml; ignoring!" — see
[`docs/INVESTIGATION.md`](../../docs/INVESTIGATION.md) for the
JarVerifier RE.

Y1Bridge is its own package (`com.koensayr.y1.bridge`), signed with the
debug keystore. Its manifest is freely editable. It exists solely to
declare the `<service>` MtkBt's `bindService` resolves to.

## What it does

- `MediaBridgeService.onBind` returns a `Binder` whose `onTransact`
  implements the `IBTAvrcpMusic` codes MtkBt's `BTAvrcpMusicAdapter`
  calls — primarily `getPlayStatus` (24), `position` (25), `duration` (26),
  `getAudioId` (27), `getTrackName` (28), `getAlbumName` (29),
  `getArtistName` (31), `getRepeatMode` (19), `getShuffleMode` (17), and
  `getCapabilities` (5) — by reading live values from
  `/data/data/com.innioasis.y1/files/y1-track-info` (the 2213-byte double-
  buffer file maintained by the music app's injected `TrackInfoWriter`,
  world-readable per `setReadable(true, false)`). The file is `mmap`'d
  once at first query via `FileChannel.map(READ_ONLY, 0, 2213)` and held
  in a `MappedByteBuffer` for the Service lifetime — per-query reads
  become memory loads (zero syscalls per Binder query). The kernel page
  cache propagates the music app's in-place writes through the shared
  inode, so the bridge always sees current state without re-opening the
  file. `MediaBridgeService.readTrackInfo` dispatches `file[0]` to the
  active 1104-byte slot before per-field parsing. Callback-register,
  notification-register, setter, and passthrough codes (1–4, 6–16, 18,
  20–23, 32–37) ack with the success replies that keep
  `BTAvrcpMusicAdapter.mRegBit` armed.
- The proactive wake path is independent of the Binder: the music app
  fires `com.android.music.metachanged` / `com.android.music.playstatechanged`, MtkBt's
  cardinality-NOP-patched JNI natives fire, and the trampoline chain in
  `libextavrcp_jni.so` builds the wire response from the same
  `y1-track-info` file.
- `BootReceiver` listens for `BOOT_COMPLETED` and calls
  `startService(MediaBridgeService)` so the Service is alive when MtkBt
  first binds.

## What it does NOT do

All AVRCP observation + state production lives in the music app
(`com.innioasis.y1`) via the Patch B3..B5 smali injections in
`src/patches/inject/com/koensayr/y1/*` (B6's `AvrcpBinder` is dormant
groundwork — see `docs/PATCHES.md`):

- `TrackInfoWriter` — writes the 2213-byte double-buffer `y1-track-info`
  and the 2-byte `y1-papp-set` under `/data/data/com.innioasis.y1/files/`
  (the trampoline chain in `libextavrcp_jni.so` mmaps the first and reads
  the second on CT-initiated PApp Set). Trampoline edge state lives in
  `libextavrcp_jni.so` `.bss` (no on-disk artifact).
- `PlaybackStateBridge` — hooks the music app's player engine
  (`Static.setPlayValue` + IjkMediaPlayer / `android.media.MediaPlayer`
  listener lambdas). State edges observed in-process, no logcat scraping,
  no foreground/background visibility gaps.
- `BatteryReceiver` — bucket-maps `ACTION_BATTERY_CHANGED` and fires
  `com.android.music.playstatechanged` so T9 emits `BATT_STATUS_CHANGED CHANGED`.
- `PappSetFileObserver` + `PappStateBroadcaster` — round-trip Repeat /
  Shuffle between the CT and the music app's SharedPreferences.

See [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) for the full
trampoline chain reference.

## Build

```bash
cd src/Y1Bridge && ./gradlew --stop && ./gradlew assembleDebug
```

Output: `app/build/outputs/apk/debug/app-debug.apk` (~5-10 KB). `apply.bash
--avrcp` copies it to `/system/app/Y1Bridge.apk` at flash time.

Source is tiny — three files total:

- `app/src/main/java/com/koensayr/y1/bridge/MediaBridgeService.java` (~440 lines)
- `app/src/main/java/com/koensayr/y1/bridge/BootReceiver.java` (~24 lines)
- `app/src/main/AndroidManifest.xml` (~41 lines)
