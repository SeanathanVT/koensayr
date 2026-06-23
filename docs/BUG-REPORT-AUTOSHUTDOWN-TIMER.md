# Innioasis Y1 MP3 Player - Autoshutdown Timer Bug Report

## Executive Summary

The Innioasis Y1's autoshutdown timer feature has a critical bug: **the timer does not persist across device reboots**. When a user sets a shutdown timer (e.g., 30 minutes) and reboots the device before the timer expires, the active countdown is lost, even though the user's selected duration setting is correctly saved to persistent storage.

---

## Problem Description

### Current Behavior

1. User sets autoshutdown timer to 30 minutes
2. Timer starts counting down correctly
3. User reboots device (or device crashes/restarts)
4. **After reboot:** Timer is gone, device will not shut down
5. User's timer setting (30 minutes) is still shown in settings UI, but no active countdown exists

### Expected Behavior

1. User sets autoshutdown timer to 30 minutes
2. Timer starts counting down correctly
3. User reboots device after 10 minutes
4. **After reboot:** Timer resumes with ~20 minutes remaining
5. Device shuts down when the original target time is reached

### Impact

- Users cannot rely on the autoshutdown feature if the device reboots
- Battery drain continues if user expected device to shut down
- Poor user experience for a core feature

---

## Root Cause Analysis

### The Bug

The autoshutdown feature uses two separate persistence mechanisms that are not synchronized:

1. **Setting Storage (WORKS):** The selected timer duration is saved to MMKV persistent storage
2. **Timer State (BROKEN):** The active countdown timer is stored only in RAM and is lost on reboot

### Code Analysis

#### Location: `SettingActivity.smali`

**Method:** `startShutdown(I)V` (starts the countdown timer)

**What it does correctly:**
- Saves the selected duration to persistent storage via `Global.setShutdownTime(I)`

**What it does wrong:**
- Creates a `CountDownTimer` object and stores it in `Y1Application.Companion` (in-memory only)
- Does **NOT** save a target shutdown timestamp that could be used to restore the timer after reboot

**Relevant code (decompiled smali):**
```smali
.method private final startShutdown(I)V
	# ... timer setup code ...

	# Creates in-memory timer - LOST ON REBOOT
	new-instance v0, Lcom/innioasis/y1/activity/SettingActivity$startShutdown$1;
	invoke-direct {v0, v2, v3, p0}, Lcom/innioasis/y1/activity/SettingActivity$startShutdown$1;-><init>(JLcom/innioasis/y1/activity/SettingActivity;)V

	# Stores timer in memory only
	invoke-virtual {v4, v0}, Lcom/innioasis/y1/Y1Application$Companion;->setTimer(Landroid/os/CountDownTimer;)V

	# Starts the timer
	invoke-virtual {v0}, Landroid/os/CountDownTimer;->start()Landroid/os/CountDownTimer;

	# Saves duration to persistent storage - THIS WORKS
	sget-object v0, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;
	invoke-virtual {v0, p1}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	return-void
.end method
```

#### Location: `Global.smali`

**Methods:** `setShutdownTime(I)V` and `getShutdownTime()I`

