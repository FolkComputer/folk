IMG_FILENAME := folk-$(shell date -I)-$(shell git rev-parse HEAD | head -c 7)-live-amd64.img

$(IMG_FILENAME).zip: $(IMG_FILENAME)
	 zip $@ $<

$(IMG_FILENAME): live-image-amd64.img
	./make-folk-amd64-img.sh $< $@

live-image-amd64.img:
	sudo sh -c 'lb clean && lb config && lb build'

clean:
	rm -f *amd64.img
