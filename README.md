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
