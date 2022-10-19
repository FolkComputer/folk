# folk

to run on (Mac) laptop:
```
$ brew install tcl-tk
```

to run on Pi:
```
$ sudo apt install tcl tcl-thread critcl libjpeg62-turbo-dev

$ cd ~; git clone https://github.com/AprilRobotics/apriltag.git; cd apriltag
$ make -j
$ cd -2

$ make
```

then (on laptop or Pi):
```
make
```

## setup notes
- get a separate computer (Raspberry Pi 4, probably). don't use your laptop.
- make as solid / permanent a mount as you can. you shouldn't be
  scared of it falling and you shouldn't have to take it apart and put
  it back together every time

### NUC setup

1. install Ubuntu Server 22.04 LTS with username `folk`, hostname
   `folk0.local`? (on Pi: Raspbian Lite => `sudo useradd -m folk; sudo
   passwd folk; sudo usermod -a -G
   adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,lpadmin,gpio,i2c,spi
   folk`)
1. set up OpenSSH server
1. connect to Wi-Fi
1. `sudo apt update`
1. `sudo apt install avahi-daemon`
1. (on your laptop: `ssh-copy-id folk@folk0.local`)
1. `sudo apt install make rsync`
1. `sudo apt install tcl-thread critcl git killall libjpeg-dev fbset`
1. `sudo adduser folk video` & log out and log back in (re-ssh)
1. get apriltags: `cd ~; git clone
   https://github.com/AprilRobotics/apriltag.git; cd apriltag; make`
   (you can probably ignore errors at the end of this)
1. `make`


potentialyl useful: `v4l-utils`, `gdb`, `streamer`, `cec-utils`

### printer

```
$ sudo apt update
$ sudo apt install cups cups-bsd
$ sudo usermod -a -G lpadmin pi
```

ssh tunnel `ssh -L 6310:localhost:631 folk0`



## stuff
- implement generators (~point at~)
- ~implement even-better fake lexical scope~
- ~share (axiom) statements from laptop -> Pi~
- ~mmap or otherwise hw-accelerate pi graphics~
- ~bareword/nicer colors for Pi~ (could support more colors)
- keyboard support for Pi
- watchdog on Pi, ~autoupdate on Pi~
