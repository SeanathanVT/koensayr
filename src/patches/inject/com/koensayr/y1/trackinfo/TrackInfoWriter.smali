.class public final Lcom/koensayr/y1/trackinfo/TrackInfoWriter;
.super Ljava/lang/Object;
.source "TrackInfoWriter.smali"


# Singleton holder + double-buffer writer for /data/data/com.innioasis.y1/files/y1-track-info.
#
# Schema (2213 bytes): file[0]=active_slot, file[1..3]=RFA, file[4..1107]=slot[0],
# file[1108..2211]=slot[1], file[2212]=RFA. Each slot holds the 1104-byte track-info
# image (audio_id / title / artist / album / position / status / battery / papp /
# etc.) at the same per-field offsets that pre-mmap code used at file[0..1103].
#
# flushLocked picks inactive = 1 - active_slot, writes the 1104-byte image into the
# inactive slot via RandomAccessFile.seek+write, then atomically updates file[0]
# to point at the just-written slot. Single-byte writes to offset 0 are atomic on
# ARMv7 (aligned strb), so libextavrcp_jni.so's reader (mmap'd) never sees a torn
# slot — at any instant slot[file[0]] is the consistent snapshot from the last
# completed flush.
#
# All public mutators are synchronized on INSTANCE. flushLocked() is called inline
# from the calling thread (Static.setPlayValue runs on main; callbacks are off-main
# but file IO is small + state-edge frequency only — single-threaded acceptable).


# static fields
.field public static final INSTANCE:Lcom/koensayr/y1/trackinfo/TrackInfoWriter;


# instance fields
.field private mContext:Landroid/content/Context;

.field private mFilesDir:Ljava/io/File;

# 0=STOPPED, 1=PLAYING, 2=PAUSED — AVRCP 1.3 §5.4.1 Tbl 5.26
.field private mPlayStatus:B

.field private mPositionAtStateChange:J

.field private mStateChangeTime:J

.field private mPreviousTrackNaturalEnd:Z

# Latched between onCompletion (true) and the next onTrackEdge (consumed→cleared).
# onCompletion only fires when the player engine reaches end-of-stream, so this
# is the canonical natural-end signal — no extrapolation needed.
.field private mPendingNaturalEnd:Z

# AVRCP §5.4.2 Tbl 5.35 enum: 0=NORMAL 1=WARNING 2=CRITICAL 3=EXTERNAL 4=FULL_CHARGE
.field private mBatteryStatus:B

# AVRCP §5.2.4 Tbl 5.20 Repeat (default OFF=0x01)
.field private mRepeatAvrcp:B

# AVRCP §5.2.4 Tbl 5.21 Shuffle (default OFF=0x01)
.field private mShuffleAvrcp:B

# Cached current-track metadata populated by flushLocked, consumed by
# wakeTrackChanged / wakePlayStateChanged so MMI_AVRCP's Java mirror sees
# AOSP-convention Intent extras (id / track / artist / album / playing).
.field private mCachedAudioId:J

.field private mCachedTitle:Ljava/lang/String;

.field private mCachedArtist:Ljava/lang/String;

.field private mCachedAlbum:Ljava/lang/String;

# Last duration value PlayerService.getDuration() returned while prepared.
# flushLocked preserves it across prepare gaps so y1-track-info[776..779]
# never falls back to 0 (which CTs treat as "duration unknown" and hide
# the playhead display).
.field private mLastKnownDuration:J

# elapsedRealtime() at the most recent real (audio_id-changed) onTrackEdge
# fire. onSeek consults this to suppress the music app's playerPrepared()
# restore-from-saved-progress seek (3 setCurrentPosition sites in stock
# playerPrepared, lines 1737/1793/1923) — without it, those calls
# overwrite our reset-to-0 from onEarlyTrackChange and the wire-side
# playhead resumes from the user's prior pause point on the new track.
#
# 2 s suppression window covers prepareAsync + OnPreparedListener + the
# playerPrepared restore. User-initiated seeks (seek-bar drag) come well
# after, so they're not affected.
.field private mLastFreshTrackChangeAt:J

# Rate-limit gate state for wakePlayStateChanged. AVRCP 1.3 §5.4.2 Tbl 5.33
# leaves PLAYBACK_POS_CHANGED cadence to the TG; nominal 1Hz is the floor
# for any spec-conforming CT. Cascading callbacks during a single track-edge
# (onPlayValue + onPrepared + onPlayerPreparedTail + PositionTicker) used
# to fire 3+ wakes in <200ms, producing back-to-back position CHANGED
# emits that saturate strict §6.7.1 CTs' AVCTP buffer (observed on Bolt
# 2112 — 21 of 75 ev=05 RegNotifs arrived within <500ms of the previous
# one). wakePlayStateChanged now coalesces same-play_status wakes within
# 800ms of the previous broadcast — real play-state edges (mPlayStatus
# changed) always bypass.
.field private mLastWakePlayStateAt:J

.field private mLastWakePlayStatus:B

# MediaMetadataRetriever-derived duration cache. Y1 music app stores no
# DB-cached duration; PlayerService.getDuration() delegates to
# IjkMediaPlayer/MediaPlayer.getDuration() which throws before
# prepareAsync completes. Without an alternate source the first T4
# GetElementAttributes response on every track skip carries dur=0
# (attribute 0x07 PlayingTime = "0"), which strict CTs cache as
# "duration unknown" — AVRCP 1.3 has no DURATION_CHANGED event so a
# §6.7.1-correct second TRACK_CHANGED CHANGED (same audio_id) cannot
# refresh it once the real duration arrives via B5.2c's playerPrepared
# tail ~700 ms later. MediaMetadataRetriever.setDataSource(path) +
# extractMetadata(METADATA_KEY_DURATION) reads the file's container
# header synchronously without involving the C++ MediaPlayer, so it's
# safe to call from any state. Per-audio_id cache keeps the cost to one
# header parse per track (~10-50 ms for local MP3/M4A).
.field private mMmrAudioId:J

.field private mMmrDurationMs:J


