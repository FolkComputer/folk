detect: detect.c
	cc detect.c -I/home/pi/apriltag -L/home/pi/apriltag -lapriltag -lm -lpthread -o detect

run-detect: detect
	LD_LIBRARY_PATH=/home/pi/apriltag ./detect
