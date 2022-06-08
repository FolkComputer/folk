dnl Tcl M4 Routines

dnl Find a runnable Tcl
AC_DEFUN([TCLEXT_FIND_TCLSH_PROG], [
	AC_CACHE_CHECK([for runnable tclsh], [tcl_cv_tclsh_native_path], [
		dnl Try to find a runnable tclsh
		if test -z "$TCLCONFIGPATH"; then
			TCLCONFIGPATH=/dev/null/null
		fi

		for try_tclsh in "$TCLSH_NATIVE" "$TCLCONFIGPATH/../bin/tclsh" \
		                 "$TCLCONFIGPATH/../bin/tclsh8.6" \
		                 "$TCLCONFIGPATH/../bin/tclsh8.5" \
		                 "$TCLCONFIGPATH/../bin/tclsh8.4" \
		                 `which tclsh 2>/dev/null` \
		                 `which tclsh8.6 2>/dev/null` \
		                 `which tclsh8.5 2>/dev/null` \
		                 `which tclsh8.4 2>/dev/null` \
		                 tclsh; do
			if test -z "$try_tclsh"; then
				continue
			fi
			if test -x "$try_tclsh"; then
				if echo 'exit 0' | "$try_tclsh" 2>/dev/null >/dev/null; then
					tcl_cv_tclsh_native_path="$try_tclsh"

					break
				fi
			fi
		done

		if test "$TCLCONFIGPATH" = '/dev/null/null'; then
			unset TCLCONFIGPATH
		fi
	])

	TCLSH_PROG="${tcl_cv_tclsh_native_path}"
	AC_SUBST(TCLSH_PROG)
])


dnl Must call AC_CANONICAL_HOST  before calling us
AC_DEFUN([TCLEXT_FIND_TCLCONFIG], [

	TCLCONFIGPATH=""
	AC_ARG_WITH([tcl], AS_HELP_STRING([--with-tcl], [directory containing tcl configuration (tclConfig.sh)]), [
		if test "x$withval" = "xno"; then
			AC_MSG_ERROR([cant build without tcl])
		fi

		TCLCONFIGPATH="$withval"
	], [
		if test "$cross_compiling" = 'no'; then
			TCLEXT_FIND_TCLSH_PROG
			tclConfigCheckDir0="`echo 'puts [[tcl::pkgconfig get libdir,runtime]]' | "$TCLSH_PROG" 2>/dev/null`"
			tclConfigCheckDir1="`echo 'puts [[tcl::pkgconfig get scriptdir,runtime]]' | "$TCLSH_PROG" 2>/dev/null`"
		else
			tclConfigCheckDir0=/dev/null/null
			tclConfigCheckDir1=/dev/null/null
		fi

		if test "$cross_compiling" = 'no'; then
			dirs="/usr/$host_alias/lib /usr/lib /usr/lib64 /usr/local/lib /usr/local/lib64"
		else
			dirs=''
		fi

		for dir in "$tclConfigCheckDir0" "$tclConfigCheckDir1" $dirs; do
			if test -f "$dir/tclConfig.sh"; then
				TCLCONFIGPATH="$dir"

				break
			fi
		done
	])

	AC_MSG_CHECKING([for path to tclConfig.sh])

	if test -z "$TCLCONFIGPATH"; then
		AC_MSG_ERROR([unable to locate tclConfig.sh.  Try --with-tcl.])
	fi

	AC_SUBST(TCLCONFIGPATH)

	AC_MSG_RESULT([$TCLCONFIGPATH])

	dnl Find Tcl if we haven't already
	if test -z "$TCLSH_PROG"; then
		TCLEXT_FIND_TCLSH_PROG
	fi
])

dnl Must define TCLCONFIGPATH before calling us (i.e., by TCLEXT_FIND_TCLCONFIG)
AC_DEFUN([TCLEXT_LOAD_TCLCONFIG], [
	AC_MSG_CHECKING([for working tclConfig.sh])

	if test -f "$TCLCONFIGPATH/tclConfig.sh"; then
		. "$TCLCONFIGPATH/tclConfig.sh"
	else
		AC_MSG_ERROR([unable to load tclConfig.sh])
	fi


	AC_MSG_RESULT([found])
])

AC_DEFUN([TCLEXT_INIT], [
	AC_CANONICAL_HOST

	TCLEXT_FIND_TCLCONFIG
	TCLEXT_LOAD_TCLCONFIG

	AC_DEFINE_UNQUOTED([MODULE_SCOPE], [static], [Define how to declare a function should only be visible to the current module])

	TCLEXT_BUILD='shared'
	AC_ARG_ENABLE([shared], AS_HELP_STRING([--disable-shared], [disable the shared build (same as --enable-static)]), [
		if test "$enableval" = "no"; then
			TCLEXT_BUILD='static'
			TCL_SUPPORTS_STUBS=0
		fi
	])

	AC_ARG_ENABLE([static], AS_HELP_STRING([--enable-static], [enable a static build]), [
		if test "$enableval" = "yes"; then
			TCLEXT_BUILD='static'
			TCL_SUPPORTS_STUBS=0
		fi
	])

	AC_ARG_ENABLE([stubs], AS_HELP_STRING([--disable-stubs], [disable use of Tcl stubs]), [
		if test "$enableval" = "no"; then
			TCL_SUPPORTS_STUBS=0
		else
			TCL_SUPPORTS_STUBS=1
		fi
	])

	if test "$TCL_SUPPORTS_STUBS" = "1"; then
		AC_DEFINE([USE_TCL_STUBS], [1], [Define if you are using the Tcl Stubs Mechanism])

		TCL_STUB_LIB_SPEC="`eval echo "${TCL_STUB_LIB_SPEC}"`"
		LIBS="${LIBS} ${TCL_STUB_LIB_SPEC}"
	else
		TCL_LIB_SPEC="`eval echo "${TCL_LIB_SPEC}"`"
		LIBS="${LIBS} ${TCL_LIB_SPEC}"
	fi

	TCL_INCLUDE_SPEC="`eval echo "${TCL_INCLUDE_SPEC}"`"

	CFLAGS="${CFLAGS} ${TCL_INCLUDE_SPEC}"
	CPPFLAGS="${CPPFLAGS} ${TCL_INCLUDE_SPEC}"
	TCL_DEFS_TCL_ONLY=`(
		eval "set -- ${TCL_DEFS}"
		for flag in "[$]@"; do
			case "${flag}" in
				-DTCL_*)
					echo "${flag}" | sed "s/'/'\\''/g" | sed "s@^@'@;s@"'[$]'"@'@" | tr $'\n' ' '
					;;
			esac
		done
	)`
	TCL_DEFS="${TCL_DEFS_TCL_ONLY}"
	AC_SUBST(TCL_DEFS)

	dnl Needed for package installation
	if test "$prefix" = 'NONE' -a "$exec_prefix" = 'NONE' -a "${libdir}" = '${exec_prefix}/lib'; then
		TCL_PACKAGE_PATH="`echo "${TCL_PACKAGE_PATH}" | sed 's@  *$''@@' | awk '{ print [$]1 }'`"
	else
		TCL_PACKAGE_PATH='${libdir}'
	fi
	AC_SUBST(TCL_PACKAGE_PATH)

	AC_SUBST(LIBS)
])