# direct methods
.method static constructor <clinit>()V
    .locals 1

    new-instance v0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;

    invoke-direct {v0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;-><init>()V

    sput-object v0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->INSTANCE:Lcom/koensayr/y1/trackinfo/TrackInfoWriter;

    return-void
.end method

.method private constructor <init>()V
    .locals 2

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    const/4 v0, 0x0

    iput-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPreviousTrackNaturalEnd:Z

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    iput-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mBatteryStatus:B

    const/4 v1, 0x1

    iput-byte v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mRepeatAvrcp:B

    iput-byte v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mShuffleAvrcp:B

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    const-string v0, ""

    iput-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedTitle:Ljava/lang/String;

    iput-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedArtist:Ljava/lang/String;

    iput-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAlbum:Ljava/lang/String;

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrAudioId:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    return-void
.end method


# Initialise on Application.onCreate. Idempotent.
.method public declared-synchronized init(Landroid/content/Context;)V
    .locals 3

    monitor-enter p0

    :try_start_0
    iget-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mContext:Landroid/content/Context;

    if-eqz v0, :cond_init

    monitor-exit p0

    return-void

    :cond_init
    invoke-virtual {p1}, Landroid/content/Context;->getApplicationContext()Landroid/content/Context;

    move-result-object v0

    iput-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mContext:Landroid/content/Context;

    invoke-virtual {v0}, Landroid/content/Context;->getFilesDir()Ljava/io/File;

    move-result-object v0

    iput-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mFilesDir:Ljava/io/File;

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v1

    iput-wide v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->prepareFilesLocked()V

    # Flush y1-track-info immediately at init so MtkBt's first read returns
    # the in-memory defaults (Repeat=0x01 OFF, Shuffle=0x01 OFF — valid AVRCP
    # §5.2.4 Tbl 5.20 / 5.21 values) rather than the zero-fill that an
    # unwritten file would give. Without this, CTs that subscribe to
    # PLAYER_APPLICATION_SETTING_CHANGED before B4's first sendNow() can
    # latch onto file[795..796] = [0,0] (invalid AVRCP enum) and refuse to
    # follow subsequent CHANGED events.
    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Make filesDir traversable for the BT process (uid bluetooth) and pre-create
# the music-app-owned data files world-rw. y1-track-info gets pre-sized to
# 2213 B so the trampolines' first mmap covers a valid file. y1-papp-set is
# pre-created so T_papp 0x14 can open without O_CREAT on CT-initiated PApp Set.
.method private prepareFilesLocked()V
    .locals 4

    :try_start_0
    iget-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mFilesDir:Ljava/io/File;

    if-nez v0, :cond_dir

    return-void

    :cond_dir
    const/4 v1, 0x1

    const/4 v2, 0x0

    invoke-virtual {v0, v1, v2}, Ljava/io/File;->setExecutable(ZZ)Z

    const-string v1, "y1-papp-set"

    const/4 v2, 0x2

    invoke-direct {p0, v1, v2}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->ensureFile(Ljava/lang/String;I)V

    # Pre-size y1-track-info to the double-buffer schema (2213 bytes:
    # active_slot byte + 3 RFA + slot[0] 1104 B + slot[1] 1104 B + 1 RFA).
    # The libextavrcp_jni.so trampolines mmap this file lazily on first
    # read; mmap requires the file to be at least the mapping size before
    # the first map call. ensureFile zeros the file content, so initial
    # active_slot = 0 and both slots are empty until flushLocked overwrites
    # slot[0]'s area on its first call.
    const-string v1, "y1-track-info"

    const/16 v2, 0x8a5

    invoke-direct {p0, v1, v2}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->ensureFile(Ljava/lang/String;I)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    const-string v1, "Y1Patch"

    invoke-virtual {v0}, Ljava/lang/Throwable;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v1, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


# Touch <name> to <size> bytes if missing; chmod world-rw.
.method private ensureFile(Ljava/lang/String;I)V
    .locals 4

    new-instance v0, Ljava/io/File;

    iget-object v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mFilesDir:Ljava/io/File;

    invoke-direct {v0, v1, p1}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    invoke-virtual {v0}, Ljava/io/File;->exists()Z

    move-result v1

    if-eqz v1, :cond_exists

    return-void

    :cond_exists
    new-instance v1, Ljava/io/FileOutputStream;

    invoke-direct {v1, v0}, Ljava/io/FileOutputStream;-><init>(Ljava/io/File;)V

    :try_start_0
    new-array v2, p2, [B

    invoke-virtual {v1, v2}, Ljava/io/FileOutputStream;->write([B)V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    invoke-virtual {v1}, Ljava/io/FileOutputStream;->close()V

    const/4 v1, 0x1

    const/4 v2, 0x0

    invoke-virtual {v0, v1, v2}, Ljava/io/File;->setReadable(ZZ)Z

    invoke-virtual {v0, v1, v2}, Ljava/io/File;->setWritable(ZZ)Z

    return-void

    :catchall_0
    move-exception v3

    invoke-virtual {v1}, Ljava/io/FileOutputStream;->close()V

    throw v3
.end method


# Public mutator: AVRCP play-status edge. Captures position/time-at-edge.
# Returns silently if status unchanged (dedupe).
#
# Inline track-edge detection (perceived-responsiveness optimisation): if
# flushLocked recomputes mCachedAudioId to a different value than the
# pre-flush snapshot, the music-app's internal nextSong/prevSong/restartPlay
# sequence has already advanced mPlayingMusic to a new track. This pause-
# flush is the earliest possible point we observe the audio_id change —
# ~260 ms BEFORE PlayerService.toRestart()'s setDataSource sites where
# B5.2b's onEarlyTrackChange currently fires. Resetting position +
# mLastKnownDuration to 0 here and re-flushing keeps the file internally
# consistent (new audio_id + new title + 0 position + 0 duration) so T4
# GetElementAttributes responses + T9 POS_CHANGED + T5 TRACK_CHANGED all
# show the CT a coherent "track just started" state in the same broadcast
# cycle. Without this, the CT briefly sees new_audio_id + new_title +
# stale_position (e.g., 15.7 s into a track that "just started"), which
# stricter CTs latch onto and visibly lag before the next consistent
# update arrives. Returns silently for resume-from-pause (audio_id
# unchanged) — no extra work.
.method public declared-synchronized setPlayStatus(B)V
    .locals 7

    monitor-enter p0

    :try_start_0
    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    if-ne v0, p1, :cond_changed

    # Same-state setPlayStatus call. Normally a no-op, but if newStatus is
    # PLAYING (1) we re-anchor from MediaPlayer.getCurrentPosition() before
    # returning. Y1's music app fires setPlayValue(1) at multiple points
    # (track-load init, audio-focus regain, restartPlay's auto-resume)
    # often BEFORE MediaPlayer actually begins emitting audio. The first
    # such call sets mPlayStatus=1 + stamps mStateChangeTime at that
    # pre-play moment; subsequent setPlayStatus(1) calls early-return
    # without re-stamping, so the trampoline's live_pos = anchor +
    # (now - stale_time) accumulates phantom seconds until actual
    # playback start. Bolt's playhead then renders ahead-of-reality (Bolt
    # 1326 capture: Y1 UI 0:30 vs IPC-shipped 3:18 = 2:48 phantom drift).
    # Ground-truthing here keeps IPC in sync with MediaPlayer regardless
    # of which redundant setPlayStatus(1) the actual play-start lands on.
    const/4 v1, 0x1

    if-ne p1, v1, :early_return

    invoke-static {}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->getPlayerService()Lcom/innioasis/y1/service/PlayerService;

    move-result-object v1

    if-eqz v1, :early_return

    invoke-virtual {v1}, Lcom/innioasis/y1/service/PlayerService;->getPlayerIsPrepared()Z

    move-result v2

    if-eqz v2, :early_return

    invoke-virtual {v1}, Lcom/innioasis/y1/service/PlayerService;->getCurrentPosition()J

    move-result-wide v2

    iput-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v2

    iput-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    :early_return
    monitor-exit p0

    return-void

    :cond_changed
    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->computeLivePositionLocked()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    iput-byte p1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    # Snapshot audio_id BEFORE flushLocked. The flush re-reads PlayerService
    # state which by this point may already reflect a new track (the music
    # app's nextSong/prevSong/restartPlay flow updates mPlayingMusic before
    # the pause() call that brings us here).
    iget-wide v5, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    # Compare new mCachedAudioId (just written) with snapshot. If different,
    # this play-status edge is the leading edge of a track change — reset
    # position + duration to 0 and re-flush so the file is internally
    # consistent before any T4/T5/T6/T9 response sees it.
    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    cmp-long v3, v5, v0

    if-eqz v3, :cond_no_edge

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastFreshTrackChangeAt:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    :cond_no_edge
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Public mutator: seek edge. Captures the new position as the live anchor
# so T6 / T9 / T8's clock_gettime extrapolation runs forward from there.
# Without this, a user-initiated seek (via the music app's seek bar) leaves
# the anchor at the previous position and the CT's playhead either jumps
# back to the pre-seek value or freezes until the next state edge.
#
# Suppression window: PlayerService.playerPrepared() in stock 3.0.2 calls
# setCurrentPosition(savedTime) at three sites (lines 1737/1793/1923 —
# restoreStartTime / Bookmark.startTime / Progress.startTime) right after
# prepareAsync completes. Desirable for the local UI but overwrites the
# reset-to-0 our onEarlyTrackChange stamped — wire-side playhead would
# resume from the prior pause point on the freshly-skipped track. Suppress
# onSeek for ~2 s after a fresh-track-change reset; user-initiated seeks
# (seek-bar drag) come well after.
.method public declared-synchronized onSeek(J)V
    .locals 5

    monitor-enter p0

    :try_start_0
    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastFreshTrackChangeAt:J

    const-wide/16 v2, 0x0

    cmp-long v4, v0, v2

    if-eqz v4, :cond_normal

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v2

    sub-long/2addr v2, v0

    const-wide/16 v0, 0x7d0

    cmp-long v4, v2, v0

    if-gez v4, :cond_normal

    # Within ~2 s of a fresh track-change reset — this seek is almost
    # certainly playerPrepared's restore-from-saved-progress call.
    # Skip the position update (and the wakePlayStateChanged broadcast,
    # since nothing changed). Don't clear mLastFreshTrackChangeAt — if
    # playerPrepared somehow fires a second restore call (e.g. for
    # bookmark + progress) we want to suppress that too.
    monitor-exit p0

    return-void

    :cond_normal
    iput-wide p1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_seek

    monitor-exit p0

    invoke-virtual {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->wakePlayStateChanged()V

    return-void

    :catchall_seek
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Latch a natural-end signal from MediaPlayer.OnCompletionListener. The next
# onTrackEdge consumes + clears it. Also freezes the playhead anchor at
# duration so T9 / T6 stop extrapolating past end-of-track during the gap
# until onPrepared fires for the next track — CTs hide the playhead when
# position > duration arrives on the wire.
.method public declared-synchronized markCompletion()V
    .locals 3

    monitor-enter p0

    :try_start_0
    const/4 v0, 0x1

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Clear any pending natural-end (e.g., on OnError — interrupted, not natural end).
.method public declared-synchronized markError()V
    .locals 1

    monitor-enter p0

    :try_start_0
    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Unconditional fresh-track reset. Called from PlaybackStateBridge.onEarlyTrackChange
# (invoked from PlayerService.toRestart's setDataSource sites — a guaranteed
# track-load entry). Resets position-anchor + mLastKnownDuration + stamps
# mLastFreshTrackChangeAt; bypasses audio_id dedup.
#
# Dedup wouldn't work here: restartPlay() pauses before toRestart(), and pause's
# setPlayValue → flushLocked has already updated mCachedAudioId — by the time
# onTrackEdge would snapshot it, old==new.
#
# mLastKnownDuration reset is critical: flushLocked falls back to the cached
# duration when getPlayerIsPrepared() is false (the prepareAsync gap). Without
# the reset, the file briefly reports the previous track's duration. 0 reads
# as "unknown" per AVRCP 1.3 Appendix E attr 0x07 (PlayingTime); the B5.2c playerPrepared-tail
# hook re-flushes once getPlayerIsPrepared() flips true.
.method public declared-synchronized onFreshTrackChange()V
    .locals 3

    monitor-enter p0

    :try_start_0
    iget-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPreviousTrackNaturalEnd:Z

    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastFreshTrackChangeAt:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Soft track edge: dedup-gated reset for re-prepare paths that may or may not
# represent a real track change. Called from PlaybackStateBridge.onPrepared
# (OnPreparedListener fires on every prepareAsync completion, including the
# re-prepare some player engines do on pause→resume cycles of the same track).
#
# Snapshot old mCachedAudioId → flushLocked refreshes it → compare. Only resets
# position-anchor if audio_id actually changed. Real fresh-track changes are
# already handled by onFreshTrackChange via onEarlyTrackChange; this method
# exists so an OnPrepared firing for a same-track re-prepare doesn't disturb
# the existing live-position baseline.
.method public declared-synchronized onTrackEdge()V
    .locals 5

    monitor-enter p0

    :try_start_0
    # Natural-end latch (unchanged).
    iget-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPreviousTrackNaturalEnd:Z

    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPendingNaturalEnd:Z

    # Snapshot the previous cached audio_id (from prior flushLocked).
    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    # First flush — recomputes audio_id from PlayerService.getPlayingSong()
    # and stores it in mCachedAudioId. Also refreshes title/artist/album so
    # CTs that re-query metadata immediately after the metachanged broadcast
    # see the new track even if we end up taking the same-track path below.
    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    # Two independent reset triggers:
    #   1. audio_id changed (real track edge)
    #   2. previous track ended naturally (mPreviousTrackNaturalEnd, latched
    #      from mPendingNaturalEnd above) — covers the EOS-replay-same-track
    #      case where the player is re-preparing the SAME track that just
    #      naturally completed. markCompletion left
    #      mPositionAtStateChange = mLastKnownDuration (freeze at end);
    #      without a reset here T9's live-extrapolation emits
    #      live_pos = duration + (now - completion_time) on every PPC tick,
    #      which CTs render as "playhead at end of track, frozen there"
    #      even though audio is playing the freshly re-prepared track from 0.
    #      Detail in docs/INVESTIGATION.md.
    iget-boolean v4, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPreviousTrackNaturalEnd:Z

    if-nez v4, :cond_force_reset

    # Compare new audio_id (just written) with snapshot.
    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    cmp-long v4, v0, v2

    if-eqz v4, :cond_same_track

    :cond_force_reset
    # Reset position anchor and re-flush.
    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    # Stamp the fresh-track-change time so onSeek can suppress the
    # music app's playerPrepared() restore-from-saved-progress seek
    # that fires ~50-500 ms later (after prepareAsync completes).
    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastFreshTrackChangeAt:J

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    :cond_same_track
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Battery bucket update; dedupe.
.method public declared-synchronized setBattery(B)V
    .locals 1

    monitor-enter p0

    :try_start_0
    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mBatteryStatus:B

    if-ne v0, p1, :cond_changed

    monitor-exit p0

    return-void

    :cond_changed
    iput-byte p1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mBatteryStatus:B

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Public mutator: Repeat + Shuffle bytes (AVRCP §5.2.4 enum). Both at once
# because PappStateBroadcaster always sends them together.
.method public declared-synchronized setPapp(II)V
    .locals 3

    monitor-enter p0

    :try_start_0
    const/4 v0, 0x0

    int-to-byte v1, p1

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mRepeatAvrcp:B

    if-eq v1, v2, :cond_no_repeat

    iput-byte v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mRepeatAvrcp:B

    const/4 v0, 0x1

    :cond_no_repeat
    int-to-byte v1, p2

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mShuffleAvrcp:B

    if-eq v1, v2, :cond_no_shuffle

    iput-byte v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mShuffleAvrcp:B

    const/4 v0, 0x1

    :cond_no_shuffle
    if-eqz v0, :cond_done

    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V

    :cond_done
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Force a flush. Used on cold-boot init and any path that wants the file
# rewritten without a state edge.
.method public declared-synchronized flush()V
    .locals 0

    monitor-enter p0

    :try_start_0
    invoke-direct {p0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->flushLocked()V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit p0

    return-void

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Live position with playing-state extrapolation, capped at duration.
# Caller must hold monitor.
.method private computeLivePositionLocked()J
    .locals 7

    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    const/4 v1, 0x1

    if-eq v0, v1, :cond_playing

    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    return-wide v0

    :cond_playing
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    sub-long/2addr v0, v2

    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    add-long/2addr v0, v2

    invoke-static {}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->getPlayerService()Lcom/innioasis/y1/service/PlayerService;

    move-result-object v2

    if-eqz v2, :cond_done

    # Same MediaPlayer-getDuration-during-prepareAsync hazard as flushLocked:
    # gate on getPlayerIsPrepared so we don't trip the C++ player into Error
    # state when extrapolating position around a track edge. Skip the cap
    # if not prepared (live position is just elapsed-since-state-change anyway).
    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getPlayerIsPrepared()Z

    move-result v4

    if-eqz v4, :cond_done

    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getDuration()J

    move-result-wide v2

    const-wide/16 v4, 0x0

    cmp-long v6, v2, v4

    if-lez v6, :cond_done

    cmp-long v6, v0, v2

    if-lez v6, :cond_done

    move-wide v0, v2

    :cond_done
    return-wide v0
.end method


.method static getPlayerService()Lcom/innioasis/y1/service/PlayerService;
    .locals 1

    sget-object v0, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;

    invoke-virtual {v0}, Lcom/innioasis/y1/Y1Application$Companion;->getPlayerService()Lcom/innioasis/y1/service/PlayerService;

    move-result-object v0

    return-object v0
.end method


# The actual file writer. Caller must hold monitor.
# Fills a 1104-byte buffer with the current track image, then writes it to the
# inactive slot of the 2213-byte double-buffer file via RandomAccessFile +
# atomic single-byte active_slot flip. World-readable so mtkbt can mmap.
.method private flushLocked()V
    .locals 14

    :try_start_top
    iget-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mFilesDir:Ljava/io/File;

    if-nez v0, :cond_have_dir

    return-void

    :cond_have_dir
    const/16 v1, 0x450

    new-array v1, v1, [B

    # Read live state from PlayerService. v2 = svc, v3 = song, v4-v9 = strings + audioId
    invoke-static {}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->getPlayerService()Lcom/innioasis/y1/service/PlayerService;

    move-result-object v2

    const/4 v3, 0x0

    const-string v4, ""

    move-object v5, v4

    move-object v6, v4

    move-object v7, v4

    const/4 v8, 0x0

    const-wide/16 v9, 0x0

    move-wide v11, v9

    const/4 v13, 0x0

    if-eqz v2, :cond_no_svc

    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getPlayingSong()Lcom/innioasis/y1/database/Song;

    move-result-object v3

    if-nez v3, :cond_have_song

    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getPlayingMusic()Lcom/innioasis/y1/database/Song;

    move-result-object v3

    :cond_have_song
    if-eqz v3, :cond_no_song

    invoke-virtual {v3}, Lcom/innioasis/y1/database/Song;->getSongName()Ljava/lang/String;

    move-result-object v4

    invoke-static {v4}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->safeStr(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v4

    invoke-virtual {v3}, Lcom/innioasis/y1/database/Song;->getArtist()Ljava/lang/String;

    move-result-object v5

    invoke-static {v5}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->safeStr(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v5

    invoke-virtual {v3}, Lcom/innioasis/y1/database/Song;->getAlbum()Ljava/lang/String;

    move-result-object v6

    invoke-static {v6}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->safeStr(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v6

    invoke-virtual {v3}, Lcom/innioasis/y1/database/Song;->getGenre()Ljava/lang/String;

    move-result-object v7

    invoke-static {v7}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->safeStr(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v7

    invoke-virtual {v3}, Lcom/innioasis/y1/database/Song;->getPath()Ljava/lang/String;

    move-result-object v8

    invoke-static {v8}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->syntheticAudioId(Ljava/lang/String;)J

    move-result-wide v9

    :cond_no_song
    # PlayerService.getDuration() delegates to MediaPlayer.getDuration() for non-IJK
    # paths, which crashes the C++ MediaPlayer ("Attempt to call getDuration without
    # a valid mediaplayer" → INVALID_OPERATION → async OnError -38) when called
    # between setDataSource and OnPrepared. The music app calls Static.setPlayValue
    # inside its restart sequence BEFORE prepareAsync completes, so flushing here
    # without a guard would nuke the new MediaPlayer mid-prepare and leave the UI
    # stuck at 0:00. Gate on getPlayerIsPrepared (a pure iget-boolean, safe in any
    # state); when not prepared, fall back to MediaMetadataRetriever (cached per
    # audio_id) so the first T4 response for a new track carries the real duration
    # rather than 0. AVRCP 1.3 has no DURATION_CHANGED event — a CT that caches
    # dur=0 from the first T4 will keep it until the next track change.
    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getPlayerIsPrepared()Z

    move-result v0

    if-eqz v0, :cond_skip_duration

    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getDuration()J

    move-result-wide v11

    # Cache the live duration so we can fall back to it when getPlayerIsPrepared
    # goes false during a prepare gap. Without this, the duration field in
    # y1-track-info briefly resets to 0 and the CT loses its playhead display
    # ("0:00 / 0:00" or hidden entirely) until the next prepare completes.
    iput-wide v11, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    goto :cond_have_duration

    :cond_skip_duration
    # Pre-prepare path. Try MMR cache first (per-audio_id parse of file
    # container header — no MediaPlayer involvement). v8 = path string,
    # v9:v10 = synthetic audio_id long. Result lands in v11:v12 (long).
    #
    # Register-type discipline at :cond_have_duration: the "true" branch
    # above wrote v0 as int (boolean from getPlayerIsPrepared move-result)
    # and we reach the merge via goto. Dalvik 4.x's verifier joins
    # register types at the merge — if THIS branch writes v0 as long
    # (e.g., const-wide/16 v0, 0x0 for a cmp-long), the join becomes
    # int|long-low → conflict, and the class fails verification with
    # VerifyError at Y1Application.onCreate even though v0 is later
    # overwritten (Dalvik 4.x is strict about conflict-state merges).
    #
    # Use long-to-int instead to derive a sign-test int without touching
    # v0 as long. AVRCP duration is u32 in the file schema (max ~4.3 B ms
    # = ~50 days, well beyond any real track), so v11 alone (the low half
    # of the long pair) is a safe int representation for the sign check.
    invoke-direct {p0, v8, v9, v10}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->getMmrDurationLocked(Ljava/lang/String;J)J

    move-result-wide v11

    long-to-int v0, v11

    if-gtz v0, :cond_have_duration

    # MMR returned 0 (failure or unsupported codec) — last-resort fallback
    # to the legacy cached duration. mLastKnownDuration is reset to 0 by
    # setPlayStatus's inline edge detection on track changes, so this
    # typically yields 0 for fresh tracks where MMR also failed; the wire
    # result is dur=0, same as pre-MMR behaviour.
    iget-wide v11, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    :cond_have_duration
    invoke-virtual {v2}, Lcom/innioasis/y1/service/PlayerService;->getMusicIndex()I

    move-result v13

    add-int/lit8 v13, v13, 0x1

    :cond_no_svc
    # Cache the live metadata so wakeTrackChanged / wakePlayStateChanged can
    # emit AOSP-convention Intent extras without re-reading PlayerService
    # (which can return null mid-prepare).
    iput-wide v9, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    iput-object v4, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedTitle:Ljava/lang/String;

    iput-object v5, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedArtist:Ljava/lang/String;

    iput-object v6, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAlbum:Ljava/lang/String;

    # bytes 0..7 = audio_id (BE u64)
    const/4 v0, 0x0

    invoke-static {v1, v0, v9, v10}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putBE64([BIJ)V

    # Strings: title @ 8 (256), artist @ 264 (256), album @ 520 (256)
    const/16 v0, 0x8

    const/16 v2, 0x100

    invoke-static {v1, v0, v2, v4}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    const/16 v0, 0x108

    invoke-static {v1, v0, v2, v5}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    const/16 v0, 0x208

    invoke-static {v1, v0, v2, v6}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    # duration_ms BE @ 776; clamp negatives to 0
    const-wide/16 v2, 0x0

    cmp-long v0, v11, v2

    if-gtz v0, :cond_pos_dur

    move-wide v11, v2

    :cond_pos_dur
    const/16 v0, 0x308

    long-to-int v2, v11

    invoke-static {v1, v0, v2}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putBE32([BII)V

    # pos_at_state_change BE @ 780
    const/16 v0, 0x30c

    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPositionAtStateChange:J

    long-to-int v2, v2

    invoke-static {v1, v0, v2}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putBE32([BII)V

    # state_change_time BE @ 784 (low 32 bits of elapsedRealtime)
    const/16 v0, 0x310

    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mStateChangeTime:J

    long-to-int v2, v2

    invoke-static {v1, v0, v2}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putBE32([BII)V

    # bytes 788..791 pad

    # play_status @ 792
    const/16 v0, 0x318

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    aput-byte v2, v1, v0

    # natural_end @ 793
    const/16 v0, 0x319

    iget-boolean v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPreviousTrackNaturalEnd:Z

    if-eqz v2, :cond_ne_zero

    const/4 v2, 0x1

    goto :goto_ne_done

    :cond_ne_zero
    const/4 v2, 0x0

    :goto_ne_done
    int-to-byte v2, v2

    aput-byte v2, v1, v0

    # battery @ 794
    const/16 v0, 0x31a

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mBatteryStatus:B

    aput-byte v2, v1, v0

    # repeat @ 795, shuffle @ 796
    const/16 v0, 0x31b

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mRepeatAvrcp:B

    aput-byte v2, v1, v0

    const/16 v0, 0x31c

    iget-byte v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mShuffleAvrcp:B

    aput-byte v2, v1, v0

    # GetElementAttributes attrs 4-7 — pre-formatted ASCII decimal slots.
    # TrackNumber @ 800 (16), TotalNumberOfTracks @ 816 (16), PlayingTime @ 832 (16), Genre @ 848 (256)
    const/16 v0, 0x320

    const/16 v2, 0x10

    invoke-static {v13}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->intToDecOrEmpty(I)Ljava/lang/String;

    move-result-object v3

    invoke-static {v1, v0, v2, v3}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    # totalTracks: read getMusicList().size() if svc available
    invoke-static {}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->getPlayerService()Lcom/innioasis/y1/service/PlayerService;

    move-result-object v3

    const/4 v4, 0x0

    if-eqz v3, :cond_no_total

    invoke-virtual {v3}, Lcom/innioasis/y1/service/PlayerService;->getMusicList()Ljava/util/List;

    move-result-object v3

    if-eqz v3, :cond_no_total

    invoke-interface {v3}, Ljava/util/List;->size()I

    move-result v4

    :cond_no_total
    const/16 v0, 0x330

    invoke-static {v4}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->intToDecOrEmpty(I)Ljava/lang/String;

    move-result-object v3

    invoke-static {v1, v0, v2, v3}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    const/16 v0, 0x340

    invoke-static {v11, v12}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->longToDecOrEmpty(J)Ljava/lang/String;

    move-result-object v3

    invoke-static {v1, v0, v2, v3}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    const/16 v0, 0x350

    const/16 v2, 0x100

    invoke-static {v1, v0, v2, v7}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->putUtf8Padded([BIILjava/lang/String;)V

    # RandomAccessFile-based double-buffer in-place write to y1-track-info.
    # Schema: file[0]=active_slot, file[1..3]=RFA, file[4..1107]=slot[0],
    # file[1108..2211]=slot[1], file[2212]=RFA. Reader (libextavrcp_jni.so
    # trampolines via the read_track_info subroutine) reads file[0] once,
    # dispatches to slot[active], mmaps the same inode across the writer's
    # in-place updates — no tmpfile + rename which would orphan the
    # reader's mapped page.
    new-instance v0, Ljava/io/File;

    iget-object v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mFilesDir:Ljava/io/File;

    const-string v3, "y1-track-info"

    invoke-direct {v0, v2, v3}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    new-instance v3, Ljava/io/RandomAccessFile;

    const-string v2, "rw"

    invoke-direct {v3, v0, v2}, Ljava/io/RandomAccessFile;-><init>(Ljava/io/File;Ljava/lang/String;)V

    :try_start_inner
    # setLength(2213) — extends an upgrade-from-old-schema file (1104 B)
    # to the new size and zeros the new tail bytes. No-op on a properly
    # sized file (RandomAccessFile.setLength on size==N is documented
    # idempotent on Android).
    const/16 v2, 0x8a5

    int-to-long v4, v2

    invoke-virtual {v3, v4, v5}, Ljava/io/RandomAccessFile;->setLength(J)V

    # Read active_slot byte at offset 0.
    const-wide/16 v4, 0x0

    invoke-virtual {v3, v4, v5}, Ljava/io/RandomAccessFile;->seek(J)V

    invoke-virtual {v3}, Ljava/io/RandomAccessFile;->read()I

    move-result v2

    # inactive_slot = 1 - (active_slot & 1). Mask first so an EOF return
    # (-1) is treated as 0 for the flip computation — yields inactive=1
    # which writes to slot[1] and flips active to 1 on the first post-
    # upgrade flush, leaving slot[0] still holding stale-or-zero data
    # until the next flush. Subsequent flushes alternate cleanly.
    and-int/lit8 v2, v2, 0x1

    rsub-int/lit8 v6, v2, 0x1

    # inactive_byte_offset = 4 + inactive_slot * 1104.
    const/16 v7, 0x450

    mul-int/2addr v7, v6

    add-int/lit8 v7, v7, 0x4

    int-to-long v4, v7

    # Seek to inactive slot, write the 1104-byte buffer.
    invoke-virtual {v3, v4, v5}, Ljava/io/RandomAccessFile;->seek(J)V

    invoke-virtual {v3, v1}, Ljava/io/RandomAccessFile;->write([B)V

    # Atomic flip: seek to 0, write the new active_slot byte (= inactive).
    # RandomAccessFile.write(int) writes only the low 8 bits — single-byte
    # store, atomic on ARMv7 / cacheline-aligned offset 0.
    const-wide/16 v4, 0x0

    invoke-virtual {v3, v4, v5}, Ljava/io/RandomAccessFile;->seek(J)V

    invoke-virtual {v3, v6}, Ljava/io/RandomAccessFile;->write(I)V
    :try_end_inner
    .catchall {:try_start_inner .. :try_end_inner} :catchall_inner

    invoke-virtual {v3}, Ljava/io/RandomAccessFile;->close()V

    # Ensure world-readable so mtkbt (separate uid bluetooth) can mmap.
    # Idempotent; covers the case where ensureFile or some external
    # cleanup re-chmod'd the file.
    const/4 v2, 0x1

    const/4 v4, 0x0

    invoke-virtual {v0, v2, v4}, Ljava/io/File;->setReadable(ZZ)Z
    :try_end_top
    .catch Ljava/lang/Throwable; {:try_start_top .. :try_end_top} :catch_top

    return-void

    :catchall_inner
    move-exception v4

    invoke-virtual {v3}, Ljava/io/RandomAccessFile;->close()V

    throw v4

    :catch_top
    move-exception v0

    const-string v1, "Y1Patch"

    invoke-virtual {v0}, Ljava/lang/Throwable;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v1, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


# Helpers

# MediaMetadataRetriever-backed duration getter. Per-audio_id cache: only
# the first call for a given audio_id parses the file container; subsequent
# calls return the cached value in microseconds. Failures (unreadable file,
# unsupported codec, malformed metadata) latch a cached 0 for that audio_id
# so we don't retry on every flush.
#
# Caller must hold the TrackInfoWriter monitor.
.method private getMmrDurationLocked(Ljava/lang/String;J)J
    .locals 7

    # Cache check: if cached audio_id matches current, return cached duration
    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrAudioId:J

    cmp-long v6, v0, p2

    if-nez v6, :cond_cache_miss

    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    # Re-mirror into mLastKnownDuration. setPlayStatus's inline-edge reset
    # zeroes mLastKnownDuration between the two flushLocked calls; without
    # this, the second flush would write the cached MMR value via v11:v12
    # but leave mLastKnownDuration stale at 0 (visible in --debug fL.dur).
    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J

    return-wide v0

    :cond_cache_miss
    # Latch the audio_id immediately so a failed parse caches 0 and avoids
    # re-attempting on every subsequent flush during this track.
    iput-wide p2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrAudioId:J

    const-wide/16 v3, 0x0

    iput-wide v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    # Null path → return 0
    if-eqz p1, :cond_return

    # Construct the MediaMetadataRetriever OUTSIDE the try block. Dalvik
    # 4.x's verifier rejects code where a catch handler is reachable while
    # any register holds an uninitialized reference — `new-instance` produces
    # an uninit ref and `invoke-direct <init>` only marks it initialized on
    # successful return. If either of those instructions were inside the try
    # range, the catch handler entry would observe v0 as "uninit MMR", which
    # is a verify-time error (the stock `com/innioasis/music/util/Other`'s
    # `getAlbumCover` uses the same out-of-try construction pattern).
    new-instance v0, Landroid/media/MediaMetadataRetriever;

    invoke-direct {v0}, Landroid/media/MediaMetadataRetriever;-><init>()V

    :try_start_mmr
    invoke-virtual {v0, p1}, Landroid/media/MediaMetadataRetriever;->setDataSource(Ljava/lang/String;)V

    # METADATA_KEY_DURATION = 9 (android.media.MediaMetadataRetriever)
    const/16 v1, 0x9

    invoke-virtual {v0, v1}, Landroid/media/MediaMetadataRetriever;->extractMetadata(I)Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v0}, Landroid/media/MediaMetadataRetriever;->release()V

    if-eqz v2, :cond_return

    invoke-static {v2}, Ljava/lang/Long;->parseLong(Ljava/lang/String;)J

    move-result-wide v5

    # cmp result into v1 (kept int across the try), not v0 (kept MMR object
    # across the try). The verifier joins register types at catch entry over
    # every throwing instruction in the try region; writing v0 as int late
    # in the try would make catch-entry v0 a conflict (MMR vs int), which
    # Dalvik 4.x rejects even though move-exception immediately overwrites.
    cmp-long v1, v5, v3

    if-lez v1, :cond_return

    iput-wide v5, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    # Mirror into mLastKnownDuration so the legacy fallback path + the
    # --debug fL.dur log read the same coherent value.
    iput-wide v5, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastKnownDuration:J
    :try_end_mmr
    .catch Ljava/lang/Throwable; {:try_start_mmr .. :try_end_mmr} :catch_mmr

    :cond_return
    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    return-wide v0

    :catch_mmr
    move-exception v0

    iget-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mMmrDurationMs:J

    return-wide v0
.end method


.method private static safeStr(Ljava/lang/String;)Ljava/lang/String;
    .locals 1

    if-nez p0, :cond_nn

    const-string v0, ""

    return-object v0

    :cond_nn
    return-object p0
.end method


# Stable u64 from path: ((path.hashCode() & 0xFFFFFFFFL) | 0x100000000L). High
# bit distinguishes the synthetic id from MediaStore _ID values (which are u32).
.method private static syntheticAudioId(Ljava/lang/String;)J
    .locals 4

    if-nez p0, :cond_nn

    const-wide v0, 0x100000000L

    return-wide v0

    :cond_nn
    invoke-virtual {p0}, Ljava/lang/String;->hashCode()I

    move-result v0

    int-to-long v0, v0

    const-wide v2, 0xffffffffL

    and-long/2addr v0, v2

    const-wide v2, 0x100000000L

    or-long/2addr v0, v2

    return-wide v0
.end method


.method private static intToDecOrEmpty(I)Ljava/lang/String;
    .locals 1

    if-gtz p0, :cond_pos

    const-string v0, ""

    return-object v0

    :cond_pos
    invoke-static {p0}, Ljava/lang/Integer;->toString(I)Ljava/lang/String;

    move-result-object v0

    return-object v0
.end method


.method private static longToDecOrEmpty(J)Ljava/lang/String;
    .locals 3

    const-wide/16 v0, 0x0

    cmp-long v2, p0, v0

    if-gtz v2, :cond_pos

    const-string v0, ""

    return-object v0

    :cond_pos
    invoke-static {p0, p1}, Ljava/lang/Long;->toString(J)Ljava/lang/String;

    move-result-object v0

    return-object v0
.end method


.method private static putBE64([BIJ)V
    .locals 6

    const/4 v0, 0x0

    :goto_loop
    const/16 v1, 0x8

    if-ge v0, v1, :cond_done

    rsub-int/lit8 v1, v0, 0x7

    shl-int/lit8 v1, v1, 0x3

    shr-long v2, p2, v1

    long-to-int v2, v2

    and-int/lit16 v2, v2, 0xff

    int-to-byte v2, v2

    add-int v3, p1, v0

    aput-byte v2, p0, v3

    add-int/lit8 v0, v0, 0x1

    goto :goto_loop

    :cond_done
    return-void
.end method


.method private static putBE32([BII)V
    .locals 2

    shr-int/lit8 v0, p2, 0x18

    int-to-byte v0, v0

    aput-byte v0, p0, p1

    add-int/lit8 v1, p1, 0x1

    shr-int/lit8 v0, p2, 0x10

    int-to-byte v0, v0

    aput-byte v0, p0, v1

    add-int/lit8 v1, p1, 0x2

    shr-int/lit8 v0, p2, 0x8

    int-to-byte v0, v0

    aput-byte v0, p0, v1

    add-int/lit8 v1, p1, 0x3

    int-to-byte v0, p2

    aput-byte v0, p0, v1

    return-void
.end method


# UTF-8 codepoint-safe truncation; cap = min(slot-1, 240). Trailing NUL implicit
# (caller passes a zero-initialised buffer).
.method private static putUtf8Padded([BIILjava/lang/String;)V
    .locals 7

    if-nez p3, :cond_have

    return-void

    :cond_have
    :try_start_0
    const-string v0, "UTF-8"

    invoke-virtual {p3, v0}, Ljava/lang/String;->getBytes(Ljava/lang/String;)[B

    move-result-object v0
    :try_end_0
    .catch Ljava/io/UnsupportedEncodingException; {:try_start_0 .. :try_end_0} :catch_0

    add-int/lit8 v1, p2, -0x1

    const/16 v2, 0xf0

    if-le v1, v2, :cond_cap_ok

    move v1, v2

    :cond_cap_ok
    array-length v2, v0

    if-ge v2, v1, :cond_use_cap

    move v3, v2

    goto :goto_have_n

    :cond_use_cap
    move v3, v1

    :goto_have_n
    # codepoint-safe truncation: walk back if v3 lands on a 0x80..0xBF continuation byte
    :goto_walk
    if-lez v3, :cond_walk_done

    if-ge v3, v2, :cond_walk_done

    aget-byte v4, v0, v3

    and-int/lit16 v5, v4, 0xc0

    const/16 v6, 0x80

    if-ne v5, v6, :cond_walk_done

    add-int/lit8 v3, v3, -0x1

    goto :goto_walk

    :cond_walk_done
    const/4 v4, 0x0

    invoke-static {v0, v4, p0, p1, v3}, Ljava/lang/System;->arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V

    return-void

    :catch_0
    move-exception v0

    return-void
.end method


# Wake the trampoline chain's track-changed dispatch by firing
# com.android.music.metachanged. MtkBt.odex's cardinality-NOP-patched
# BTAvrcpMusicAdapter.handleKeyMessage sswitch_1a3 wakes
# notificationTrackChangedNative on this broadcast, which jumps to T5 →
# AVRCP §5.4.2 Tbl 5.30 TRACK_CHANGED CHANGED (+ §5.4.2 Tbl 5.31/5.32 if
# the natural-end / start-of-track edges are armed).
#
# Call site: PlaybackStateBridge.onPrepared, after onTrackEdge has flushed
# the new track's y1-track-info to disk.
.method public wakeTrackChanged()V
    .locals 5

    :try_start_0
    iget-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mContext:Landroid/content/Context;

    if-eqz v0, :cond_no_ctx

    new-instance v1, Landroid/content/Intent;

    const-string v2, "com.android.music.metachanged"

    invoke-direct {v1, v2}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V

    # AOSP-convention Intent extras: id (long), track (String), artist (String),
    # album (String). MMI_AVRCP's onReceive reads these directly into its Java
    # mirror; without them MtkBt logs `track-info id:-1` and gates downstream
    # notification dispatch on stale defaults.
    const-string v2, "id"

    iget-wide v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    invoke-virtual {v1, v2, v3, v4}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v2, "track"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedTitle:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "artist"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedArtist:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "album"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAlbum:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    invoke-virtual {v0, v1}, Landroid/content/Context;->sendBroadcast(Landroid/content/Intent;)V

    :cond_no_ctx
    return-void
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :catch_0
    move-exception v0

    const-string v1, "Y1Patch"

    invoke-virtual {v0}, Ljava/lang/Throwable;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


# Wake the trampoline chain's play-status / battery / position / papp
# dispatch by firing com.android.music.playstatechanged. MtkBt.odex's
# cardinality-NOP-patched BTAvrcpMusicAdapter.handleKeyMessage sswitch_18a
# wakes notificationPlayStatusChangedNative on this broadcast, which jumps
# to T9 → AVRCP §5.4.2 CHANGED for the four events T9 handles (PLAYBACK_STATUS
# 0x01, PLAYBACK_POS 0x05, BATT_STATUS 0x06, PLAYER_APPLICATION_SETTING 0x08;
# each gated on its own file vs state edge inside T9).
#
# Call sites: PlaybackStateBridge.onPlayValue (state-edge wake), and
# PlaybackStateBridge.onPrepared (new-track wake — position resets to 0).
.method public wakePlayStateChanged()V
    .locals 7

    :try_start_0
    # Rate-limit gate. Suppress broadcast when mPlayStatus is unchanged AND
    # the previous broadcast fired <800ms ago. AVRCP 1.3 §5.4.2 Tbl 5.33
    # nominal 1Hz position cadence is the floor; real play-state edges
    # (mPlayStatus differs from mLastWakePlayStatus) always bypass the
    # gate. File state (y1-track-info) was already flushed by the caller's
    # setPlayStatus / flush / onTrackEdge / markCompletion path, so T6
    # GetPlayStatus polling remains current even when the broadcast
    # itself is suppressed.
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v5

    iget-wide v2, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastWakePlayStateAt:J

    sub-long v0, v5, v2

    const-wide/16 v2, 0x320

    cmp-long v4, v0, v2

    if-gez v4, :rate_limit_proceed

    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    iget-byte v1, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastWakePlayStatus:B

    if-ne v0, v1, :rate_limit_proceed

    return-void

    :rate_limit_proceed
    iput-wide v5, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastWakePlayStateAt:J

    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    iput-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastWakePlayStatus:B

    iget-object v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mContext:Landroid/content/Context;

    if-eqz v0, :cond_no_ctx

    new-instance v1, Landroid/content/Intent;

    const-string v2, "com.android.music.playstatechanged"

    invoke-direct {v1, v2}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V

    # AOSP-convention Intent extras: id (long), track / artist / album
    # (String), and playing (boolean). MMI_AVRCP's onReceive logs
    # `update-info playing:<bool>` + `track-info isPlaying:<bool> id:<long>`
    # from these extras directly — without them MtkBt's Java mirror stays
    # at the (false, -1) defaults regardless of actual playback state.
    const-string v2, "id"

    iget-wide v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAudioId:J

    invoke-virtual {v1, v2, v3, v4}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v2, "track"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedTitle:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "artist"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedArtist:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "album"

    iget-object v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mCachedAlbum:Ljava/lang/String;

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "playing"

    iget-byte v3, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    const/4 v4, 0x1

    if-eq v3, v4, :cond_playing

    const/4 v4, 0x0

    :cond_playing
    invoke-virtual {v1, v2, v4}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Z)Landroid/content/Intent;

    invoke-virtual {v0, v1}, Landroid/content/Context;->sendBroadcast(Landroid/content/Intent;)V

    :cond_no_ctx
    return-void
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :catch_0
    move-exception v0

    const-string v1, "Y1Patch"

    invoke-virtual {v0}, Ljava/lang/Throwable;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


# Force-emit a PlaybackStatusChanged edge pair (PAUSED → PLAYING) on the
# AVRCP wire. Called at track-edge settle from PlaybackStateBridge.
# onPlayerPreparedTail. The actual two-phase work is delegated to
# PscPulse.fire() which handles the 50 ms inter-phase delay needed for
# mtkbt's broadcast dispatch + JNI invocation to durably consume phase
# 1's file write before phase 2 overwrites it. This method just owns the
# "only pulse while PLAYING" gate.
#
# Empirically (Bolt 2221 capture, 2026-05-19), at least one head-unit CT
# gates its metadata-pane refresh on PlaybackStatus CHANGED edges, NOT on
# TrackChanged CHANGED. Natural track ends keep mPlayStatus at PLAYING
# throughout, so T9 sees no PSC edge and never fires a CHANGED — the CT
# sits on stale metadata until its polling cycle (~40 s) catches up or
# the user presses a hardware key (which generates a PSC edge via the
# music app's setPlayValue cascade). Pixel-as-TG (observed in
# btsnoop_hci 2026-05-18) emits PSC=Paused CHANGED mid-transition then
# PSC=Playing INTERIM via the CT's re-register burst, giving the same
# CT two PSC edges per track edge. See PscPulse.fire() docstring + Trace
# #75 / #76 in docs/INVESTIGATION.md.
#
# Only fires when currently PLAYING — track edges that land while paused
# or stopped get their PSC refresh from the actual play-state edge that
# follows.
.method public declared-synchronized pulsePlayStatusForCT()V
    .locals 2

    monitor-enter p0

    :try_start_0
    iget-byte v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mPlayStatus:B

    const/4 v1, 0x1

    if-ne v0, v1, :pulse_skip

    invoke-static {}, Lcom/koensayr/y1/playback/PscPulse;->fire()V

    :pulse_skip
    monitor-exit p0

    return-void
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    :catchall_0
    move-exception v0

    monitor-exit p0

    throw v0
.end method


# Reset wake rate-limit so the NEXT wakePlayStateChanged() call always
# fires its broadcast, regardless of how recently the previous wake
# fired or whether mPlayStatus changed.
#
# The rate-limit gate inside wakePlayStateChanged was designed to
# coalesce the 3-wake cascade around track edges (onPlayValue +
# onPrepared + onPlayerPreparedTail in tight succession, <200 ms apart,
# same mPlayStatus). PositionTicker's 1 Hz heartbeat shouldn't be
# subject to that gate — but if the previous wake landed <800 ms ago
# with the same mPlayStatus (e.g., PSC pulse phase 2 settled to PLAYING,
# then PositionTicker tick lands 600 ms later), the gate suppresses
# the broadcast and T9 never runs → no PLAYBACK_POS_CHANGED on the
# wire → CT's playhead freezes after the initial track-change tick.
#
# Empirical: Kia 0707 (2026-05-20) had 86 PositionTicker.run firings
# but only 47 Kia ev=05 RegNotif acks (strict §6.7.1 = one re-register
# per PPC CHANGED received). ~39 ticks were dropped by the rate-limit.
# User reported "track length updates but track position does not
# after the initial tick" — the exact symptom predicted by the gate
# eating PositionTicker.
#
# PositionTicker.run calls this method before each wakePlayStateChanged,
# which makes the gate's `now - mLastWakePlayStateAt` calculation see
# a huge delta (current uptime minus 0) → bypass → broadcast fires.
.method public resetWakeRateLimit()V
    .locals 2

    const-wide/16 v0, 0x0

    iput-wide v0, p0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->mLastWakePlayStateAt:J

    return-void
.end method
