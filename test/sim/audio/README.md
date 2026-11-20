# test/sim/audio: a sound card that tests can listen to

Headless test machines have no `/dev/snd`. `sink.sh` starts a private PulseAudio daemon
whose only device is a null sink (`folk_sim`); everything played into it can be recorded
from `folk_sim.monitor` and checked with `analyze.py`. Both Folk's own `audio.folk`
(miniaudio) and a Chromium started by Folk find it through one environment variable.

| File | What |
|---|---|
| `sink.sh` | `start <rundir>` / `env` / `record <rundir> <out.wav>` / `stop-record` / `stop` / `status` |
| `capture.py` | the recorder behind `sink.sh record` (parec -> WAV + `<out.wav>.json` with the wall-clock time of sample 0) |
| `analyze.py` | numpy-only analyser: segments, `find_tone`, `assert_tone`, `assert_silence`, onsets; `--selftest` |
| `tone-page.html` | test page: `#play` = WebAudio 440 Hz 1.0 s then 880 Hz 0.5 s; `#play-audio` = `<audio>` 660 Hz 1.0 s; `window.__audioLog` |
| `drive-page.js` | Playwright launcher that clicks the buttons with raw CDP mouse events and prints the page log |
| `play-audio.folk` | Folk-level program: `Wish to play audio $FOLK_SIM_AUDIO_WAV` through `builtin-programs/audio.folk` |
| `selftest.sh` | all of the above end to end; exit 0/1 |

## Recipe

```sh
export $(test/sim/audio/sink.sh start /tmp/aud)      # prints PULSE_SERVER=unix:... and PULSE_COOKIE=...
test/sim/audio/sink.sh record /tmp/aud /tmp/aud/out.wav   # returns once samples are flowing
HOME=... FOLK_HEADLESS=1280x720 ./folk               # Folk and every child inherit PULSE_SERVER
test/sim/audio/sink.sh stop /tmp/aud                 # stops recorder + daemon; safe to repeat
python3 test/sim/audio/analyze.py /tmp/aud/out.wav --tone 440:0.9 --silence 0:0.2
```

- Start the sink **before** Folk: `audio.folk` picks its backend once, at boot.
- `PULSE_SERVER` is all a client needs. `PULSE_COOKIE` only keeps libpulse from creating
  `~/.config/pulse/cookie`. Nothing else in the home directory or `XDG_RUNTIME_DIR` is used.
- The daemon runs with `-n` (no system config), 48 kHz s16 stereo, as root or as a normal user.
  A rundir path too long for a unix socket (107 bytes) gets its socket in a `mktemp` dir, which
  `stop` removes. `FOLK_SIM_SINK_IDLE_EXIT=<s>` makes a forgotten daemon exit by itself.
- Python: `w = analyze.load(path); w.assert_tone(440, 0.9, max_gap=0.05); w.epoch(t)`.
  Use `max_gap` in tests that run on a loaded machine (see Limitations).
- Playwright adds `--mute-audio` to headless launches: pass `ignoreDefaultArgs: ["--mute-audio"]`.
  Its `page.evaluate()` runs with `userGesture: true`, which unlocks audio by itself; use CDP
  `Runtime.evaluate` when a test is about the autoplay policy.

## What was measured (Chrome for Testing 157, PulseAudio 16.1, 4 CPUs, no sound hardware)

- `chrome-headless-shell` and full `chrome --headless` both open PulseAudio streams
  (`pactl list sink-inputs` shows them while playing) and both tone sequences arrive in the
  capture with the right frequency and length. Xvfb is not needed.
- Default autoplay policy: the AudioContext is `suspended` and `audio.play()` rejects with
  `NotAllowedError` without a gesture; `element.click()` from script does not help; a CDP
  `Input.dispatchMouseEvent` press/release is a trusted click and unlocks both.
- Click to first captured sample, 15 clicks: WebAudio 28-44 ms (median 34), `<audio>` 60-81 ms
  (median 70). The capture timestamp itself is good to about one 10 ms fragment.
- `Wish to play audio` in Folk: miniaudio picks its PulseAudio backend (it tries PulseAudio
  before ALSA), sound about 30 ms after the wish. A Chromium child spawned by a Folk program
  in a full boot plays into the same sink.
- With no sink at all Chromium falls back to a silent dummy output and reports nothing: the
  context is `running`, `currentTime` advances in real time, `play()` resolves, `ended` fires.
  Only a capture proves that sound was produced.
- The daemon costs 0 % CPU idle and about 2 % of one core while playing and recording.

Rejected: pure ALSA (`ALSA_CONFIG_PATH` with a `type file` PCM over the `null` slave,
Chromium with `--alsa-output-device=default`). The null slave has no clock: `aplay` finished
a 1.0 s file in 7 ms, Chromium's `currentTime` reached 183 s within one second of wall time,
and the file was garbage. It also cannot mix two processes. `--system` mode was not needed.

## A real Folk box (not verified here: this machine has no sound hardware)

Chromium uses PulseAudio if it can reach a server, otherwise the ALSA PCM `default`
(`--alsa-output-device=<pcm>` in `FOLK_BROWSER_FLAGS` to change it), otherwise silence
without an error. For a box with bare ALSA and Folk as a systemd service:

1. The service user must be in group `audio` (no login session grants `/dev/snd` access).
2. `default` must be the output that is wired to the speakers (an HDMI output is often not
   card 0 device 0): `/etc/asound.conf`, check with `sudo -u folk aplay -D default some.wav`.
3. `default` must allow several openers. `audio.folk` keeps its stream open for as long as
   Folk runs (seen here as a permanent sink input), so on a plain `hw` PCM Chromium would get
   `EBUSY` and go silent. Use `dmix`:
   ```
   pcm.!default { type plug slave.pcm "folkmix" }
   pcm.folkmix  { type dmix ipc_key 4273 slave { pcm "hw:CARD=<card>,DEV=<dev>" rate 48000 channels 2 } }
   ```
   or run a PulseAudio daemon like `sink.sh` does, with `module-alsa-sink device=hw:...`
   in place of the null sink and `Environment=PULSE_SERVER=unix:<socket>` in `folk.service`
   (the client side is then exactly what is tested here).
4. Boxes that run `music.folk` (JACK on the HDMI device; `audio.folk` then uses JACK only):
   Chromium has no JACK backend, it needs the ALSA `jack` PCM or PulseAudio's JACK sink.
5. Pages need a click before they may play. For kiosk pages add
   `--autoplay-policy=no-user-gesture-required` to `FOLK_BROWSER_FLAGS`.

## Limitations

- On a busy machine Chromium occasionally drops 10-20 ms of a tone (seen with 6 busy loops on
  4 CPUs); `assert_tone(..., max_gap=0.05)` bridges that. Strict asserts can flake under load.
- `segments()` boundaries are quantised to the window (50 ms) and a chord of equally strong
  notes splits into several segments; use `find_tone()` (about 10 ms) and `onsets()` (about 1 ms).
- `analyze.py` mixes the capture down to mono; left/right placement is not checked.
- One recorder per rundir. A daemon restarted while Chromium or Folk runs was not tested.
- `selftest.sh` needs Node with Playwright and a Chromium under `/opt/pw-browsers` (or
  `--browser <path>` / `FOLK_BROWSER`), `pulseaudio`, `pulseaudio-utils`, `python3-numpy`.
