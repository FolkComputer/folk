#!/bin/bash
# End-to-end check of the audio sink:
#   1. analyze.py --selftest (synthetic signals)
#   2. sink.sh start + record; paplay a 1000 Hz reference (is the sink itself alive?)
#   3. headless Chromium on tone-page.html: a CDP mouse click on each button
#      (WebAudio 440 Hz 1.0 s + 880 Hz 0.5 s, then an <audio> element at 660 Hz 1.0 s)
#   4. sink.sh stop; analyze.py asserts the tones, their order and the silences
#   5. with --folk: a second recording of builtin-programs/audio.folk (miniaudio) playing
#      a 523.25 Hz WAV through `Wish to play audio` (needs the built ./folk; ~20 s more)
#
#   selftest.sh [--browser shell|chrome|/path/to/chromium] [--folk] [--keep]
#
# Exit 0 = everything asserted, 1 = something failed. Uses its own temp dir and its own
# PulseAudio daemon; both are gone when it returns (--keep leaves the temp dir).
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
browser=()
folk=0
keep=0
while [ $# -gt 0 ]; do
    case $1 in
        --browser) browser=(--browser "$2"); shift ;;
        --folk) folk=1 ;;
        --keep) keep=1 ;;
        *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    esac
    shift
done

work=$(mktemp -d "${TMPDIR:-/tmp}/folk-audio-selftest.XXXXXX") || exit 1
status=1
cleanup() {
    "$here/sink.sh" stop "$work"
    if [ -f "$work/pulse.pid.seen" ] && kill -0 "$(cat "$work/pulse.pid.seen")" 2>/dev/null; then
        echo "selftest: FAIL: the PulseAudio daemon is still running" >&2
        status=1
    fi
    if [ "$keep" = 1 ]; then echo "selftest: kept $work"; else rm -rf "$work"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() { echo "selftest: FAIL: $*" >&2; exit 1; }

echo "selftest: 1/5 analyze.py --selftest"
python3 "$here/analyze.py" --selftest > "$work/analyze-selftest.log" 2>&1 \
    || { grep -v '^ok ' "$work/analyze-selftest.log" >&2; fail "analyze.py --selftest"; }
tail -n 1 "$work/analyze-selftest.log"

echo "selftest: 2/5 sink"
env_lines=$("$here/sink.sh" start "$work") || fail "sink.sh start"
cp "$work/pulse.pid" "$work/pulse.pid.seen"
# shellcheck disable=SC2086
export $env_lines
"$here/sink.sh" start "$work" > /dev/null || fail "sink.sh start is not idempotent"
[ "$(cat "$work/pulse.pid")" = "$(cat "$work/pulse.pid.seen")" ] || fail "second start replaced the daemon"
"$here/sink.sh" record "$work" "$work/browser.wav" > /dev/null || fail "sink.sh record"
python3 - "$here" "$work" <<'EOF' || fail "could not write the reference tones"
import sys
sys.path.insert(0, sys.argv[1])
import numpy as np, analyze
analyze.write_wav(sys.argv[2] + "/ref1000.wav", np.repeat(analyze.sine(1000, 0.3), 2), 48000, channels=2)
analyze.write_wav(sys.argv[2] + "/tone523.wav", np.repeat(analyze.sine(523.25, 1.0, 44100), 2), 44100, channels=2)
EOF
sleep 0.2
timeout 20 paplay "$work/ref1000.wav" || fail "paplay could not play into the sink"
sleep 0.3

echo "selftest: 3/5 Chromium on tone-page.html"
timeout 90 node "$here/drive-page.js" "${browser[@]}" > "$work/drive.json" 2> "$work/drive.err" \
    || { cat "$work/drive.err" >&2; fail "drive-page.js"; }
sleep 0.3
"$here/sink.sh" stop-record "$work" || fail "sink.sh stop-record"

if [ "$folk" = 1 ]; then
    echo "selftest: 5/5 Folk audio.folk (miniaudio)"
    [ -x "$repo/folk" ] || fail "$repo/folk is not built"
    "$here/sink.sh" record "$work" "$work/folk.wav" > /dev/null || fail "sink.sh record (folk)"
    mkdir -p "$work/folk-home"
    (cd "$repo" && HOME="$work/folk-home" FOLK_PID_FILE="$work/folk.pid" TERM=dumb \
        FOLK_SIM_AUDIO_WAV="$work/tone523.wav" FOLK_SIM_AUDIO_SECONDS=1.5 \
        timeout 120 ./folk test/sim/audio/play-audio.folk) > "$work/folk.log" 2>&1 \
        || { tail -n 20 "$work/folk.log" >&2; fail "./folk test/sim/audio/play-audio.folk"; }
    grep '^play-audio:' "$work/folk.log"
    "$here/sink.sh" stop-record "$work" || fail "sink.sh stop-record (folk)"
fi
"$here/sink.sh" stop "$work" || fail "sink.sh stop"
"$here/sink.sh" stop "$work" || fail "second sink.sh stop"

echo "selftest: 4/5 analysis"
python3 - "$here" "$work" "$folk" <<'EOF' || fail "analysis"
import json, sys
sys.path.insert(0, sys.argv[1])
import analyze
work, folk = sys.argv[2], sys.argv[3] == "1"
wav = analyze.load(work + "/browser.wav")
print(wav.describe())
drive = json.load(open(work + "/drive.json"))
log, steps = drive["log"], drive["steps"]
first = lambda name: next((e for e in log if e["event"] == name), None)

# max_gap: on a busy machine Chromium now and then drops 10-20 ms of a tone
ref = wav.assert_tone(1000, 0.25)
a = wav.assert_tone(440, 0.95, max_gap=0.05)
b = wav.assert_tone(880, 0.45, max_gap=0.05)
c = wav.assert_tone(660, 0.95, max_gap=0.05)
assert ref[1] < a[0] < b[0] < c[0], "tones out of order: %r" % ([ref, a, b, c],)
assert abs(b[0] - a[1]) < 0.03, "880 Hz does not follow 440 Hz directly: %r %r" % (a, b)
assert abs((a[1] - a[0]) - 1.0) < 0.05 and abs((b[1] - b[0]) - 0.5) < 0.05 and abs((c[1] - c[0]) - 1.0) < 0.05, \
    "wrong tone durations: %r" % ([a, b, c],)
wav.assert_silence(0, ref[0] - 0.03)
wav.assert_silence(ref[1] + 0.03, a[0] - 0.03)
wav.assert_silence(b[1] + 0.03, c[0] - 0.03)
wav.assert_silence(c[1] + 0.03, None)
sounds = wav.sounds(min_silence=0.1)
assert len(sounds) == 3, "expected 3 stretches of sound, got %r" % (sounds,)
for f in (523.25, 1319, 220):
    wav.assert_no_tone(f)

assert first("tones-start") and first("audio-play-resolved"), "the page did not start playing: %r" % (log,)
assert "isTrusted=true" in first("tones-request")["why"], "the click was not a trusted event"
loaded = first("loaded")
print("page: AudioContext was %r at load (no gesture), %r after the click; sample rate %d" % (
    loaded["state"], steps[-1]["ctxState"], loaded["sampleRate"]))
clicks = {s["id"]: s["t"] / 1000.0 for s in steps if s["step"] == "click"}
for name, iv in (("play", a), ("play-audio", c)):
    ms = (wav.epoch(iv[0]) - clicks[name]) * 1000.0
    print("latency: click on #%s -> sound in the capture: %.0f ms" % (name, ms))
    assert -20 < ms < 1000, "implausible click-to-sound latency %.0f ms" % ms
if folk:
    fw = analyze.load(work + "/folk.wav")
    print(fw.describe())
    t = fw.assert_tone(523.25, 0.95, max_gap=0.05)
    assert abs((t[1] - t[0]) - 1.0) < 0.05, "wrong duration %r" % (t,)
    assert len(fw.sounds(min_silence=0.1)) == 1
    wished = [l for l in open(work + "/folk.log") if "wishing to play" in l]
    ms = (fw.epoch(t[0]) - int(wished[0].split(" at ")[1].split()[0]) / 1000.0) * 1000.0
    print("latency: Wish to play audio -> sound in the capture: %.0f ms" % ms)
print("analysis: all assertions hold")
EOF
status=0
echo "selftest: PASS"
