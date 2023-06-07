# Setup notes

## Useful for configuring the webcam

```
# List devices and their controls
v4l2-ctl --list-devices
v4l2-ctl --list-ctrls-menus

# Manual focus
v4l2-ctl -d /dev/video0 --set-ctrl=focus_auto=0  # default=1
v4l2-ctl -d /dev/video0 --set-ctrl=focus_absolute=0

# Manual light exposure controls
v4l2-ctl -d /dev/video0 --set-ctrl=exposure_auto=1  # default=3 (Aperture Priority Mode)
v4l2-ctl -d /dev/video0 --set-ctrl=exposure_absolute=166  # min=12 max=664 default=166

# Brightness and other useful controls
v4l2-ctl -d /dev/video0 --set-ctrl=sharpness=170  # default=128
v4l2-ctl -d /dev/video0 --set-ctrl=brightness=150  # default=128
v4l2-ctl -d /dev/video0 --set-ctrl=backlight_compensation=1  # default=0
```
