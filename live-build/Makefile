folk-amd64.img: live-image-amd64.img
	./make-folk-amd64-img.sh $< $@

live-image-amd64.img:
	sudo sh -c 'lb clean && lb config && lb build'

clean:
	rm -f folk-amd64.img live-image-amd64.img
