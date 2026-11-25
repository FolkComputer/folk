# Video decoder

`builtin-programs/video.folk` plays a video file on a program, like an
image. It splits **decoding** (`VideoSource`, one `ffmpeg` per file)
from **playing** (`VideoPlayer`, one per program showing it), with a
memory-capped ring of decoded frames in between.

## Why not `exec` in a `When`?

The simplest version of this runs `ffmpeg` with `exec` (or `open |`) in
a `When` and reads frames in that `When`, so the process dies when the
`When` unmatches. That works for playing a file once, forwards. This
decoder is bigger because:

- **Reading frames from Tcl keeps a Folk worker busy** for as long as a
  video plays, one per video. Here a C thread reads `ffmpeg`'s pipes,
  and another publishes each frame with `HoldStatementGlobally`, so
  playing keeps no worker busy (`test/video.folk` checks this).
- **Several programs can share one decode.** A program that plays with
  `source $video` reads from the same ring as `$video`, with no extra
  `ffmpeg`.

The process is still tied to statements: the player's `Claim ... with
player $id` has a `-destructor` that closes the player, and closing the
last player on a source kills `ffmpeg` (`SIGKILL`, then `waitpid`),
after the 80 ms warm hold described under Display.
Retracting the wish stops the video and leaves no `ffmpeg` behind
(`test/video.folk` and `test/video-restart.folk` check this).

## Decoding and the ring

- `ffmpeg` writes PPM frames on `pipe:1` and, when there is sound,
  48 kHz stereo `s16le` on `pipe:3`. Frames are scaled to at most 640
  wide at 25 fps (`scale='min(640,iw)':-2,fps=25`). Only the `ffmpeg`
  binary is needed (see `README.md`), on macOS and Linux.
- The ring is 26 MB per source by default (`FOLK_VIDEO_RING_MB`, 4 to
  256), and at most 1024 frames. It is `mmap`ed when the first frame
  comes in and `munmap`ed when the source closes, so its memory goes
  back to the OS.
  - A short clip fits in the ring completely; once it is all decoded,
    `ffmpeg` stays blocked on its pipe and uses no CPU.
  - A longer clip keeps a window of frames around the playhead.
- `videoDecodeThread` owns the `ffmpeg` process (`posix_spawnp`,
  `O_CLOEXEC` pipes) and fills the ring. It never touches the database.
- `videoPlayThread` paces frames at 25 fps (or to the audio clock),
  copies out the frame to show, publishes `$p has video $path frame
  $im`, and writes the sound to an `AudioStream` from `audio.folk`.
- `ffprobe` results are cached by path, mtime and size.
- **Sharing:** a player opened `with source $prog` attaches to the
  source already playing the same file on `$prog`, if that clip fits
  in its ring (no new `ffmpeg`). If not, it opens its own source around
  the time it seeks to, so the two don't fight over the ring.

## Sound

- `ffmpeg` decodes sound at 1x, paired frame by frame with the picture
  (7,680 bytes per 40 ms frame).
- At rate 1 the samples go straight to `audioStreamWriteBytes`. At
  other forward rates (0.1x to 16x), a WSOLA time-scaler keeps the
  pitch the same.
- Reversed or paused video is silent, but the `AudioStream` stays open,
  so playing forwards again doesn't reopen it.
- `volume` and `muted` come from the options.

## Display

- Display options (`width`, `height`, `position`, ...) are passed
  straight to `Wish $p displays image`, so they mean exactly what they
  mean for images.
- Changing an option rematches the `When`, so a program that moves or
  resizes its video every frame would restart it every frame. Instead,
  for 80 ms (`VIDEO_WARM_HOLD_NS`) after a player closes, its source,
  playhead and `AudioStream` are kept warm, and a new player for the
  same program and file takes them over: no new `ffmpeg`, and the
  picture doesn't jump back to the start.
- Each playing video claims `$p has video $path frame $im` (`uniq`
  counts from 1), `$p plays video $path from $from length $length at
  rate $rate`, `$p has video $path duration $seconds`, and `$p has
  negotiated video speed $rate` (signed, `%.1f`).
