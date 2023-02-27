start:
	tclsh8.6 main.tcl
FOLK_SHARE_NODE := $(shell tclsh8.6 hosts.tcl shareNode)
sync:
	rsync --delete --timeout=1 -e "ssh -o StrictHostKeyChecking=no" -a . folk@$(FOLK_SHARE_NODE):/home/folk/folk

.PHONY: test
test:
	for testfile in test/*.tcl; do echo; echo $${testfile}; echo --------; make FOLK_ENTRY=$${testfile}; done

repl:
	tclsh8.6 replmain.tcl

journal:
	ssh folk@$(FOLK_SHARE_NODE) -- journalctl -f -n 100 -u folk

backup-printed-programs:
	tar -zcvf ~/"folk-printed-programs_$(shell date '+%Y-%m-%d_%H-%M-%S%z').tar.gz" ~/folk-printed-programs
