folk-amd64.hybrid.iso: live-image-amd64.hybrid.iso
	./make-folk-amd64-hybrid-iso.sh $< $@

live-image-amd64.hybrid.iso:
	sudo sh -c 'lb clean && lb config && lb build'
