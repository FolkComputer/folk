#!/usr/bin/env python3
"""Records a PulseAudio source into a 16-bit WAV and notes when its first sample was captured.

    capture.py OUT.wav [--device folk_sim.monitor] [--rate 48000] [--channels 2] [--latency-msec 10]

Runs `parec --raw` against $PULSE_SERVER and writes OUT.wav plus OUT.wav.json:
  {"t0_epoch": wall-clock time of sample 0, "rate", "channels", "frames", ...}
The sidecar appears as soon as the first samples arrive (sink.sh waits for it), so sound made
after `sink.sh record` returns is in the file. SIGINT / SIGTERM: stop parec, drain, fix the
WAV header, exit 0. A file whose writer was killed -9 still loads in analyze.py.
"""

import argparse
import json
import os
import signal
import struct
import subprocess
import sys
import time


def header(data_bytes, rate, channels):
    align = channels * 2
    return (b"RIFF" + struct.pack("<I", (36 + data_bytes) & 0xFFFFFFFF) + b"WAVEfmt " +
            struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * align, align, 16) +
            b"data" + struct.pack("<I", data_bytes & 0xFFFFFFFF))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--device", default="folk_sim.monitor")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--channels", type=int, default=2)
    ap.add_argument("--latency-msec", type=int, default=10)
    args = ap.parse_args()

    frame = 2 * args.channels
    sidecar = args.out + ".json"
    for p in (sidecar,):
        try:
            os.unlink(p)
        except OSError:
            pass
    parec = subprocess.Popen(
        ["parec", "--raw", "--format=s16le", "--rate=%d" % args.rate, "--channels=%d" % args.channels,
         "--device=" + args.device, "--latency-msec=%d" % args.latency_msec,
         "--client-name=folk-sim-capture"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, bufsize=0)
    stopped = []

    def stop(signum, _frame):
        stopped.append(signum)
        try:
            parec.send_signal(signal.SIGINT)      # parec flushes what it has and exits
        except OSError:
            pass
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    info = {"device": args.device, "rate": args.rate, "channels": args.channels,
            "latency_msec": args.latency_msec, "t0_epoch": None, "frames": 0, "complete": False}

    def write_sidecar():
        tmp = sidecar + ".tmp"
        with open(tmp, "w") as f:
            json.dump(info, f)
        os.replace(tmp, sidecar)

    total = 0
    fd = parec.stdout.fileno()
    with open(args.out, "wb") as out:
        out.write(header(0, args.rate, args.channels))
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            if info["t0_epoch"] is None:
                # The first fragment has just been filled: its first sample is that much older.
                info["t0_epoch"] = time.time() - (len(chunk) // frame) / args.rate
                info["first_chunk_frames"] = len(chunk) // frame
                write_sidecar()
            out.write(chunk)
            out.flush()
            total += len(chunk)
        total -= total % frame
        out.seek(0)
        out.write(header(total, args.rate, args.channels))
        out.truncate(44 + total)
    code = parec.wait()
    info["frames"] = total // frame
    info["complete"] = True
    info["stopped_by_signal"] = bool(stopped)
    info["parec_exit"] = code
    write_sidecar()
    return 0 if stopped else 1          # parec ending on its own means the server went away


if __name__ == "__main__":
    sys.exit(main())
