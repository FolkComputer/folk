folk-amd64.hybrid.iso: live-image-amd64.hybrid.iso
	./make-folk-amd64-hybrid-iso.sh $< $@

# You should manually clean if you change the /etc/skel contents.
live-image-amd64.hybrid.iso: config/binary config/package-lists/folk.list.chroot
	sudo sh -c 'lb clean && lb config && lb build'
