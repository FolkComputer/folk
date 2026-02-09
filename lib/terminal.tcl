# terminal.tcl --
#
#     Implements a virtual terminal with basic read/write procs.
#

set cc [C]
$cc cflags -I./vendor/libtmt
$cc endcflags -lutil ./vendor/libtmt/tmt.c

$cc include <sys/types.h>
$cc include <stdlib.h>
$cc include <unistd.h>
if {$::tcl_platform(os) eq "darwin"} {
    $cc include <util.h>
} else {
    $cc include <pty.h>
}
$cc include <fcntl.h>
$cc include <string.h>
$cc include <sys/time.h>
$cc include <signal.h>
$cc include "tmt.h"

$cc struct VTerminal {
  TMT* tmt;
  int pty_fd;
  int pid;

  // Note: display has 1 more column than tmt screen to hold newlines between each line
  char* display;
  int curs_r;
  int curs_c;
  int ncols;
};

$cc code {
  #define PTYBUF 4096
  char iobuf[PTYBUF];

  char* charAt(VTerminal *vt, int r, int c) {
    int i = r * (vt->ncols + 1) + c;
    return &vt->display[i];
  }

  void tmtEvent(tmt_msg_t m, TMT *tmt, const void *a, void *p) {
      VTerminal *vt = (VTerminal*)p;
      const TMTSCREEN *s = tmt_screen(tmt);

      if (m == TMT_MSG_UPDATE) {
        for (size_t r = 0; r < s->nline; r++){
            if (s->lines[r]->dirty){
                for (size_t c = 0; c < s->ncol; c++){
                  *charAt(vt, r, c) = s->lines[r]->chars[c].c;
                }
            }
        }
        tmt_clean(tmt);
      }
  }

  void blinkCursor(VTerminal *vt) {
    // Restore char under old cursor
    const TMTSCREEN *s = tmt_screen(vt->tmt);
    *charAt(vt, vt->curs_r, vt->curs_c) = s->lines[vt->curs_r]->chars[vt->curs_c].c;

    // Update new cursor
    const TMTPOINT *c = tmt_cursor(vt->tmt);
    vt->curs_r = c->r;
    vt->curs_c = c->c;

    // Replace char with cursor every other second
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv.tv_sec % 2 == 0) {
      *charAt(vt, vt->curs_r, vt->curs_c) = 0xDB; // block char: █
    }
  }
}

$cc proc termCreate {int rows int cols char* cmd[]} VTerminal* {
  int i = 0;
  while (true) {
    // execvp requires cmd array to be terminated by null pointer
    if (strlen(cmd[i]) == 0) { cmd[i] = NULL; break; }
    i++;
  }

  VTerminal *vt = malloc(sizeof(VTerminal));
  vt->curs_r = 0;
  vt->curs_c = 0;
  vt->ncols = cols;

  vt->display = malloc(sizeof(char[rows][cols + 1]));
  for (int r = 0; r < rows - 1; r++) {
    *charAt(vt, r, cols) = '\n';
  }
  *charAt(vt, rows - 1, cols) = '\0';

  vt->tmt = tmt_open(rows, cols, tmtEvent, vt, NULL);

  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  pid_t pid = forkpty(&vt->pty_fd, NULL, NULL, &ws);
  if (pid < 0){
    return NULL;
  } else if (pid == 0){
    setenv("TERM", "ansi", 1);
    if (execvp(cmd[0], cmd) == -1) {
      fprintf(stderr, "execvp(%s, ...) failed: %m\n", cmd[0]);
    }
    return NULL;
  }

  vt->pid = pid;
  fcntl(vt->pty_fd, F_SETFL, O_NONBLOCK);
  return vt;
}

$cc proc termDestroy {VTerminal* vt} void {
  kill(vt->pid, SIGTERM);
  close(vt->pty_fd);
  free(vt->display);
  free(vt);
}

$cc proc termRead {VTerminal* vt} char* {
  ssize_t r = read(vt->pty_fd, iobuf, PTYBUF);
  if (r > 0) {
    tmt_write(vt->tmt, iobuf, r);
  }

  blinkCursor(vt);
  return vt->display;
}

$cc proc termWrite {VTerminal* vt char* key} void {
  write(vt->pty_fd, key, strlen(key));
}

set impl [$cc compile]

set terminalLib [library create terminalLib {impl} {
  # From `man console_codes`
  variable keymap [dict create \
    Remove               "\x08" \
    Tab                  "\x09" \
    Linefeed             "\x0a" \
    Return               "\x0d" \
    nul                  "\x00" \
    Delete               "\x7f" \
    Escape               "\x1b" \
    Control_backslash    "\x1c" \
    Control_bracketright "\x1d" \
    Control_asciicircum  "\x1e" \
    Control_underscore   "\x1f" \
    Up                   "\x1b\[A" \
    Down                 "\x1b\[B" \
    Right                "\x1b\[C" \
    Left                 "\x1b\[D" \
  ]

  for {set i [scan a %c]} {$i <= [scan z %c]} {incr i} {
      set char [format %c $i]
      set charCode [expr {$i - 32 - 64}]
      set charCode [format %c $charCode]

      dict append keymap "Control_$char" $charCode
  }

  proc _remap {key} {
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

  proc create {rows cols cmd} {
    variable impl
    $impl termCreate $rows $cols [list bash -c $cmd ""]
  }

  proc destroy {term} {
    variable impl
    $impl termDestroy $term
  }

  proc write {term char} {
    variable impl
    $impl termWrite $term $char
  }

  proc handleKey {term key} {
    variable impl
    set key [_remap $key]
    if {$key ne ""} {
      $impl termWrite $term $key
    }
  }

  # Returns a newline separated string of terminal lines
  proc read {term} {
    variable impl
    $impl termRead $term
  }
}]

