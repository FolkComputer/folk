folk-amd64.img: live-image-amd64.img
	./make-folk-amd64-img.sh

# You should manually clean if you change the /etc/skel contents.
live-image-amd64.img: # config/binary config/package-lists/folk.list.chroot
	sudo sh -c 'lb clean && lb config && lb build'
