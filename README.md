# folk

to run on (Mac) laptop:
```
$ brew install tcl-tk
$ ln -s /usr/local/Cellar/tcl-tk/8.6*/bin/tclsh /usr/local/bin/tclsh8.6
```

to run on Pi:
```
$ sudo apt install tcl tcl-thread libjpeg62-turbo-dev tcl8.6-dev

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

on Ubuntu Server on NUC (as root) ([from here](https://medium.com/@benmorel/creating-a-linux-service-with-systemd-611b5c8b91d6)):
```
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
ExecStart=make -C /home/folk/folk-rsync

[Install]
WantedBy=multi-user.target

# systemctl start folk
# systemctl enable folk
```

you probably want to add `folk ALL=(ALL) NOPASSWD: /usr/bin/systemctl`
to `/etc/sudoers` as well

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
1. `sudo apt install tcl-thread git killall libjpeg-dev fbset`
1. `sudo adduser folk video` & `sudo adduser folk input` (?) & log out and log back in (re-ssh)
1. `sudo nano /etc/udev/rules.d/99-input.rules`. add
   `SUBSYSTEM=="input", GROUP="input", MODE="0666"`. `sudo udevadm control --reload-rules && sudo udevadm trigger`
1. get apriltags: `cd ~; git clone
   https://github.com/AprilRobotics/apriltag.git; cd apriltag; make`
   (you can probably ignore errors at the end of this if they're just
   for the OpenCV demo)
1. `make`


potentially useful: `v4l-utils`, `gdb`, `streamer`, `cec-utils`,
`file`, `strace`

potentially useful: add `folk0` shortcut to your laptop
`~/.ssh/config`:
```
Host folk0
     HostName folk0.local
     User folk
```

`journalctl -f -u folk` to see log of folk service

for audio: https://askubuntu.com/questions/1349221/which-packages-should-be-installed-to-have-sound-output-working-on-minimal-ubunt

#### ubuntu server slow boot

https://askubuntu.com/questions/1321443/very-long-startup-time-on-ubuntu-server-network-configuration
(add `optional: true` to all netplan interfaces)

### printer

on the NUC:
```
$ sudo apt update
$ sudo apt install cups cups-bsd
$ sudo usermod -a -G lpadmin folk
```

ssh tunnel `ssh -L 6310:localhost:631 folk@folk0.local` run on your computer

go to http://localhost:6310 on your computer, go to Printers,
hopefully it shows up there automatically, try printing test page

if job is paused due to `cups-browsed` issue, try
https://askubuntu.com/questions/1128164/no-suitable-destination-host-found-by-cups-browsed :
remove `cups-browsed` `sudo apt-get purge --autoremove cups-browsed`
then add printer manually via IPP in CUPS Web UI (it might
automatically show up via dnssd)

once printer is working, go to Administration dropdown on printer page
and Set as Server Default

test `lpr folk-rsync/printed-programs/SOMETHING.pdf` (you have to
print the PDF and not the PS for it to work, probably)

## stuff

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
- with-all-matches

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
