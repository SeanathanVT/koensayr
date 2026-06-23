#!/usr/bin/env python3
"""
patch_autoshutdown_persistence.py — Fix autoshutdown timer persistence across reboots

The autoshutdown timer currently uses CountDownTimer which is destroyed on reboot.
This patch:
1. Saves the target shutdown timestamp (not just duration) to MMKV
2. Restores the timer in Y1Application.onCreate() on boot
3. Clears expired timers

Usage:
	From the y1-decoded directory:
	python3 ../../src/patches/patch_autoshutdown_persistence.py .
"""

import os
import sys

def main():
	if len(sys.argv) != 2:
		print("Usage: python3 patch_autoshutdown_persistence.py <y1-decoded-dir>")
		sys.exit(1)

	decoded_dir = os.path.abspath(sys.argv[1])

	print("=== Autoshutdown Timer Persistence Patch ===\n")
	print(f"Working directory: {decoded_dir}\n")

	# Check if the decoded directory exists
	if not os.path.exists(decoded_dir):
		print(f"ERROR: Directory {decoded_dir} does not exist")
		print("\nMake sure you've decompiled the APK first with:")
		print("  java -jar tools/apktool-2.9.3.jar d Y1.apk -o y1-decoded")
		sys.exit(1)

	# File paths
	setting_activity = os.path.join(decoded_dir, "smali/com/innioasis/y1/activity/SettingActivity.smali")
	y1_application = os.path.join(decoded_dir, "smali/com/innioasis/y1/Y1Application.smali")
	timer_callback = os.path.join(decoded_dir, "smali/com/innioasis/y1/Y1Application$restoredTimer$1.smali")

	# Check if it looks like a decompiled APK directory
	smali_dir = os.path.join(decoded_dir, "smali")
	if not os.path.exists(smali_dir):
		print(f"ERROR: {smali_dir} not found")
		print(f"\nThe directory {decoded_dir} doesn't look like a decompiled APK.")
		print("Expected to find a 'smali/' subdirectory.")
		sys.exit(1)

	# Check files exist
	if not os.path.exists(setting_activity):
		print(f"ERROR: {setting_activity} not found")
		print(f"\nSearching for SettingActivity.smali...")
		# Try to find it
		for root, dirs, files in os.walk(decoded_dir):
			if "SettingActivity.smali" in files:
				print(f"Found at: {os.path.join(root, 'SettingActivity.smali')}")
		sys.exit(1)

	if not os.path.exists(y1_application):
		print(f"ERROR: {y1_application} not found")
		print(f"\nSearching for Y1Application.smali...")
		for root, dirs, files in os.walk(decoded_dir):
			if "Y1Application.smali" in files:
				print(f"Found at: {os.path.join(root, 'Y1Application.smali')}")
		sys.exit(1)

	print("Step 1: Patching SettingActivity.smali to save target timestamp...")
	patch_setting_activity(setting_activity)

	print("Step 2: Creating timer restoration callback...")
	create_timer_callback(timer_callback)

	print("Step 3: Patching Y1Application.smali to restore timer on boot...")
	patch_y1_application(y1_application)

	print("\n✓ Patch complete!")
	print("\nNext steps:")
	print("1. Rebuild the APK with apktool")
	print("2. Install and test on device")
	print("3. Set a timer, reboot, and verify it resumes")


