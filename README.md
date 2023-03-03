# Folk

## Mac installation

to run on (Mac) laptop:
```
$ brew install tcl-tk
$ ln -s /usr/local/Cellar/tcl-tk/8.6*/bin/tclsh /usr/local/bin/tclsh8.6
```

then:
```
make
```

## Linux tabletop installation

These are for a dedicated system, probably on a Raspberry Pi 4 or
Intel NUC, probably running Raspberry Pi OS Lite 32-bit or Ubuntu
Server 22.04 LTS-minimal.

1. Install Linux with username `folk`, hostname
   `folk-SOMETHING.local`? (check hosts.tcl in this repo to make sure
   you're not reusing one)

   On Pi, Raspberry Pi OS Lite => if no `folk`
   user, then:

        sudo useradd -m folk; sudo passwd folk;
        sudo usermod -a -G adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,lpadmin,gpio,i2c,spi folk

3. `sudo apt update`
2. Set up OpenSSH server if needed, connect to network.
4. `sudo apt install avahi-daemon` if needed (for mDNS so hostname can be autodiscovered)
5. On your laptop: `ssh-copy-id folk@folk-WHATEVER.local`
6. `sudo apt install make rsync tcl-thread tcl8.6-dev git libjpeg-dev fbset`
7. `sudo adduser folk video` & `sudo adduser folk input` (?) & log out and log back in (re-ssh)
8. `sudo nano /etc/udev/rules.d/99-input.rules`. add
   `SUBSYSTEM=="input", GROUP="input", MODE="0666"`. `sudo udevadm control --reload-rules && sudo udevadm trigger`
9. Get AprilTags: `cd ~; git clone
   https://github.com/AprilRobotics/apriltag.git; cd apriltag; make`
   (you can probably ignore errors at the end of this if they're just
   for the OpenCV demo)
10. Add the systemd service so it starts on boot and can be managed
   when you run it from laptop. On Ubuntu Server or Raspberry Pi OS
   (as root) ([from
   here](https://medium.com/@benmorel/creating-a-linux-service-with-systemd-611b5c8b91d6)):

        # cat >/etc/systemd/system/folk.service
        [Unit]
        Description=Folk service
        After=network.target
        StartLimitIntervalSec=0

        [Service]
        Type=simple
        Restart=always
        RestartSec=1
        User=folk
        ExecStart=make -C /home/folk/folk

        [Install]
        WantedBy=multi-user.target

        # systemctl start folk
        # systemctl enable folk

You probably want to add `folk ALL=(ALL) NOPASSWD: /usr/bin/systemctl`
to `/etc/sudoers` as well.

Then, _on your laptop_, clone this repo and run `make
FOLK_SHARE_NODE=folk-WHATEVER.local`. This will rsync folk to the
tabletop and run it there as well as running it on your laptop.

### How to control tabletop Folk from your laptop

On your laptop Web browser, go to http://folk-WHATEVER.local:4273 --
click New Program, hit Save, drag it around. You should see the
program move on your table as you drag it around on your laptop.

Does it work? Add your tabletop to hosts.tcl! Send in a patch!
Celebrate!

### General debugging

You can run `make journal` to see stdout/stderr output from the
tabletop machine. If you need to pass in a specific hostname, `make
journal FOLK_SHARE_NODE=folk-whatever.local`.

`make repl` will give you a dialed-in Tcl REPL.

### Printer support

On the tabletop:
```
$ sudo apt update
$ sudo apt install cups cups-bsd
$ sudo usermod -a -G lpadmin folk
```

(`cups-bsd` provides the `lpr` command that we use to print)

ssh tunnel to get access to CUPS Web UI: run on your laptop `ssh -L 6310:localhost:631
folk@folk-WHATEVER.local`, leave it open

Go to http://localhost:6310 on your computer, go to Printers,
hopefully it shows up there automatically, try printing test page. _I
could not get that implicitclass:// automatically-added printer in
CUPS to work for my printer at all_, so I did the below:

If job is paused due to `cups-browsed` issue or otherwise doesn't
work, try
https://askubuntu.com/questions/1128164/no-suitable-destination-host-found-by-cups-browsed :
remove `cups-browsed` `sudo apt-get purge --autoremove cups-browsed`
then add printer manually via IPP in Add Printer in Administration tab
of CUPS Web UI (it might automatically show up under Discovered
Network Printers there using dnssd)

Once printer is working, go to Administration dropdown on printer page
and Set as Server Default.

Try printing from Folk!

You can also test printing again with `lpr
~/folk-printed-programs/SOMETHING.pdf` (you have to print the PDF and
not the PS for it to work, probably)

### Projector-camera calibration

1. Print 4 AprilTags.

1. On the tabletop, suspend the system with `sudo systemctl stop folk` and run
   `tclsh8.6 pi/Camera.tcl` and position your camera to cover your
   table.

1. Place the 4 AprilTags around your table. On the tabletop, run
   `tclsh8.6 calibrate.tcl`. Wait.

1. You should see red triangles projected on each of your 4 tags. Then
   you're done! Run Folk! If not, rerun calibration until you do see a
   red triangle on each tag.

### Bluetooth keyboards

Install `bluetoothctl`. Follow the instructions in
https://wiki.archlinux.org/title/bluetooth_keyboard to pair and trust
and connect.

Write down the Bluetooth MAC address of your keyboard. We'll proceed
as though it's "f4:73:35:93:7f:9d" (it's important that you turn it
into lowercase).

Next, add a udev rule on a new line at the end of `/etc/udev/rules.d/99-input.rules` to create
a stable device file at `/dev/input/btkeyboard-f4-73-35-93-7f-9d` that Folk can
get events on:

```
KERNEL=="event[0-9]|event[0-9][0-9]", SUBSYSTEM=="input", ATTRS{uniq}=="f4:73:35:93:7f:9d", ACTION=="add", SYMLINK+="input/btkeyboard-f4-73-35-93-7f-9d"
```


### Potentially useful

Potentially useful for graphs: `graphviz`

Potentially useful: `v4l-utils`, `gdb`, `streamer`, `cec-utils`,
`file`, `strace`

Potentially useful: add `folk0` shortcut to your laptop `~/.ssh/config`:
```
Host folk0
     HostName folk0.local
     User folk
```

Potentially useful: `journalctl -f -u folk` to see log of folk service

For audio:
https://askubuntu.com/questions/1349221/which-packages-should-be-installed-to-have-sound-output-working-on-minimal-ubunt

### HDMI No signal on Pi 4

Edit /boot/cmdline.txt https://github.com/raspberrypi/firmware/issues/1647#issuecomment-971500256
(HDMI-A-1 or HDMI-A-2 depending on which port)

### Ubuntu Server boots slowly

https://askubuntu.com/questions/1321443/very-long-startup-time-on-ubuntu-server-network-configuration
(add `optional: true` to all netplan interfaces)

## Setup notes

- get a separate computer (Raspberry Pi 4, probably). don't use your laptop.
- make as solid / permanent a mount as you can. you shouldn't be
  scared of it falling and you shouldn't have to take it apart and put
  it back together every time

## License

We intend to release this repo as open-source under an MIT, GPLv3,
Apache 2.0, or AGPLv3 license by June 2023 or earlier; by contributing
code, you're also agreeing to license your code under whichever
license we end up choosing.

## Stuff

- implement generators (~point at~)
- ~implement even-better fake lexical scope~
- ~share (axiom) statements from laptop -> Pi~
- ~mmap or otherwise hw-accelerate pi graphics~
- ~bareword/nicer colors for Pi~ (could support more colors)
- keyboard support for Pi
- ~watchdog on Pi~, ~autoupdate on Pi~
- parallelize tag detection / camera processing
- text editor
- ~print support~
- ~clean up lexical scope~
- ~with-all-matches~

## Troubleshooting

You can build Tcl with `TCL_MEM_DEBUG`. Download Tcl source code. (On
Mac, _do not_ go to the macosx/ subdir; go to the unix/ subdir.) Do
`./configure --enable-symbols=all`, do `make`, `make install`

## Vulkan

### Pi 4

Basically follow
https://forums.libretro.com/t/retroarch-raspberry-pi-4-vulkan-without-x-howto/31164/2 except:

install `pkg-config` if it can't find `libdrm`

`sudo ninja install` to install Mesa system-wide

Clone https://github.com/krh/vkcube and `mkdir build` and `meson ..`
and `ninja` and `./vkcube -m khr -k 0:0:0`.

### Hades Canyon NUC

Also similar to above Pi 4 instructions.

`sudo apt install libdrm-dev libdrm-tests`

`modetest -M amdgpu` to list connectors and not try the Intel
integrated graphics

`modetest -M amdgpu -s 86:3840x2160`

You need `glslang-tools` before running `meson` to build Mesa:

`sudo apt install glslang-dev glslang-tools spirv-tools
python3-mako pkg-config libudev-dev clang llvm-dev bison flex`

`sudo apt install libelf-dev` for some reason https://gitlab.freedesktop.org/mesa/mesa/-/issues/7456
 make sure meson finds it below! `Run-time dependency libelf found: YES 0.186` it won't fail in configure phase
 if it doesn't

Mesa `meson` configure options for the AMD GPU:

`meson -Dglx=disabled -Dplatforms=
-Dvulkan-drivers=amd -Ddri-drivers='' -Dgallium-drivers=radeonsi
-Dbuildtype=release ..`

`vulkaninfo`

`sudo chmod 666 /dev/dri/renderD129`

### Testing

clone https://github.com/krh/vkcube

`mkdir build; cd build; meson .. && ninja`

`./vkcube -m khr -k 0:0:0`

## Language reference

Folk is built around Tcl. We don't add any additional syntax or
preprocessing to the basic Tcl language; all our 'language constructs'
like `When` and `Wish` are really just plain Tcl functions that we've
created. Therefore, it will eventually be useful for you to know
[basic](http://antirez.com/articoli/tclmisunderstood.html) [Tcl
syntax](https://www.ee.columbia.edu/~shane/projects/sensornet/part1.pdf).

These are all implemented in `main.tcl`. For most things, you'll
probably only need `Wish`, `Claim`, `When`, and maybe `Commit`.

### Wish and Claim

```
Wish $this is labelled "Hello, world!"
```

```
Claim $this is cool
Claim Omar is cool
```

### When

```
When /actor/ is cool {
   Wish $this is labelled "$actor seems pretty cool"
   Wish $actor is outlined red
}
```

The inside block (body) of the `When` gets executed for each claim
that is being made that it matches. It will get reactively rerun
whenever a new matching claim is introduced.

Any wishes/claims you make in the body will get automatically revoked
if the claim that the `When` was matching is revoked. (so if Omar stops
being cool, the downstream label `Omar seems pretty cool` will go away
automatically)

The `/actor/` in the `When` binds the
variable `actor` to whatever is at that position in the
statement.

It's like variables in Datalog, or parentheses in regular expressions.

#### `&` joins

You can match multiple patterns at once:

```
Claim Omar is cool
Claim Omar is a person with 2 legs
When /x/ is cool & /x/ is a person with /n/ legs {
   Wish $this is labelled "$x is a cool person with $n legs"
}
```

Notice that `x` here will have to be the same in both arms of the
match.

You can join as many patterns as you want, separated by `&`.

If you want to break your `When` onto multiple lines, remember to
terminate each line with a `\` so you can continue onto the next
line:

```
When /x/ is cool & \
    /x/ is a person with /n/ legs {
  Wish $this is labelled "$x is a cool person with $n legs"
}
```

### Collecting matches

```
When the collected matches for [list /actor/ is cool] are /matches/ {
   Wish $this is labelled [join $matches "\n"]
}
```

This gets you an array of all matches for the pattern `/actor/ is
cool`.

(We use the Tcl `list` function to construct a pattern as a
first-class object. You can use `&` joins in that pattern as
well.)

### Commit

Experimental: `Commit` is used to register claims that will stick
around until you do another `Commit`. You can use this to create the
equivalent of 'variables', stateful statements.

```
Commit { Claim there is a ball at x 100 y 100 }

When there is a ball at x /x/ y /y/ {
    puts "ball at $x $y"
    After 10 milliseconds {
        Commit { Claim there is a ball at x $x y [expr {$y+1}] }
        if {$y > 115} { set ::done true }
    }
}
```

`Commit` will overwrite all statements made by the previous `Commit`
(scoped to the current `$this`).

If you want multiple state atoms, you can also provide a key -- you
can be like

```
Commit the ball position {
  Claim the ball is at blahblah
}
```

and then future commits with that key, `the ball position`, will
overwrite this statement but not override different commits with
different keys

(there's currently no way to overwrite state from other pages, but we
could probably add a way to provide an absolute key that would allow
that if it was useful.)

### You usually won't need these

#### On

General note: the `On` block is used for weird non-reactive
behavior.

You should _not_ use `When`, `Claim`, or `Wish` directly inside an
`On` block; those only make sense inside a normal reactive context.

##### On process

```
On process A {
  while true {
    puts "Hello! Another second has passed"
    exec sleep 1
  }
}
```

##### On unmatch

```
set pid [exec chmod 33]
On unmatch {
    kill $pid
}
```

#### Assert and Retract

General note: `Assert` and `Retract` are used for weird non-reactive
behavior.

You should generally _not_ use `Assert` and `Retract` inside a `When`
block. Use `Claim`, `Wish`, and `When` instead.
