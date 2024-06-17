start:
	case "$(shell hostname)" in \
	gadget-*) \
		libcamerify tclsh8.6 main.tcl;; \
	*) \
		tclsh8.6 main.tcl;; \
	esac
debug:
	gdb --args tclsh8.6 main.tcl
remote-debug: sync
	ssh -tt folk@$(FOLK_SHARE_NODE) -- 'sudo systemctl stop folk && make -C /home/folk/folk debug'

FOLK_SHARE_NODE := $(shell tclsh8.6 hosts.tcl shareNode)

sync:
	rsync --delete --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . folk@$(FOLK_SHARE_NODE):/home/folk/folk

sync-restart: sync
	ssh -tt folk@$(FOLK_SHARE_NODE) -- 'sudo systemctl restart folk'

test:
	for testfile in test/*.tcl; do echo; echo $${testfile}; echo --------; make FOLK_ENTRY=$${testfile}; done

test/%.debug:
	FOLK_ENTRY=test/$*.tcl lldb -- tclsh8.6 main.tcl

test/%:
	make FOLK_ENTRY=$@.tcl

repl:
	tclsh8.6 replmain.tcl

journal:
	ssh folk@$(FOLK_SHARE_NODE) -- journalctl -f -n 100 -u folk

ssh:
	ssh folk@$(FOLK_SHARE_NODE)

FLAMEGRAPH_TID := $(shell pgrep tclsh8.6 | head -1)
flamegraph:
	sudo perf record -F 997 --tid=$(FLAMEGRAPH_TID) -g -- sleep 30
	sudo perf script -f > out.perf
	~/FlameGraph/stackcollapse-perf.pl out.perf > out.folded
	~/FlameGraph/flamegraph.pl out.folded > out.svg

# You can use the Web server to check the pid of display.folk,
# apriltags.folk, camera.folk, etc.
remote-flamegraph:
	ssh -t folk@$(FOLK_SHARE_NODE) -- make -C /home/folk/folk flamegraph $(if $(REMOTE_FLAMEGRAPH_TID),FLAMEGRAPH_TID=$(REMOTE_FLAMEGRAPH_TID),)
	scp folk@$(FOLK_SHARE_NODE):~/folk/out.svg .
	scp folk@$(FOLK_SHARE_NODE):~/folk/out.perf .

backup-printed-programs:
	cd ~/folk-printed-programs && timestamp=$$(date '+%Y-%m-%d_%H-%M-%S%z') && tar -zcvf ~/"folk-printed-programs_$$timestamp.tar.gz" . && echo "Saved to: ~/folk-printed-programs_$$timestamp.tar.gz"

calibrate:
	tclsh8.6 calibrate.tcl
calibrate-debug:
	gdb --args tclsh8.6 calibrate.tcl
remote-calibrate: sync
	ssh folk@$(FOLK_SHARE_NODE) -- make -C /home/folk/folk calibrate
remote-calibrate-debug: sync
	ssh folk@$(FOLK_SHARE_NODE) -- make -C /home/folk/folk calibrate-debug

.PHONY: test sync start journal repl calibrate remote-calibrate enable-pubkey install-deps

enable-pubkey:
	ssh folk-live -- 'sudo sed -i "s/.*PubkeyAuthentication.*/PubkeyAuthentication yes/g" /etc/ssh/sshd_config && sudo systemctl restart ssh'
	sleep 1
	ssh-copy-id folk-live

install-deps:
	sudo apt remove libtcl8.6 || true
	sudo apt install console-data

	cd ~ && \
		curl -O https://netactuate.dl.sourceforge.net/project/tcl/Tcl/8.6.14/tcl8.6.14-src.tar.gz?viasf=1 && \
		curl -O https://core.tcl-lang.org/tcllib/uv/tcllib-1.21.tar.gz && \
		curl -o VecTcl-0.2.tar.gz https://codeload.github.com/auriocus/VecTcl/tar.gz/refs/tags/v0.2 && \
		tar xfz tcl8.6.14-src.tar.gz && \
		tar xfz tcllib-1.21.tar.gz && \
		tar xfz VecTcl-0.2.tar.gz && \
		rm tcl8.6.14-src.tar.gz tcllib-1.21.tar.gz VecTcl-0.2.tar.gz

	cd ~/tcl8.6.14 && \
		patch -p1 < ../VecTcl-0.2/tcl86_vectcl.patch && \
		cd unix && \
		./configure --enable-symbols && \
		make -j2 && \
		sudo make install

	cd ~/tcl8.6.14 && \
		ln -s ~/tcllib-1.21/modules/textutil library/textutil && \
		ln -s ~/tcllib-1.21/modules/fileutil library/fileutil && \
		ln -s ~/tcllib-1.21/modules/cmdline library/cmdline

	cd ~/VecTcl-0.2 && \
		./configure --enable-listpatch && \
		make -j2 && \
		sudo make install
