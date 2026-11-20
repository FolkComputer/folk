#!/bin/bash
# A capturable sound card for headless tests: a private PulseAudio daemon whose only sink is
# a null sink ("folk_sim"). Everything lives in <rundir>; nothing in ~/.config/pulse is used.
#
#   sink.sh start  <rundir>            start the daemon (no-op if it already runs); prints the
#                                      environment a child needs, as KEY=VALUE lines
#   sink.sh env    <rundir>            print those lines again
#   sink.sh record <rundir> <out.wav>  start capturing what is played (in the background);
#                                      prints the recorder's PID once samples are flowing
#   sink.sh stop-record <rundir>       stop the recorder (finishes the WAV); the daemon stays
#   sink.sh stop   <rundir>            stop the recorder and the daemon; safe to call twice
#   sink.sh status <rundir>            exit 0 if the daemon answers; lists streams
#
# Typical use:
#   export $(test/sim/audio/sink.sh start /tmp/aud)     # PULSE_SERVER=... PULSE_COOKIE=...
#   test/sim/audio/sink.sh record /tmp/aud /tmp/aud/out.wav
#   ./folk ... ; chromium ... ; paplay x.wav            # anything that speaks PulseAudio
#   test/sim/audio/sink.sh stop /tmp/aud
#   python3 test/sim/audio/analyze.py /tmp/aud/out.wav --tone 440:0.9
#
# Environment: FOLK_SIM_SINK_RATE (default 48000), FOLK_SIM_SINK_IDLE_EXIT (seconds without
# any client after which the daemon exits by itself; default -1 = never).
set -u

here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}
rundir=${2:-}
rate=${FOLK_SIM_SINK_RATE:-48000}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "sink.sh: $*" >&2; exit 1; }

[ -n "$cmd" ] && [ -n "$rundir" ] || usage
case $cmd in start|env|record|stop-record|stop|status) ;; *) usage ;; esac

if [ ! -d "$rundir" ]; then
    case $cmd in
        start) mkdir -p "$rundir" || die "cannot create $rundir" ;;
        stop|stop-record) exit 0 ;;
        *) die "$rundir does not exist (run: sink.sh start $rundir)" ;;
    esac
fi
rundir=$(cd "$rundir" && pwd -P)

# AF_UNIX paths are limited to 107 bytes: a deep rundir gets its socket in a short temp dir.
sockdir() {
    if [ -s "$rundir/sockdir" ]; then cat "$rundir/sockdir"; else echo "$rundir"; fi
}
socket() { echo "$(sockdir)/pulse.sock"; }

print_env() {
    echo "PULSE_SERVER=unix:$(socket)"
    echo "PULSE_COOKIE=$rundir/cookie"
}

