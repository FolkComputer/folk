# terminal.tcl --
#
#     Implements a virtual terminal with basic read/write procs.
#

set cc [c create]
$cc cflags -I./vendor/libtmt ./vendor/libtmt/tmt.c

# TODO: find the right libutil.so for the system
c loadlib /lib/aarch64-linux-gnu/libutil.so
$cc cflags -lutil

$cc include <sys/types.h>
$cc include <stdio.h>
$cc include <stdlib.h>
$cc include <unistd.h>
$cc include <pty.h>
$cc include <fcntl.h>
$cc include <string.h>
$cc include <sys/time.h> ;# For gettimeofday()

$cc code {
  #include "tmt.h"

  #define SHELL "/bin/bash"

  #define ROWS 12
  #define COLS 43

  typedef struct {
    TMT *tmt;
    pid_t pty_fd;

    char screen[ROWS][COLS + 1];
    int curs_r;
    int curs_c;
  } VTerminal;

  VTerminal *vt = NULL;

  #define PTYBUF 4096
  char iobuf[PTYBUF];

  void tmt_callback(tmt_msg_t m, TMT *tmt, const void *a, void *p) {
      const TMTSCREEN *s = tmt_screen(tmt);

      if (m == TMT_MSG_UPDATE) {
        for (size_t r = 0; r < s->nline; r++){
            if (s->lines[r]->dirty){
                for (size_t c = 0; c < s->ncol; c++){
                  vt->screen[r][c] = s->lines[r]->chars[c].c;
                }
            }
        }
        tmt_clean(tmt);
      }
  }

  void updateCursor() {
    // Restore char under old cursor
    const TMTSCREEN *s = tmt_screen(vt->tmt);
    vt->screen[vt->curs_r][vt->curs_c] = s->lines[vt->curs_r]->chars[vt->curs_c].c;

    // Update new cursor
    const TMTPOINT *c = tmt_cursor(vt->tmt);
    vt->curs_r = c->r;
    vt->curs_c = c->c;

    // Replace char with cursor every other second
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv.tv_sec % 2 == 0) {
      vt->screen[vt->curs_r][vt->curs_c] = 0xDB; // block char: █
    }
  }
}

$cc proc termCreate {} void {
  if (vt != NULL) {
    return;
  }

  vt = malloc(sizeof(VTerminal));
  vt->curs_r = 0;
  vt->curs_c = 0;

  for (int r = 0; r < ROWS - 1; r++) vt->screen[r][COLS] = '\n';
  vt->screen[ROWS - 1][COLS] = '\0';

  vt->tmt = tmt_open(ROWS, COLS, tmt_callback, NULL, NULL);

  struct winsize ws = {.ws_row = ROWS, .ws_col = COLS};
  pid_t pid = forkpty(&vt->pty_fd, NULL, NULL, &ws);
  if (pid < 0){
    return;
  } else if (pid == 0){
    setenv("TERM", "ansi", 1);
    execl(SHELL, SHELL, NULL);
    return;
  }

  fcntl(vt->pty_fd, F_SETFL, O_NONBLOCK);
  return;
}

$cc proc termRead {} char* {
  ssize_t r = read(vt->pty_fd, iobuf, PTYBUF);
  if (r > 0) {
    tmt_write(vt->tmt, iobuf, r);
  }

  updateCursor(vt);
  return (char*)vt->screen;
}

$cc proc termWrite {char* key} void {
  write(vt->pty_fd, key, strlen(key));
}

$cc compile

# Folk stuff...

namespace eval Terminal {
  # From `man console_codes`
  variable keymap [dict create \
    ENTER     "\x0d" \
    TAB       "\x09" \
    BACKSPACE "\x08" \
    DELETE    "\x7f" \
    ESC       "\x1b" \
    UP        "\x1b\[A" \
    DOWN      "\x1b\[B" \
    RIGHT     "\x1b\[C" \
    LEFT      "\x1b\[D" \
  ]

  proc remap {key ctrlPressed} {
    variable keymap
    if {[string length $key] == 1} {
      # Convert ctrl-A through ctrl-Z and others to terminal control characters
      if {$ctrlPressed} {
        set charCode [scan [string toupper $key] %c]
        if {$charCode >= 64 && $charCode <= 95} {
          set charCode [expr {$charCode - 64}]
          return [format %c $charCode]
        }
      }
      # All other single char keys can be passed through
      return $key
    }
    if {[dict exists $keymap $key]} {
      return [dict get $keymap $key]
    }
    return ""
  }

  # Creates a new virtual terminal and returns its ID
  proc create {} {
    return [termCreate]
  }

  proc destroy {} {
    # TODO
  }

  # Writes a keyboard key to the terminal, handling control codes
  proc write {key ctrlPressed} {
    set key [remap $key $ctrlPressed]
    if {[string length $key] > 0} {
      termWrite $key
    }
  }

  # Returns a newline separated string of terminal lines
  proc read {} {
    return [termRead]
  }
}
