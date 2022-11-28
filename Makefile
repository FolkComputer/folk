start:
	tclsh8.6 main.tcl
FOLK_SHARE_NODE := folk0.local
sync:
	rsync --update --timeout=1 -a folk@$(FOLK_SHARE_NODE):/home/folk/folk-rsync/printed-programs/ printed-programs
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

check-size:
	echo 'list [string length $$Statements::statements] [string length $$Statements::statementClauseToId]' | nc -w1 folk0.local 4273
