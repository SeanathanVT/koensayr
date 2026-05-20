package com.koensayr.y1.bridge;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;
import android.util.Log;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.Charset;

/**
 * MediaBridgeService — Binder host that satisfies MtkBt's
 * {@code bindService(Intent("com.android.music.MediaPlaybackService"))}.
 *
 * <p>The music APK cannot declare this intent-filter itself
 * ({@code sharedUserId="android.uid.system"} + JarVerifier — see
 * {@code docs/ARCHITECTURE.md}). The bridge process therefore hosts the
 * Binder. State queries from {@code BTAvrcpMusicAdapter} are answered live
 * from {@code /data/data/com.innioasis.y1/files/y1-track-info}, the
 * 2213-byte double-buffer file maintained by the music app's injected
 * {@code TrackInfoWriter} (Patch B5). The file is mmap'd once at first
 * read via {@link #getOrInitTrackInfoMap()} and held for the Service
 * lifetime; per-query reads become memory loads (no syscall, no
 * allocation per query) — same shared-inode trick the trampoline chain
 * in {@code libextavrcp_jni.so} uses on the BT-process side.
 * {@link #readTrackInfo()} dispatches the active slot and returns the
 * 1104-byte slot content so per-field offsets stay slot-relative.
 *
 * <p>The proactive {@code IBTAvrcpMusicCallback} dispatch path is handled
 * out-of-band by the music-app-side wake helpers plus MtkBt's cardinality
 * NOPs plus the trampoline chain in {@code libextavrcp_jni.so} — the
 * Binder only needs to answer the synchronous queries
 * ({@code getPlayStatus}, {@code position}, {@code duration},
 * {@code getAudioId}, {@code getTrackName}, etc.) with real values so
 * {@code BTAvrcpMusicAdapter.mRegBit} stays armed and the Java mirror
 * matches the on-disk state.
 */
public class MediaBridgeService extends Service {

    private static final String TAG = "Y1Bridge";

    private static final String TRACK_INFO_PATH =
            "/data/data/com.innioasis.y1/files/y1-track-info";
    // Double-buffer schema (post-mmap rework): file[0] = active_slot,
    // file[1..3] = RFA, file[4..1107] = slot[0], file[1108..2211] = slot[1],
    // file[2212] = RFA. readTrackInfo() returns the 1104-byte active slot
    // contents so the rest of this class's field offsets (OFF_AUDIO_ID,
    // OFF_TITLE, ...) remain slot-relative and unchanged.
    private static final int TRACK_INFO_FILE_SIZE = 2213;
    private static final int TRACK_INFO_SLOT_SIZE = 1104;
    private static final int TRACK_INFO_SLOT0_OFF = 4;
    // y1-papp-set — 2-byte (attr_id, AVRCP value) tuple consumed by the
    // music app's PappSetFileObserver. World-writable per ensureFile
    // (TrackInfoWriter.smali:243-245). Backstop sink when a Java-routed
    // PApp Set arrives without the wire PDU 0x14 going through T_papp.
    private static final String PAPP_SET_PATH =
            "/data/data/com.innioasis.y1/files/y1-papp-set";
    private static final byte PAPP_ATTR_REPEAT  = 0x02;
    private static final byte PAPP_ATTR_SHUFFLE = 0x03;

    private static final Charset UTF8 = Charset.forName("UTF-8");

    // y1-track-info schema (BE byte order for u32 / u64; see docs/BT-COMPLIANCE.md §4).
    private static final int OFF_AUDIO_ID          = 0;
    private static final int OFF_TITLE             = 8;
    private static final int OFF_ARTIST            = 264;
    private static final int OFF_ALBUM             = 520;
    private static final int OFF_DURATION_MS       = 776;
    private static final int OFF_POSITION_MS       = 780;
    private static final int OFF_STATE_CHANGE_TIME = 784;
    private static final int OFF_PLAY_STATUS       = 792;
    private static final int OFF_REPEAT_AVRCP      = 795;
    private static final int OFF_SHUFFLE_AVRCP     = 796;
    private static final int STRING_FIELD_LEN      = 256;

    private final IBinder mBinder = new AvrcpBinder();

