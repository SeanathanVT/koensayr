#!/usr/bin/env python3
"""
avrcp-wire-trace.py — pretty-print the trampoline-side `Y1T :` debug logs
emitted by `apply.bash --debug` builds.

The trampolines in `src/patches/_trampolines.py` (DEBUG_NATIVE_LOG branch)
call `__android_log_print(INFO, "Y1T", fmt, value)` at five marker sites.
With KOENSAYR_DEBUG=1 in the build, those lines surface in
`adb logcat -s Y1T:*`:

  inbound CMD dispatcher markers (libextavrcp_jni.so):
    Y1T : T1pdu=20             T4 dispatcher saw non-RegNotif PDU 0x20 (GetEA)
    Y1T : T2reg ev=02          extended_T2 saw inbound RegisterNotification ev=2

  outbound emit markers (libextavrcp_jni.so T9):
    Y1T : T9ps                 PLAYBACK_STATUS_CHANGED CHANGED about to ship
    Y1T : T9papp               PlayerApplicationSetting CHANGED about to ship
    Y1T : T9pos=00002b3a       PlaybackPositionChanged CHANGED, pos_ms=0x2b3a

  wire-level markers (mtkbt M5 cave):
    Y1T : M5wire c39=02        chan+0x39 at wire emit (AVCTP TID nibble source)
    Y1T : M5dbg p8=b8          packet[+8]   (0xb8 outbound, 0xea inbound)
    Y1T : M5dbg pd=02          packet[+0xd] (M5's strb source on inbound)

This script:
  - Prepends each line with the logcat timestamp so the markers can be
    correlated against the music-app-side `Y1Patch :` traces and the
    mtkbt-side btlog entries on the same time axis.
  - Optionally filters by tag prefix.

Usage:
    adb logcat -s Y1T:* > bolt.log
    ./avrcp-wire-trace.py bolt.log
    ./avrcp-wire-trace.py bolt.log --tag T2reg          # only RegNotif markers
    ./avrcp-wire-trace.py bolt.log --tag M5             # all M5* lines (wire-side)
    ./avrcp-wire-trace.py bolt.log --tag T9pos          # only position emits

Pair with `tools/btlog-parse.py --avrcp` on the simultaneously-captured
`btlog.bin` for the matching mtkbt-internal view.
"""

import argparse
import re
import sys


LINE_RE = re.compile(r"Y1T\s*:\s*(?P<text>\S.*)$")
TS_RE = re.compile(r"^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)")


def parse_lines(path):
    """Yield (timestamp_str, text) for each Y1T log line."""
    with open(path) as f:
        for line in f:
            m = LINE_RE.search(line)
            if not m:
                continue
            ts_match = TS_RE.match(line)
            ts = ts_match.group(1) if ts_match else ""
            yield ts, m.group("text").rstrip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile", help="adb logcat output (text)")
    ap.add_argument("--tag",
                    help="filter by tag prefix (e.g. T2reg, T9pos, M5wire, M5dbg)")
    args = ap.parse_args()

    n = 0
    for ts, text in parse_lines(args.logfile):
        if args.tag and not text.startswith(args.tag):
            continue
        print(f"[{ts}] {text}")
        n += 1

    print(f"\n# {n} Y1T line(s) printed", file=sys.stderr)


if __name__ == "__main__":
    main()
