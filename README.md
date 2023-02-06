# folk

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

We intend to release this repo as open-source under an MIT, GPLv3, or
AGPLv3 license by June 2023 or earlier; by contributing code, you're
also agreeing to license your code under whichever license we end up
choosing.

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

## FFT example

- Including [kissfft](https://github.com/mborgerding/kissfft)

``` tcl
Wish $this has filename "fft.folk"
Wish $this is outlined thick magenta
# bring in RGB image, display its FFT


set cc [c create]

# if Laptop:
# try .dylib, .so, fail

try {
    c loadlib $::env(HOME)/code/kissfft/libkissfft-float.dylib
    $cc cflags -I$::env(HOME)/code/kissfft -Wall -Werror
    # ...
} on error {} {
  try {
    # load .so
    c loadlib $::env(HOME)/kissfft/libkissfft-float.so
    $cc cflags -I$::env(HOME)/kissfft -Wall -Werror
  } on error {} {
    # bail completely
    return
  }
}

source "pi/cUtils.tcl"
# if NUC:
# ---- libkissfft-float.so
defineImageType $cc

$cc proc test {} void {
  printf("hello world :-)\n");
}

$cc include <stdlib.h>
$cc include <string.h>
$cc include <kiss_fftnd.h>
$cc proc bw {image_t im} image_t {
	image_t ret;
	ret.width = im.width;
	ret.height = im.height;
	ret.components = 3;
	ret.bytesPerRow = ret.width * ret.components;
	ret.data = calloc(ret.bytesPerRow, ret.height);
        
        # TODO -- @cwervo
        # use kiss_fft to get fft for ret.data ...
        # probably want a 2D array of floating point numbers
        # call kissfft to construct a plan
        # using plan + fft, get fft image & convert complex float 2D array -> RGB
	for (uint32_t y = 0; y < im.height; ++y) {
		int R = 0; int G = 1; int B = 2;
		for (uint32_t x = 0; x < im.width; ++x) {
			int i = y * ret.bytesPerRow + x * ret.components;
			int j = y * im.bytesPerRow + x * im.components;
			ret.data[i + 0] = im.data[j + R];
			ret.data[i + 1] = im.data[j + G];
			ret.data[i + 2] = im.data[j + B];
		}		
	}

	return ret;
}
$cc proc freeImage {image_t im} void { free(im.data); }
$cc compile

Wish $this has camera image
When $this has camera image /im/ {
	When $this has region /r/ {
		set bwim [bw $im]
		Wish display runs [list Display::image {*}[lindex $r 0 0] $bwim]
		On unmatch [list freeImage $bwim]
	}
}
```
