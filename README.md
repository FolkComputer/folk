**Note: Folk is in a *pre-alpha* state and isn't yet well-documented
or well-exampled.**

**We're making Folk's source code free and available to the public, in
case you're already excited about trying it, but we haven't formally
announced it or made it ready for public use. We make no guarantee of
support, of usability, or of continuing backward compatibility. Try at
your own risk!**

We're working on a more formal announcement, which will talk
more about the goals of the project & provide canonical examples/demos
to show what's possible. If you don't know what this is, then you
might want to wait for that release.

-----

# [Folk](https://folk.computer)

[Folk](https://folk.computer) is a physical computing system: reactive
database, programming environment, projection mapping. Instead
of a phone/laptop/touchscreen/mouse/keyboard, your computational
objects are physical objects in the real world, and you can program
them inside the system itself. Folk is [written in a mix of C and
Tcl](https://github.com/FolkComputer/folk/blob/main/docs/design.md).

## Hardware

You'll need to set up a dedicated PC to run Folk and connect to
webcam+projector+printer+etc.

We tend to recommend a Beelink mini-PC (or _maybe_ a Pi 5).

See <https://folk.computer/pilot/>

## Linux tabletop installation using live USB

**Experimental:** If you have an amd64 PC, you can use the live USB
image which has Folk and all dependencies pre-installed.

**See <https://github.com/FolkComputer/folk/releases> to
get the Linux live USB image.**

You can update Folk by running `git pull` in the `folk` subfolder of
the FOLK-LIVE partition once you've flashed the live USB.

## Manual Linux tabletop installation

On an Intel/AMD PC, set up [Ubuntu **Server** 24.04 LTS (Noble
Numbat)](https://ubuntu.com/download/server#releases).

(for a Pi 4/5, use Raspberry Pi Imager and get Raspberry Pi OS Lite
64-bit version [also see [this
issue](https://github.com/raspberrypi/rpi-imager/issues/466#issuecomment-1207107554)
if flashing from a Mac] -- Ubuntu doesn't have a good kernel for Pi 5)

1. Install Linux with username `folk`, hostname
   `folk-SOMETHING`? (check hosts.tcl in this repo to make sure
   you're not reusing one)

   If no `folk` user, then:

        sudo useradd -m folk; sudo passwd folk;

   After creating `folk` user, then:
    
        for group in adm dialout cdrom sudo audio video plugdev games users input tty render netdev lpadmin gpio i2c spi; do sudo usermod -a -G $group folk; done; groups folk

1. `sudo apt update`

1. Set up OpenSSH server if needed; connect to network. To ssh into
   `folk@folk-WHATEVER.local` by name, `sudo apt install avahi-daemon`
   and then on your laptop: `ssh-copy-id folk@folk-WHATEVER.local`

1. Install dependencies: `sudo apt install rsync tcl-thread tcl8.6-dev
   git libjpeg-dev libpng-dev libdrm-dev pkg-config v4l-utils
   mesa-vulkan-drivers vulkan-tools libvulkan-dev libvulkan1 meson
   libgbm-dev glslc vulkan-validationlayers ghostscript console-data kbd`

   (When prompted while installing `console-data` for `Policy for handling keymaps` type `3` (meaning `3. Keep kernel keymap`) and press `Enter`)

1. Vulkan testing (optional):
     1. Try `vulkaninfo` and see if it works.
          1. On a Pi, if vulkaninfo reports "Failed to detect any
             valid GPUs in the current config", add `dtoverlay=vc4-kms-v3d` to the bottom of
             `/boot/firmware/config.txt`.
             (<https://raspberrypi.stackexchange.com/questions/116507/open-dev-dri-card0-no-such-file-or-directory-on-rpi4>)
     1. Try `vkcube`:

            git clone https://github.com/krh/vkcube
            cd vkcube
            mkdir build; cd build; meson .. && ninja
            ./vkcube -m khr -k 0:0:0
      
        If vkcube says `Assertion ``vc->image_count > 0' failed`, you
        might be able to still skip vkcube and continue the install
        process. See [this
        bug](https://github.com/FolkComputer/folk/issues/109#issuecomment-1788085237)
     1. See [notes](https://folk.computer/notes/vulkan) and [Naveen's
        notes](https://gist.github.com/nmichaud/1c08821833449bdd3ac70dcb28486539).

1. `sudo nano /etc/udev/rules.d/99-input.rules`. add
   `SUBSYSTEM=="input", GROUP="input", MODE="0666"`. `sudo udevadm
   control --reload-rules && sudo udevadm trigger`

1. Get AprilTags: `cd ~ && git clone https://github.com/FolkComputer/apriltag.git && cd apriltag && make libapriltag.so libapriltag.a`

1. Add the systemd service so it starts on boot and can be managed
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

Use `visudo` to add `folk ALL=(ALL) NOPASSWD: /usr/bin/systemctl` to
the bottom of `/etc/sudoers` on the tabletop. (This lets the `make`
scripts from your laptop manage the Folk service by running
`systemctl` without needing a password.)

Then, _on your laptop_, clone this repository:

```
$ git clone https://github.com/FolkComputer/folk.git
```

And run `make sync-restart FOLK_SHARE_NODE=folk-WHATEVER.local`. This
will rsync folk to the tabletop and run it there as well as running it
on your laptop.

(or clone it onto the machine and run `sudo systemctl start folk` there)

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

1. Position the camera. Make sure Folk is running (ssh in, `cd
   ~/folk`, `./folk.tcl start`). Go to your Folk server's Web page
   http://whatever.local:4273/camera-frame to see a preview of what
   the camera sees. Reposition your camera to cover your table.

1. Go to the Folk calibration page at
   http://whatever.local:4273/calibrate and follow the instructions
   (print calibration board & run calibration process).

### Connect a keyboard

Follow [the instructions on this Folk wiki page](https://folk.computer/guides/keyboard)
to connect a new keyboard to your system.

### Bluetooth keyboards

Install `bluetoothctl`. Follow the instructions in
https://wiki.archlinux.org/title/bluetooth_keyboard to pair and trust
and connect.

(FIXME: Write down the Bluetooth MAC address of your keyboard. We'll
proceed as though it's "f4:73:35:93:7f:9d" (it's important that you
turn it into lowercase).)

### Potentially useful

Potentially useful for graphs: `graphviz`

Potentially useful:  `gdb`, `streamer`, `cec-utils`,
`file`, `strace`

Potentially useful: add `folk-WHATEVER` shortcut to your laptop `~/.ssh/config`:
```
Host folk-WHATEVER
     HostName folk-WHATEVER.local
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

## Troubleshooting

### Why is my camera slow (why is tracking janky or laggy, why is camera time high)

#### Check that camera is plugged into a USB3 port

#### Turn off autoexposure and autofocus

for example, install `v4l-utils` and:

```
v4l2-ctl -c auto_exposure=1
v4l2-ctl -c focus_automatic_continuous=0
v4l2-ctl -c white_balance_automatic=0
```

### Tcl troubleshooting

You can build Tcl with `TCL_MEM_DEBUG`. Download Tcl source code. (On
Mac, _do not_ go to the macosx/ subdir; go to the unix/ subdir.) Do
`./configure --enable-symbols=all`, do `make`, `make install`

## License

Folk is available under the Apache 2.0 license. See the [LICENSE](LICENSE) file
for more information.

## Language reference

Folk is built around Tcl. We don't add any additional syntax or
preprocessing to the basic Tcl language; all our 'language constructs'
like `When` and `Wish` are really just plain Tcl functions that we've
created. Therefore, it will eventually be useful for you to know
[basic](http://antirez.com/articoli/tclmisunderstood.html) [Tcl
syntax](https://www.ee.columbia.edu/~shane/projects/sensornet/part1.pdf).

These are all implemented in `main.tcl`. For most things, you'll
probably only need `Wish`, `Claim`, `When`, and maybe `Hold`.

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

The `/actor/` in the `When` binds the variable `actor` to whatever is
at that position in the statement.

It's like variables in Datalog, or parentheses in regular expressions.

#### Non-capturing

`/someone/`, `/something/`, `/anyone/`, `/anything/` are special cases
if you want a wildcard that _does not bind_ (you don't care about the
value, like non-capturing groups `(?:)` in regex), so you don't get access
to `$someone` or `$something` inside the When.

#### Negation

`/nobody/`, `/nothing/` invert the polarity of the match, so it'll run
only when no statements exist that it would match.

This When will stop labelling if someone does `Claim Omar is cool`:

```
When /nobody/ is cool {
   Wish $this is labelled "nobody is cool"
}
```

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

### Hold

Experimental: `Hold` is used to register claims that will stick
around until you do another `Hold`. You can use this to create the
equivalent of 'variables', stateful statements.

```
Hold { Claim $this has a ball at x 100 y 100 }

When $this has a ball at x /x/ y /y/ {
    puts "ball at $x $y"
    After 10 milliseconds {
        Hold { Claim $this has a ball at x $x y [expr {$y+1}] }
        if {$y > 115} { set ::done true }
    }
}
```

`Hold` will overwrite all statements made by the previous `Hold`
(scoped to the current `$this`).

**Notice that you should scope your claim: it's `$this has a ball`, not `there
is a ball`, so different programs with different values of `$this`
will not stomp over each other.** Not scoping your claims will bite
you once you print your program and have both virtual & printed
instances of your program running.

If you want multiple state atoms, you can also provide a key -- you
can be like

```
Hold ball position {
  Claim $this has a ball at blahblah
}
```

and then future holds with that key, `ball position`, will
overwrite this statement but not override different holds with
different keys

You can overwrite another program's Hold with the `on` parameter, like
`Hold (on 852) { ... }` (if the Hold is from page 852) or `Hold (on
virtual-programs/example.folk) { ... }` (if the Hold is from the
example.folk virtual program)

### Every time

Experimental: `Every time` works almost like `When`, but it's used to
hold when an 'event' happens without causing a reaction cascade.

**You can't make Claims, Whens, or Wishes inside an `Every time`
block. You can only Hold.**

Example:

```
Hold { Claim $this has seen 0 boops }

Every time there is a boop & $this has seen /n/ boops {
  Hold { Claim $this has seen [expr {$n + 1}] boops }
}
```

If you had used `When` here, it wouldn't terminate, since the new
`$this has seen n+1 boops` hold would cause the `When` to retrigger,
resulting in a `$this has seen n+2 boops` hold, then another
retrigger, and so on.

`Every time`, in contrast, will 'only react once' to the boop; nothing
in its body will run again unless the boop goes away and an entirely
new boop appears.

### Animation

#### Getting time

Get the global clock time with:

```
When the clock time is /t/ {
  Wish $this is labelled $t
}
```

Use it in an animation:

```
When the clock time is /t/ {
  Wish $this draws a circle with offset [list [expr {sin($t) * 50}] 0]
}
```

### You usually won't need these

#### When when

Lets you create statements only on demand, when someone is looking for
that statement.

```
When /thing/ is cool {
    Wish $this is labelled "$thing is cool"
}
When when /personVar/ is cool /lambda/ with environment /e/ {
    Claim Folk is cool
}
```

#### On and Start

FIXME: General note: the `On` and `Start` blocks are used for weird
non-reactive behavior. Need to fill this out more.

##### Start process

```
Start process A {
  while true {
    puts "Hello! Another second has passed"
    exec sleep 1
  }
}
```

##### On unmatch

You should _not_ use `When`, `Claim`, or `Wish` directly inside an
`On unmatch` block; those only make sense inside a normal reactive
context.

```
set pid [exec python3]
On unmatch {
    kill $pid
}
```


#### Non-capturing

You can disable capturing of lexical context around a When with the
`(non-capturing)` flag.

This is mostly to help runtime performance if a When is declared
somewhere that has a lot of stuff in scope at declaration time.

```
set foo 3
When (non-capturing) /p/ is cool {
   Claim $p is awesome
   # can't access $foo from in here
}
```

#### Assert and Retract

General note: `Assert` and `Retract` are used for weird non-reactive
behavior.

You should generally _not_ use `Assert` and `Retract` inside a `When`
block. Use `Claim`, `Wish`, and `When` instead.

## Tcl for JavaScripters

JS:
```
let names = ["64", "GameCube", "Wii", "Switch"];
names = names.map(name => `Nintendo ${name}`);
console.log(names);

function add(a, b) { return a + b; }
const numbers = [1, 2];
console.log(add(...numbers));
```

Tcl:
```
set names [list 64 GameCube Wii Switch]
set names [lmap name $names {expr {"Nintendo $name"}}]
puts $names

proc add {a b} { expr {$a + $b} }
set numbers [list 1 2]
puts [add {*}$numbers]
```

## Style guide

### Tcl code vs. virtual programs vs. printed programs

In general, avoid adding new .tcl files to the Git repo. Pure Tcl
libraries are an antipattern; we should only need them for the hard
core of the system.

Most new code (both libraries and applications) should be virtual
programs (which ilve as .folk files in the virtual-programs/
subfolder) or printed programs.

### Folk 

- Use complete sentences when you word your claims and wishes.

  Bad: `Claim $this firstName Omar`

  Good: `Claim $this has first name Omar`

- Scope using `$this` where appropriate to prevent weird global
  interactions

  Bad: `Claim the value is 3`

  Good: `Claim $this has value 3`

- Style for joins across multiple lines -- use `&\` and align on the
  first token after `When`:

  ```
  When the fox is out &\
       the label is "Hello" &\
       everything seems good {
    ...
  }
  ```

### Tcl

#### fn

Use `fn` instead of `proc` to get a lexically captured command.

#### Error handling

Use `try` (and `on error`) in new code. Avoid using `catch`; it's
older and easier to get wrong.

#### apply

Use `apply` instead of `subst` to construct lambdas/code blocks,
except for one-liners (where you can use `list`)

#### Tcl datatypes

Create a namespace for your datatype that is an ensemble command with
operations on that datatype.

(Examples: `statement`, `c`, `region`, `point`, `image`)

Call the constructor `create`, as in `dict create` and `statement
create`.

#### Singletons

Capitalized namespace, like `Statements`.