    // Lazy-init mmap of y1-track-info shared with the music app's
    // TrackInfoWriter (same inode). The music app writes in-place via
    // RandomAccessFile.seek+write, the kernel page-cache propagates those
    // writes to this mapping, and per-query reads become memory loads —
    // no syscall per IBTAvrcpMusic Binder query.
    //
    // Static (process-global): readTrackInfo is invoked from AvrcpBinder
    // (which is a `private static final class`) and must therefore be
    // static itself. Holding the mmap as a static field is fine — there's
    // only one Y1Bridge process per Y1, the inode is always the same, and
    // the mapping lives until process exit. Java spec: closing the
    // FileChannel does NOT unmap the buffer; the mapping persists as long
    // as the buffer is referenced.
    private static volatile MappedByteBuffer sTrackInfoMap;
    private static final Object TRACK_INFO_MAP_LOCK = new Object();

    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "MediaBridgeService.onCreate");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return mBinder;
    }

    @Override
    public boolean onUnbind(Intent intent) {
        return true;
    }

    private static MappedByteBuffer getOrInitTrackInfoMap() {
        MappedByteBuffer m = sTrackInfoMap;
        if (m != null) return m;
        synchronized (TRACK_INFO_MAP_LOCK) {
            if (sTrackInfoMap != null) return sTrackInfoMap;
            RandomAccessFile raf = null;
            try {
                raf = new RandomAccessFile(TRACK_INFO_PATH, "r");
                FileChannel ch = raf.getChannel();
                m = ch.map(FileChannel.MapMode.READ_ONLY, 0, TRACK_INFO_FILE_SIZE);
                // FileChannel can be closed safely — the mapping lives in the
                // MappedByteBuffer's referent and persists across raf.close().
                sTrackInfoMap = m;
                return m;
            } catch (IOException e) {
                // Cold boot / file not yet at 2213 B / no permission. Caller
                // gets null and falls back to zero-filled defaults. Subsequent
                // calls retry init (no sticky-failure flag — same semantic as
                // the trampoline-side get_or_init_mmap).
                return null;
            } finally {
                if (raf != null) try { raf.close(); } catch (IOException ignored) {}
            }
        }
    }

    private static byte[] readTrackInfo() {
        // mmap path: dispatch active_slot, byte-copy 1104 active-slot bytes
        // into the return buffer (so per-field OFF_* offsets stay slot-
        // relative for the existing readBeU64 / readUtf8 helpers).
        //
        // System.arraycopy on a MappedByteBuffer slice is a JNI memcpy — much
        // cheaper than the prior open + read + close syscall chain.
        byte[] slot = new byte[TRACK_INFO_SLOT_SIZE];
        MappedByteBuffer m = getOrInitTrackInfoMap();
        if (m != null) {
            int active = m.get(0) & 0x1;
            int srcOff = TRACK_INFO_SLOT0_OFF + active * TRACK_INFO_SLOT_SIZE;
            // MappedByteBuffer.get(int) reads a single byte; for bulk copy
            // we duplicate, position, and get(byte[]) to avoid affecting
            // shared buffer position (the buffer is shared across all
            // Binder threads via the volatile field). MappedByteBuffer
            // extends ByteBuffer, and duplicate() returns ByteBuffer in
            // the JDK ≤ 12 API surface (Java 13+ added a covariant return
            // type override). Holding as ByteBuffer keeps us compatible
            // across all Android API levels.
            ByteBuffer dup = m.duplicate();
            dup.position(srcOff);
            dup.get(slot, 0, TRACK_INFO_SLOT_SIZE);
        }
        // m == null leaves slot zero-filled — sensible AVRCP defaults
        // (play_status=STOPPED, duration=0, empty strings). Same fallback
        // semantic as the prior FileInputStream-failure path.
        return slot;
    }

    private static long readBeU64(byte[] buf, int off) {
        long v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | (buf[off + i] & 0xffL);
        return v;
    }

    private static long readBeU32(byte[] buf, int off) {
        return ((buf[off]     & 0xffL) << 24)
             | ((buf[off + 1] & 0xffL) << 16)
             | ((buf[off + 2] & 0xffL) <<  8)
             |  (buf[off + 3] & 0xffL);
    }

    private static String readUtf8(byte[] buf, int off) {
        int end = off;
        int limit = off + STRING_FIELD_LEN;
        while (end < limit && buf[end] != 0) end++;
        return new String(buf, off, end - off, UTF8);
    }

    // Schema AVRCP enum (0=STOPPED, 1=PLAYING, 2=PAUSED) → IBTAvrcpMusicCallback
    // contract byte (1=STOPPED, 2=PLAYING, 3=PAUSED).
    private static byte avrcpToCallback(byte avrcpStatus) {
        switch (avrcpStatus & 0xff) {
            case 0:  return 1;
            case 1:  return 2;
            case 2:  return 3;
            default: return 3;
        }
    }

    // Write a 2-byte (attr_id, AVRCP value) tuple to y1-papp-set. The music
    // app's PappSetFileObserver picks it up on CLOSE_WRITE and applies via
    // SharedPreferencesUtils. Idempotent with the canonical wire path: if
    // T_papp 0x14 already wrote the same tuple, we just trigger a duplicate
    // observer fire with identical bytes — SharedPreferencesUtils setters
    // are no-ops when the value is unchanged.
    private static void writePappSet(byte attr, byte val) {
        FileOutputStream out = null;
        try {
            out = new FileOutputStream(PAPP_SET_PATH);
            out.write(new byte[]{ attr, val });
        } catch (IOException ignored) {
            // File may not exist yet (cold boot before TrackInfoWriter.init).
        } finally {
            if (out != null) try { out.close(); } catch (IOException ignored) {}
        }
    }

    private static long computePosition(byte[] buf) {
        long base = readBeU32(buf, OFF_POSITION_MS);
        if ((buf[OFF_PLAY_STATUS] & 0xff) != 1) return base;
        long anchor = readBeU32(buf, OFF_STATE_CHANGE_TIME);
        long elapsed = SystemClock.elapsedRealtime() - anchor;
        if (elapsed < 0) elapsed = 0;
        return base + elapsed;
    }

    private static final class AvrcpBinder extends Binder {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            if (code == INTERFACE_TRANSACTION) {
                return super.onTransact(code, data, reply, flags);
            }
            try {
                // Skip strictModePolicy + descriptor. Descriptor strings drift
                // across ROM variations; enforcing them historically left
                // BTAvrcpMusicAdapter.mRegBit empty (all registrations fell
                // through to super.onTransact()).
                data.readInt();
                data.readString();
                return dispatch(code, data, reply);
            } catch (Throwable t) {
                Log.w(TAG, "onTransact code=" + code + ": " + t);
                if (reply != null) reply.writeNoException();
                return true;
            }
        }
    }

    private static boolean dispatch(int code, Parcel data, Parcel reply)
            throws RemoteException {
        switch (code) {

            case 1:  // registerCallback(IBTAvrcpMusicCallback)
            case 2:  // unregisterCallback(IBTAvrcpMusicCallback)
                // Proactive notification is driven by the cardinality-NOP
                // wake path in MtkBt.odex + T9 trampoline, not the callback
                // Binder. Ack so registration succeeds.
                try { data.readStrongBinder(); } catch (Exception ignored) {}
                if (reply != null) reply.writeNoException();
                return true;

            case 3: // regNotificationEvent(byte eventId, int param) -> boolean
                // Returning false (or empty reply) leaves mRegBit empty and
                // every later notification is dropped before AVRCP emission.
                try { data.readByte(); data.readInt(); } catch (Exception ignored) {}
                if (reply != null) { reply.writeNoException(); reply.writeInt(1); }
                return true;

            case 4: { // setPlayerApplicationSettingValue(byte attr, byte val) -> boolean
                // Defensive backstop: T_papp 0x14 catches the wire PDU before
                // MtkBt's Java path forwards it to us, but if that ever misses
                // (or if MtkBt has a non-wire Java caller) the file write here
                // ensures PappSetFileObserver still applies the change.
                byte attr = 0, val = 0;
                try { attr = data.readByte(); val = data.readByte(); } catch (Exception ignored) {}
                if (attr == PAPP_ATTR_REPEAT || attr == PAPP_ATTR_SHUFFLE) {
                    writePappSet(attr, val);
                }
                if (reply != null) { reply.writeNoException(); reply.writeInt(1); }
                return true;
            }
            case 14: // setEqualizeMode(int) -> boolean
            case 16: // setShuffleMode(int)  -> boolean
            case 18: // setRepeatMode(int)   -> boolean
            case 20: // setScanMode(int)     -> boolean
                // Codes 16/18 are the AIDL-int counterparts to case 4 but the
                // int param's value semantics (Y1 enum vs AVRCP enum) aren't
                // documented in MtkBt's BTAvrcpMusicAdapter — would need
                // on-device verification before forwarding to y1-papp-set.
                // The canonical wire-PApp-Set path runs through T_papp 0x14
                // → case 4 above, so these stay ack-success no-ops.
                if (reply != null) { reply.writeNoException(); reply.writeInt(1); }
                return true;

            case 5: // getCapabilities() -> byte[]
                // 0x01 PLAYBACK_STATUS_CHANGED, 0x02 TRACK_CHANGED.
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeByteArray(new byte[]{ 0x01, 0x02 });
                }
                return true;

            // Passthrough — actual key delivery happens via libextavrcp_jni.so
            // uinput injection → ACTION_MEDIA_BUTTON → PlayControllerReceiver
            // (Patch E discrete arms). Bridge just acks.
            case 6:  case 7:  case 8:  case 9:
            case 10: case 11: case 12: case 13:
                if (reply != null) reply.writeNoException();
                return true;

            case 15: // getEqualizeMode()  -> int
            case 21: // getScanMode()     -> int
            case 36: // getQueuePosition() -> int
                if (reply != null) { reply.writeNoException(); reply.writeInt(0); }
                return true;

            case 17: { // getShuffleMode() -> int
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeInt(buf[OFF_SHUFFLE_AVRCP] & 0xff);
                }
                return true;
            }
            case 19: { // getRepeatMode() -> int
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeInt(buf[OFF_REPEAT_AVRCP] & 0xff);
                }
                return true;
            }

            case 22: // informDisplayableCharacterSet(int) -> boolean
            case 23: // informBatteryStatusOfCT()         -> boolean
                if (reply != null) { reply.writeNoException(); reply.writeInt(1); }
                return true;

            case 24: { // getPlayStatus() -> byte (callback contract: 1=STOPPED, 2=PLAYING, 3=PAUSED)
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeByte(avrcpToCallback(buf[OFF_PLAY_STATUS]));
                }
                return true;
            }
            case 25: { // position() -> long
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeLong(computePosition(buf));
                }
                return true;
            }
            case 26: { // duration() -> long
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeLong(readBeU32(buf, OFF_DURATION_MS));
                }
                return true;
            }
            case 27: { // getAudioId() -> long
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeLong(readBeU64(buf, OFF_AUDIO_ID));
                }
                return true;
            }
            case 28: { // getTrackName() -> String
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeString(readUtf8(buf, OFF_TITLE));
                }
                return true;
            }
            case 29: { // getAlbumName() -> String
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeString(readUtf8(buf, OFF_ALBUM));
                }
                return true;
            }
            case 30: { // getAlbumId() -> long
                // Schema doesn't carry album_id, so synthesize from the album
                // name with the same hash scheme TrackInfoWriter uses for
                // audio_id when MediaStore _ID isn't available. Bit prefix
                // 0x200000000L distinguishes it from audio_id's 0x100000000L
                // so the two can't collide. Empty album → 0 (was the old
                // benign default).
                byte[] buf = readTrackInfo();
                String album = readUtf8(buf, OFF_ALBUM);
                long id = album.isEmpty()
                        ? 0L
                        : (((long) album.hashCode()) & 0xFFFFFFFFL) | 0x200000000L;
                if (reply != null) { reply.writeNoException(); reply.writeLong(id); }
                return true;
            }

            case 31: { // getArtistName() -> String
                byte[] buf = readTrackInfo();
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeString(readUtf8(buf, OFF_ARTIST));
                }
                return true;
            }

            case 32: // enqueue(long[], int) -> void
            case 35: // open(long[], int)    -> void
            case 37: // setQueuePosition(int) -> void
                if (reply != null) reply.writeNoException();
                return true;

            case 33: // getNowPlaying() -> long[]
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeLongArray(new long[0]);
                }
                return true;

            case 34: // getNowPlayingItemName(long) -> String
                if (reply != null) { reply.writeNoException(); reply.writeString(""); }
                return true;

            default:
                if (reply != null) reply.writeNoException();
                return true;
        }
    }
}