def patch_setting_activity(filepath):
	"""Patch SettingActivity to save/clear target timestamp"""

	with open(filepath, 'r') as f:
		content = f.read()

	# Patch 1: Save target timestamp after starting timer (line ~4094)
	OLD_SAVE_DURATION = """    invoke-virtual {v0, p1}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	return-void
.end method"""

	NEW_SAVE_WITH_TIMESTAMP = """    invoke-virtual {v0, p1}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	# PATCH: Save target shutdown timestamp for restoration on boot
	invoke-static {}, Ljava/lang/System;->currentTimeMillis()J

	move-result-wide v0

	int-to-long v2, p1

	const-wide/32 v4, 0xea60

	mul-long v2, v2, v4

	add-long v0, v0, v2

	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;

	move-result-object v2

	const-string v3, "shutdownTargetTime"

	invoke-virtual {v2, v3, v0, v1}, Lcom/tencent/mmkv/MMKV;->encode(Ljava/lang/String;J)Z

	return-void
.end method"""

	# Patch 2: Clear timestamp when timer is cancelled (line ~4036)
	OLD_CLEAR_TIMER = """    const/4 v0, 0x0

	invoke-virtual {p1, v0}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	return-void"""

	NEW_CLEAR_WITH_TIMESTAMP = """    const/4 v0, 0x0

	invoke-virtual {p1, v0}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	# PATCH: Also clear the target timestamp
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;

	move-result-object p1

	const-string v0, "shutdownTargetTime"

	invoke-virtual {p1, v0}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V

	return-void"""

	if OLD_SAVE_DURATION not in content:
		print("  WARNING: Could not find save duration pattern - may already be patched")
	else:
		content = content.replace(OLD_SAVE_DURATION, NEW_SAVE_WITH_TIMESTAMP)
		print("  ✓ Added timestamp save on timer start")

	if OLD_CLEAR_TIMER not in content:
		print("  WARNING: Could not find clear timer pattern - may already be patched")
	else:
		content = content.replace(OLD_CLEAR_TIMER, NEW_CLEAR_WITH_TIMESTAMP)
		print("  ✓ Added timestamp clear on timer cancel")

	with open(filepath, 'w') as f:
		f.write(content)


def create_timer_callback(filepath):
	"""Create the timer callback class for restored timers"""

	callback_code = """.class public final Lcom/innioasis/y1/Y1Application$restoredTimer$1;
.super Landroid/os/CountDownTimer;
.source "Y1Application.kt"


# annotations
.annotation system Ldalvik/annotation/EnclosingMethod;
	value = Lcom/innioasis/y1/Y1Application;->restoreShutdownTimer(I)V
.end annotation

.annotation system Ldalvik/annotation/InnerClass;
	accessFlags = 0x19
	name = null
.end annotation


# direct methods
.method constructor <init>(J)V
	.locals 2

	const-wide/16 v0, 0x7d0

	.line 1
	invoke-direct {p0, p1, p2, v0, v1}, Landroid/os/CountDownTimer;-><init>(JJ)V

	return-void
.end method


# virtual methods
.method public onFinish()V
	.locals 3

	.line 2
	sget-object v0, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;

	const/4 v1, 0x0

	invoke-virtual {v0, v1}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	.line 3
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;

	move-result-object v0

	const-string v1, "shutdownTargetTime"

	invoke-virtual {v0, v1}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V

	.line 4
	sget-object v0, Lcom/innioasis/music/util/Other;->INSTANCE:Lcom/innioasis/music/util/Other;

	invoke-virtual {v0}, Lcom/innioasis/music/util/Other;->shutdown()V

	return-void
.end method

.method public onTick(J)V
	.locals 2

	.line 5
	sget-object v0, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;

	invoke-virtual {v0, p1, p2}, Lcom/innioasis/y1/Y1Application$Companion;->setMillisUntilFinished(J)V

	const-wide/16 v0, 0x3a98

	cmp-long v0, p1, v0

	if-gez v0, :cond_0

	.line 6
	sget-object p1, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;

	invoke-virtual {p1}, Lcom/innioasis/y1/Y1Application$Companion;->getAppContext()Landroid/content/Context;

	move-result-object p1

	if-eqz p1, :cond_0

	.line 7
	new-instance p2, Landroid/content/Intent;

	const-string v0, "com.innioasis.y1.ABOUT_SHUT_DOWN"

	invoke-direct {p2, v0}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V

	invoke-virtual {p1, p2}, Landroid/content/Context;->sendBroadcast(Landroid/content/Intent;)V

	:cond_0
	return-void
.end method
"""

	with open(filepath, 'w') as f:
		f.write(callback_code)

	print(f"  ✓ Created {filepath}")


