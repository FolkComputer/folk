TCL_HOME := /opt/homebrew/Cellar/tcl-tk/8.6*
ifeq ($(wildcard $(TCL_HOME)/*),)
	TCL_HOME := /usr/local/Cellar/tcl-tk/8.6*
else ifeq ($(wildcard $(TCL_HOME)/*),)
	TCL_HOME := /usr
endif
run:
	$(TCL_HOME)/bin/tclsh folk.tcl
