start:
	tclsh8.6 main.tcl
FOLK_SHARE_NODE := folk0.local
sync:
	 rsync --delete --timeout=1 -e "ssh -o StrictHostKeyChecking=no" -a . folk@$(FOLK_SHARE_NODE):/home/folk/folk-rsync

TCLKIT = ~/Downloads/tclkit-8.6.3*
Folk.app:
	rm -r /tmp/folk.vfs; mkdir /tmp/folk.vfs
	cp -r * /tmp/folk.vfs
	cd /tmp; tclsh ~/Downloads/sdx*kit wrap folk -runtime $(TCLKIT)

NODE := localhost
show-statements:
	echo Statements::dot | nc -w 5 $(NODE) 4273 | dot -Tpdf > statements.pdf
show-trie:
	echo 'trie dot [set Statements::statementClauseToId]' | nc -w 5 $(NODE) 4273 | dot -Tpdf > trie.pdf

assert-tags:
	echo 'set ::debug true; Assert camera claims tag 1 has center {400 400} size {100} with generation 0; Assert camera claims tag 2 has center {200 200} size {100} with generation 0; Step; set ::debug false; set ::stepTime' | nc -w1 folk0.local 4273
retract-tags:
	echo 'Retract camera claims tag 1 has center {400 400} size {100} with generation 0; Retract camera claims tag 2 has center {200 200} size {100} with generation 0; Step; set ::stepTime' | nc -w1 folk0.local 4273

check-size:
	echo 'list [string length $$Statements::statements] [string length $$Statements::statementClauseToId]' | nc -w1 folk0.local 4273