def patch_y1_application(filepath):
	"""Patch Y1Application.onCreate() to restore timer on boot"""

	with open(filepath, 'r') as f:
		content = f.read()

	# Find the end of onCreate method
	# We'll add our code right before the final return-void
	# Look for the pattern that indicates end of onCreate

	# First, add the helper method at the end of the class (before final .end method)
	HELPER_METHOD = """
# === PATCH: Helper method to restore shutdown timer ===
.method public static restoreShutdownTimer(I)V
	.locals 8

	int-to-long v0, p0

	const-wide/32 v2, 0xea60

	mul-long v0, v0, v2

	.line 1000
	sget-object v2, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;

	new-instance v3, Lcom/innioasis/y1/Y1Application$restoredTimer$1;

	invoke-direct {v3, v0, v1}, Lcom/innioasis/y1/Y1Application$restoredTimer$1;-><init>(J)V

	check-cast v3, Landroid/os/CountDownTimer;

	invoke-virtual {v2, v3}, Lcom/innioasis/y1/Y1Application$Companion;->setTimer(Landroid/os/CountDownTimer;)V

	.line 1001
	sget-object v0, Lcom/innioasis/y1/Y1Application;->Companion:Lcom/innioasis/y1/Y1Application$Companion;

	invoke-virtual {v0}, Lcom/innioasis/y1/Y1Application$Companion;->getTimer()Landroid/os/CountDownTimer;

	move-result-object v0

	if-eqz v0, :cond_0

	invoke-virtual {v0}, Landroid/os/CountDownTimer;->start()Landroid/os/CountDownTimer;

	:cond_0
	.line 1002
	sget-object v0, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;

	invoke-virtual {v0, p0}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	return-void
.end method

"""

	# Insert helper method before the final .end method of the class
	# Find the last occurrence of ".end method" followed by nothing but whitespace
	import re
	# Insert before the very last line (which should be the class .end method)
	lines = content.split('\n')

	# Find where to insert (before the last line which is typically blank or contains final comments)
	insert_pos = len(lines) - 1
	while insert_pos > 0 and (not lines[insert_pos].strip() or lines[insert_pos].strip().startswith('#')):
		insert_pos -= 1

	lines.insert(insert_pos, HELPER_METHOD)
	content = '\n'.join(lines)

	print("  ✓ Added restoreShutdownTimer() helper method")

	# Now patch onCreate() to call the restoration logic
	# Find onCreate method and add restoration code before its return-void
	# This is tricky - we need to find the onCreate method and add code at the end

	# Look for a pattern near the end of onCreate - typically after all initialization
	# We'll add after the SharedPreferencesUtils initialization since that's one of the last things

	ONCREATE_INSERTION_POINT = """    invoke-virtual {v5, v4}, Lcom/innioasis/y1/utils/SharedPreferencesUtils;->init(Landroid/content/Context;)V"""

	TIMER_RESTORE_CODE = """    invoke-virtual {v5, v4}, Lcom/innioasis/y1/utils/SharedPreferencesUtils;->init(Landroid/content/Context;)V

	# === PATCH: Restore autoshutdown timer on boot ===
	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;

	move-result-object v4

	const-string v5, "shutdownTargetTime"

	const-wide/16 v6, 0x0

	invoke-virtual {v4, v5, v6, v7}, Lcom/tencent/mmkv/MMKV;->decodeLong(Ljava/lang/String;J)J

	move-result-wide v4

	cmp-long v8, v4, v6

	if-eqz v8, :skip_timer_restore

	invoke-static {}, Ljava/lang/System;->currentTimeMillis()J

	move-result-wide v6

	sub-long v4, v4, v6

	const-wide/16 v6, 0x0

	cmp-long v6, v4, v6

	if-lez v6, :timer_expired

	const-wide/32 v6, 0xea60

	div-long v4, v4, v6

	long-to-int v4, v4

	invoke-static {v4}, Lcom/innioasis/y1/Y1Application;->restoreShutdownTimer(I)V

	goto :skip_timer_restore

	:timer_expired
	sget-object v4, Lcom/innioasis/music/objects/Global;->INSTANCE:Lcom/innioasis/music/objects/Global;

	const/4 v5, 0x0

	invoke-virtual {v4, v5}, Lcom/innioasis/music/objects/Global;->setShutdownTime(I)V

	invoke-static {}, Lcom/tencent/mmkv/MMKV;->defaultMMKV()Lcom/tencent/mmkv/MMKV;

	move-result-object v4

	const-string v5, "shutdownTargetTime"

	invoke-virtual {v4, v5}, Lcom/tencent/mmkv/MMKV;->remove(Ljava/lang/String;)V

	:skip_timer_restore
	# === END PATCH ==="""

	if ONCREATE_INSERTION_POINT in content:
		content = content.replace(ONCREATE_INSERTION_POINT, TIMER_RESTORE_CODE)
		print("  ✓ Added timer restoration logic to onCreate()")
	else:
		print("  WARNING: Could not find onCreate insertion point")
		print("  You may need to manually add the restoration logic")

	with open(filepath, 'w') as f:
		f.write(content)


if __name__ == '__main__':
	main()