**What they do:**
- Use MMKV (Tencent's key-value storage library) to persist the timer duration
- This works correctly - the setting survives reboot

**Code:**
```smali
.method public final getShutdownTime()I
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
	move-result-object v0
	const-string v1, "shutdownTime"
	const/4 v2, 0x0
	invoke-virtual {v0, v1, v2}, Lcom/tencent/mmkv/MMKV;->decodeInt(Ljava/lang/String;I)I
	move-result v0
	return v0
.end method

.method public final setShutdownTime(I)V
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
	move-result-object v0
	const-string v1, "shutdownTime"
	invoke-virtual {v0, v1, p1}, Lcom/tencent/mmkv/MMKV;->encode(Ljava/lang/String;I)Z
	return-void
.end method
```

**Note:** MMKV automatically persists - no `apply()` or `commit()` needed.

#### Location: `Y1Application.smali`

**Method:** `onCreate()V` (app initialization on boot)

**What it does wrong:**
- Initializes SharedPreferences, crash reporting, repositories, etc.
- **Does NOT check for a saved timer and restore it**
- The `shutdownTime` value persists, but no code reads it on boot to restart the countdown

**Missing logic:**
```
On boot:
  1. Check if shutdownTime > 0
  2. Check if there's a saved target timestamp
  3. Calculate remaining time
  4. If remaining > 0, restart the countdown timer
  5. If expired, clear the setting
```

---

## Technical Details

### MMKV Storage (Current Implementation)

| Key | Type | Purpose | Persists? |
|-----|------|---------|-----------|
| `shutdownTime` | `int` | Selected duration in minutes | ✅ YES |
| *(missing)* | `long` | Target shutdown timestamp | ❌ NO |

### CountDownTimer Lifecycle

The `CountDownTimer` class used for the autoshutdown feature is **not persistent**:
- It's a standard Android framework class
- Lives only in the app's process memory
- Destroyed when app process is killed or device reboots
- Cannot be serialized or saved to storage

### Files Involved

| File | Path | Purpose |
|------|------|---------|
| `SettingActivity.smali` | `smali/com/innioasis/y1/activity/` | Timer start/stop/cancel logic |
| `SettingActivity$startShutdown$1.smali` | `smali_classes2/com/innioasis/y1/activity/` | Timer callback (onTick/onFinish) |
| `Global.smali` | `smali_classes2/com/innioasis/music/objects/` | Persistent storage access |
| `Y1Application.smali` | `smali/com/innioasis/y1/` | App initialization (onCreate) |

---

## Proposed Fix

### Solution Overview

Instead of saving only the **duration**, also save the **target shutdown timestamp**. On boot, calculate the remaining time and recreate the timer.

### Required Changes

#### 1. SettingActivity.smali - Save Target Timestamp

**When timer starts** (in `startShutdown(I)V`), add after `setShutdownTime(I)`:

```smali
# Calculate target time = now + duration
invoke-static {}, Ljava/lang/System;->currentTimeMillis()J
move-result-wide v0

int-to-long v2, p1              # p1 = minutes
const-wide/32 v4, 0xea60        # 60000 ms per minute
mul-long v2, v2, v4
add-long v0, v0, v2             # v0 = target timestamp

# Save to MMKV
invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
move-result-object v2
const-string v3, "shutdownTargetTime"
invoke-virtual {v2, v3, v0, v1}, Lcom/tencent/mmkv/MMKV;->encode(Ljava/lang/String;J)Z
```

**When timer is cancelled** (in the cancel handler), add after clearing `shutdownTime`:

```smali
# Clear the target timestamp
invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
move-result-object v0
const-string v1, "shutdownTargetTime"
invoke-virtual {v0, v1}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V
```

#### 2. Y1Application.smali - Restore Timer on Boot

**In `onCreate()V`**, add before the `setLanguage()` call:

```smali
# Check for saved timer
invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
move-result-object v4
const-string v5, "shutdownTargetTime"
const-wide/16 v6, 0x0
invoke-virtual {v4, v5, v6, v7}, Lcom/tencent/mmkv/MMKV;->decodeLong(Ljava/lang/String;J)J
move-result-wide v4

cmp-long v8, v4, v6
if-eqz v8, :skip_timer_restore

# Calculate remaining time
invoke-static {}, Ljava/lang/System;->currentTimeMillis()J
move-result-wide v6
sub-long v4, v4, v6             # remaining = target - now

const-wide/16 v6, 0x0
cmp-long v6, v4, v6
if-lez v6, :timer_expired

# Remaining time > 0: restart timer
const-wide/32 v6, 0xea60
div-long v4, v4, v6             # convert ms to minutes
long-to-int v4, v4
invoke-static {v4}, Lcom/innioasis/y1/Y1Application;->restoreShutdownTimer(I)V
goto :skip_timer_restore

:timer_expired
# Timer already expired: clear settings
sget-object v4, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;
const/4 v5, 0x0
invoke-virtual {v4, v5}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V
invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
move-result-object v4
const-string v5, "shutdownTargetTime"
invoke-virtual {v4, v5}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V

:skip_timer_restore
```

**Add new helper method** `restoreShutdownTimer(I)V` to Y1Application:

```smali
.method public static restoreShutdownTimer(I)V
	.locals 8

	# Convert minutes to milliseconds
	int-to-long v0, p0
	const-wide/32 v2, 0xea60
	mul-long v0, v0, v2

	# Create new timer
	sget-object v2, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;
	new-instance v3, Lcom/innioasis/y1/Y1Application$restoredTimer$1;
	invoke-direct {v3, v0, v1}, Lcom/innioasis/y1/Y1Application$restoredTimer$1;-><init>(J)V
	check-cast v3, Landroid/os/CountDownTimer;
	invoke-virtual {v2, v3}, Lcom/innioasis/y1/Y1Application$Companion;->setTimer(Landroid/os/CountDownTimer;)V

	# Start timer
	sget-object v0, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;
	invoke-virtual {v0}, Lcom/innioasis/y1/Y1Application$Companion;->getTimer()Landroid/os/CountDownTimer;
	move-result-object v0
	if-eqz v0, :cond_0
	invoke-virtual {v0}, Landroid/os/CountDownTimer;->start()Landroid/os/CountDownTimer;

	:cond_0
	# Update stored duration
	sget-object v0, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;
	invoke-virtual {v0, p0}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	return-void
.end method
```

#### 3. Create Timer Callback Class

**New file:** `Y1Application$restoredTimer$1.smali`

This mirrors the existing `SettingActivity$startShutdown$1` callback:

```smali
.class public final Lcom/innioasis/y1/Y1Application$restoredTimer$1;
.super Landroid/os/CountDownTimer;

.method constructor <init>(J)V
	.locals 2
	const-wide/16 v0, 0x7d0    # 2000ms tick interval
	invoke-direct {p0, p1, p2, v0, v1}, Landroid/os/CountDownTimer;-><init>(JJ)V
	return-void
.end method

.method public onFinish()V
	# Clear settings
	sget-object v0, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;
	const/4 v1, 0x0
	invoke-virtual {v0, v1}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	# Clear timestamp
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;
	move-result-object v0
	const-string v1, "shutdownTargetTime"
	invoke-virtual {v0, v1}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V

	# Shutdown device
	sget-object v0, Lcom/innioasis/music/util/Other;->INSTANCE:Lcom/innioasis/music/util/Other;
	invoke-virtual {v0}, Lcom/innioasis/music/util/Other;->shutdown()V

	return-void
.end method

.method public onTick(J)V
	# Update remaining time in app
	sget-object v0, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;
	invoke-virtual {v0, p1, p2}, Lcom/innioasis/y1/Y1Application$Companion;->setMillisUntilFinished(J)V

	# Send broadcast 15 seconds before shutdown
	const-wide/16 v0, 0x3a98    # 15000ms
	cmp-long v0, p1, v0
	if-gez v0, :cond_0
	sget-object p1, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;
	invoke-virtual {p1}, Lcom/innioasis/y1/Y1Application$Companion;->getAppContext()Landroid/content/Context;
	move-result-object p1
	if-eqz p1, :cond_0
	new-instance p2, Landroid/content/Intent;
	const-string v0, "com.innioasis.y1.ABOUT_SHUT_DOWN"
	invoke-direct {p2, v0}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V
	invoke-virtual {p1, p2}, Landroid/content/Context;->sendBroadcast(Landroid/content/Intent;)V

	:cond_0
	return-void
.end method
```

---

## Testing Plan

### Test Case 1: Normal Shutdown
1. Set timer to 5 minutes
2. Wait for timer to expire
3. **Expected:** Device shuts down, timestamp is cleared

### Test Case 2: Reboot Before Timer Expires
1. Set timer to 30 minutes
2. Wait 10 minutes
3. Reboot device
4. **Expected:** Timer resumes with ~20 minutes remaining
5. Device shuts down after total 30 minutes from original start

### Test Case 3: Reboot After Timer Expired
1. Set timer to 5 minutes
2. Wait 10 minutes (without reboot)
3. Reboot device
4. **Expected:** Timer setting cleared, no shutdown scheduled

### Test Case 4: Cancel Timer
1. Set timer to 30 minutes
2. Cancel timer via settings
3. Reboot device
4. **Expected:** No timer active after reboot

### Test Case 5: USB Charging Override
1. Set timer to 5 minutes
2. Plug in USB charger
3. Wait for timer to expire
4. **Expected:** Device does NOT shut down (existing behavior preserved)

---

## Additional Notes

### Why This Bug Exists

- The original implementation likely assumed the device would not reboot during normal use
- CountDownTimer is convenient for UI updates but not designed for persistence
- The separation between UI (SettingActivity) and app lifecycle (Y1Application) created a gap

### Dependencies

- **MMKV:** Tencent's key-value storage library (already in use, works correctly)
- **CountDownTimer:** Android framework class (limitations understood)
- **System.currentTimeMillis():** Standard Java/Android time API

### Backward Compatibility

The fix is backward compatible:
- New MMKV key (`shutdownTargetTime`) won't affect existing users
- If key is missing, no timer restoration is attempted
- Existing shutdown behavior unchanged for non-reboot scenarios

### Alternative Solutions Considered

1. **Use AlarmManager:** More robust but requires significant refactoring
2. **Save only duration and restart from scratch:** Loses partial countdown progress
3. **Disable timer on reboot:** Poor user experience
4. **Current solution:** Minimal code change, preserves all existing behavior

---

## Contact Information

This bug report was generated based on reverse-engineering the decompiled APK (`com.innioasis.y1_3.0.7.apk`). 

For questions or clarification:
- The patched version implementing this fix is available
- All code references are from decompiled smali (use apktool to inspect)

---

## Appendix: Quick Reference

### MMKV Keys

| Key | Type | Value |
|-----|------|-------|
| `shutdownTime` | int | Duration in minutes (existing) |
| `shutdownTargetTime` | long | Unix timestamp when shutdown should occur (NEW) |

### Method Signatures

```
SettingActivity.startShutdown(I)V           - Start timer with N minutes
SettingActivity$startShutdown$1.onFinish()  - Timer expired callback
Global.getShutdownTime()I                   - Read saved duration
Global.setShutdownTime(I)V                  - Save duration
Y1Application.onCreate()V                   - App initialization
Y1Application.restoreShutdownTimer(I)V      - Recreate timer (NEW)
```

### Build Instructions

To apply this fix to the APK:
1. Decompile with apktool: `apktool d com.innioasis.y1_3.0.7.apk`
2. Apply the smali changes listed above
3. Rebuild: `apktool b com.innioasis.y1_3.0.7 -o patched.apk`
4. Sign: `jarsigner -keystore key.jks patched.apk alias`
5. Install: `adb install patched.apk`

---

**Document Version:** 1.0  
**Date:** June 23, 2026  
**APK Version:** com.innioasis.y1_3.0.7  
**Status:** Bug Identified, Fix Designed, Patch Available
