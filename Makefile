TCL_HOME := /opt/homebrew/Cellar/tcl-tk/8.6*
ifeq ($(wildcard $(TCL_HOME)/*),)
	TCL_HOME := /usr/local/Cellar/tcl-tk/8.6*
endif
ifeq ($(wildcard $(TCL_HOME)/*),)
	TCL_HOME := /usr
endif
run:
	$(TCL_HOME)/bin/tclsh main.tcl

TCLKIT = ~/Downloads/tclkit-8.6.3*
Folk.app:
	rm -r /tmp/folk.vfs; mkdir /tmp/folk.vfs
	cp -r * /tmp/folk.vfs
	cd /tmp; tclsh ~/Downloads/sdx*kit wrap folk -runtime $(TCLKIT)

NODE := localhost
show-statements:
	echo showStatements | nc -w 1 $(NODE) 4273
show-whens:
	echo showWhens | nc -w 1 $(NODE) 4273
show-statements-trie:
	echo showStatementsTrie | nc -w 1 $(NODE) 4273 | dot -Tpdf > statements-trie.pdf
