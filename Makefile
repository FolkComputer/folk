start:
	tclsh8.6 main.tcl

FOLK_SHARE_NODE := $(shell tclsh8.6 hosts.tcl shareNode)

sync:
	rsync --delete --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . folk@$(FOLK_SHARE_NODE):/home/folk/folk

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

flamegraph:
	sudo perf record -F 997 --tid=$(shell pgrep tclsh8.6) -g -- sleep 30
	sudo perf script -f > out.perf
	~/FlameGraph/stackcollapse-perf.pl out.perf > out.folded
	~/FlameGraph/flamegraph.pl out.folded > out.svg

remote-flamegraph:
	ssh -t folk@$(FOLK_SHARE_NODE) -- make -C /home/folk/folk flamegraph
	scp folk@$(FOLK_SHARE_NODE):~/folk/out.svg .

backup-printed-programs:
	cd ~/folk-printed-programs && timestamp=$$(date '+%Y-%m-%d_%H-%M-%S%z') && tar -zcvf ~/"folk-printed-programs_$$timestamp.tar.gz" . && echo "Saved to: ~/folk-printed-programs_$$timestamp.tar.gz"

calibrate:
	tclsh8.6 calibrate.tcl

remote-calibrate: sync
	ssh folk@$(FOLK_SHARE_NODE) -- make -C /home/folk/folk calibrate

.PHONY: test sync start journal repl calibrate remote-calibrate