# pid_alive <pidfile> <word that must be in the command line>
pid_alive() {
    local pid
    pid=$(cat "$1" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "$2"
}

# stop_pid <pidfile> <word> <signal> <seconds before SIGKILL>
stop_pid() {
    local pid i
    if pid_alive "$1" "$2"; then
        pid=$(cat "$1")
        kill "-$3" "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $(($4 * 20)) ]; do sleep 0.05; i=$((i + 1)); done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
            sleep 0.1
        fi
    fi
    rm -f "$1"
}

pactl_() { PULSE_SERVER="unix:$(socket)" PULSE_COOKIE="$rundir/cookie" pactl "$@"; }
daemon_up() { pid_alive "$rundir/pulse.pid" pulseaudio && pactl_ info >/dev/null 2>&1; }

do_start() {
    command -v pulseaudio >/dev/null || die "pulseaudio is not installed"
    command -v pactl >/dev/null || die "pactl (pulseaudio-utils) is not installed"
    chmod 700 "$rundir"
    if daemon_up; then print_env; return 0; fi
    do_stop                                      # leftovers of a daemon that died

    local sd=$rundir
    if [ $((${#rundir} + 11)) -gt 100 ]; then
        sd=$(mktemp -d "${TMPDIR:-/tmp}/folk-sim-audio.XXXXXX") || die "mktemp failed"
        echo "$sd" > "$rundir/sockdir"
    fi
    mkdir -p "$rundir/state" "$rundir/home"
    # Chromium and miniaudio open their streams at the server's default rate: make it the
    # sink's rate so nothing is resampled. No realtime scheduling (it needs rtkit / D-Bus).
    cat > "$rundir/daemon.conf" <<EOF
default-sample-format = s16le
default-sample-rate = $rate
alternate-sample-rate = $rate
default-sample-channels = 2
realtime-scheduling = no
flat-volumes = no
EOF
    cat > "$rundir/default.pa" <<EOF
load-module module-native-protocol-unix socket=$sd/pulse.sock auth-anonymous=1
load-module module-null-sink sink_name=folk_sim rate=$rate channels=2 format=s16le sink_properties=device.description=folk_sim
set-default-sink folk_sim
set-default-source folk_sim.monitor
EOF
    # Runs fine as root without --system (it only warns). setsid: no controlling terminal,
    # own process group, so a ^C in the test runner does not take the daemon down mid-run.
    env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u PULSE_SERVER \
        HOME="$rundir/home" XDG_RUNTIME_DIR="$rundir" \
        PULSE_RUNTIME_PATH="$rundir/pulse" PULSE_STATE_PATH="$rundir/state" \
        PULSE_CONFIG_PATH="$rundir" PULSE_CONFIG="$rundir/daemon.conf" PULSE_COOKIE="$rundir/cookie" \
        setsid pulseaudio -n --daemonize=no --use-pid-file=no --disallow-exit \
            --exit-idle-time="${FOLK_SIM_SINK_IDLE_EXIT:--1}" \
            --log-target="file:$rundir/pulse.log" -F "$rundir/default.pa" \
            </dev/null >"$rundir/pulse.out" 2>&1 &
    echo $! > "$rundir/pulse.pid"
    local i=0
    until daemon_up; do
        i=$((i + 1))
        if [ "$i" -gt 200 ] || ! kill -0 "$(cat "$rundir/pulse.pid")" 2>/dev/null; then
            cat "$rundir/pulse.out" "$rundir/pulse.log" >&2 2>/dev/null
            do_stop
            die "pulseaudio did not come up (log above)"
        fi
        sleep 0.05
    done
    pactl_ list short sinks | grep -q folk_sim || { do_stop; die "the null sink is missing"; }
    print_env
}

do_stop_record() { stop_pid "$rundir/record.pid" capture.py INT 5; }

do_stop() {
    do_stop_record
    stop_pid "$rundir/pulse.pid" pulseaudio TERM 3
    if [ -s "$rundir/sockdir" ]; then
        rm -rf "$(cat "$rundir/sockdir")"
        rm -f "$rundir/sockdir"
    fi
    rm -f "$rundir/pulse.sock"
}

do_record() {
    local out=${1:-}
    [ -n "$out" ] || usage
    daemon_up || die "no daemon in $rundir (run: sink.sh start $rundir)"
    pid_alive "$rundir/record.pid" capture.py && die "already recording (pid $(cat "$rundir/record.pid")): run stop-record first"
    rm -f "$out" "$out.json"
    PULSE_SERVER="unix:$(socket)" PULSE_COOKIE="$rundir/cookie" \
        setsid python3 "$here/capture.py" "$out" --device folk_sim.monitor --rate "$rate" \
        </dev/null >"$rundir/record.log" 2>&1 &
    echo $! > "$rundir/record.pid"
    local i=0
    until [ -s "$out.json" ]; do                 # written when the first samples arrive
        i=$((i + 1))
        if [ "$i" -gt 200 ] || ! kill -0 "$(cat "$rundir/record.pid")" 2>/dev/null; then
            cat "$rundir/record.log" >&2
            do_stop_record
            die "the recorder did not start"
        fi
        sleep 0.05
    done
    cat "$rundir/record.pid"
}

case $cmd in
    start) do_start ;;
    env) print_env ;;
    record) do_record "${3:-}" ;;
    stop-record) do_stop_record ;;
    stop) do_stop ;;
    status)
        daemon_up || { echo "not running"; exit 1; }
        echo "running pid=$(cat "$rundir/pulse.pid") socket=$(socket)"
        echo "sink inputs:"; pactl_ list short sink-inputs
        echo "source outputs:"; pactl_ list short source-outputs
        ;;
esac
