.class public final Lcom/koensayr/y1/playback/PscPulse;
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;
.source "PscPulse.smali"


# Two-phase PSC (PlaybackStatusChanged) pulse on the AVRCP wire to drive
# CT-side metadata refresh on head units that gate refresh on PSC edges
# rather than TrackChanged edges (see docs/INVESTIGATION.md for the
# empirical evidence).
#
# Phase 1 (immediate, on the caller thread):
#     setPlayStatus(PAUSED) → file[792]=2 + flushLocked
#     wakePlayStateChanged() → fires com.android.music.playstatechanged →
#         mtkbt's BluetoothAvrcpReceiver → notificationPlayStatusChangedNative
#         → T9 (libextavrcp_jni.so trampoline) → emits PSC=PAUSED CHANGED on
#         the wire.
#
# Phase 2 (Handler.postDelayed 50 ms):
#     setPlayStatus(PLAYING) → file[792]=1 + flushLocked
#     wakePlayStateChanged() → T9 emits PSC=PLAYING CHANGED + POSITION CHANGED.
#
# The 50 ms gap matters: T9 reads y1-track-info from disk at run time, NOT
# at broadcast-queued time. Without the gap, phase 2's setPlayStatus(1)
# overwrites file[792]=2 before mtkbt schedules T9 for phase 1's broadcast.
# T9 then reads file[792]=1 for BOTH broadcasts, sees no edge against
# state[9]=1, and emits zero PSC CHANGEDs. The race was observed in Bolt
# 2221 — 06:23:54 track edge had a 7 ms phase1→phase2 gap and produced
# zero T9ps emits; the 06:23:50 edge had a 5 ms gap that worked only
# because mtkbt was less loaded and T9 happened to fire between the two
# setPlayStatus calls. 50 ms is enough headroom for mtkbt's broadcast
# dispatch + JNI invocation + T9 syscall chain to complete phase 1
# durably before phase 2's file write.
#
# Phase 2 runs on the main thread (Looper.getMainLooper()) — same thread
# as PositionTicker. Idempotent on re-fire (Handler.removeCallbacks on
# the singleton Runnable before each postDelayed).


# static fields
.field private static final INSTANCE:Lcom/koensayr/y1/playback/PscPulse;

.field private static sHandler:Landroid/os/Handler;


# direct methods
.method static constructor <clinit>()V
    .locals 1

    new-instance v0, Lcom/koensayr/y1/playback/PscPulse;

    invoke-direct {v0}, Lcom/koensayr/y1/playback/PscPulse;-><init>()V

    sput-object v0, Lcom/koensayr/y1/playback/PscPulse;->INSTANCE:Lcom/koensayr/y1/playback/PscPulse;

    return-void
.end method


.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# Phase 1: setPlayStatus(PAUSED) + wakePlayStateChanged, then schedule
# phase 2 (Handler.postDelayed 50 ms on main looper). Caller should
# already have checked that the current play status is PLAYING — phase 2
# unconditionally writes PLAYING, so calling fire() while paused or
# stopped would leave the file in the wrong state. TrackInfoWriter.
# pulsePlayStatusForCT() owns that gate.
.method public static fire()V
    .locals 4

    :try_start_0
    sget-object v0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->INSTANCE:Lcom/koensayr/y1/trackinfo/TrackInfoWriter;

    const/4 v1, 0x2

    invoke-virtual {v0, v1}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->setPlayStatus(B)V

    invoke-virtual {v0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->wakePlayStateChanged()V

    sget-object v0, Lcom/koensayr/y1/playback/PscPulse;->sHandler:Landroid/os/Handler;

    if-nez v0, :cond_have_handler

    new-instance v0, Landroid/os/Handler;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v1

    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    sput-object v0, Lcom/koensayr/y1/playback/PscPulse;->sHandler:Landroid/os/Handler;

    :cond_have_handler
    sget-object v1, Lcom/koensayr/y1/playback/PscPulse;->INSTANCE:Lcom/koensayr/y1/playback/PscPulse;

    invoke-virtual {v0, v1}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    const-wide/16 v2, 0x32

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

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


# Phase 2: setPlayStatus(PLAYING) + wakePlayStateChanged. Runs on the
# main thread 50 ms after fire(). T9's edge detection sees file[792]=1
# vs state[9]=2 (T9 updated state[9] after phase 1's emit) → emits
# PSC=PLAYING CHANGED.
.method public run()V
    .locals 3

    :try_start_0
    sget-object v0, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->INSTANCE:Lcom/koensayr/y1/trackinfo/TrackInfoWriter;

    const/4 v1, 0x1

    invoke-virtual {v0, v1}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->setPlayStatus(B)V

    invoke-virtual {v0}, Lcom/koensayr/y1/trackinfo/TrackInfoWriter;->wakePlayStateChanged()V

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
