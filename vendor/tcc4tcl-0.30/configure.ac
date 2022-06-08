dnl Define ourselves
AC_INIT(tcc4tcl, 0.30)

dnl Default prefix should be "UNSPECIFIED" to use magic in the Makefile
ac_default_prefix="UNSPECIFIED"

dnl Checks for programs.
AC_PROG_CC
AC_PROG_CPP
AC_PROG_MAKE_SET
AC_PROG_INSTALL
AC_GNU_SOURCE
AC_LANG(C)

dnl Determine system information
DC_CHK_OS_INFO

dnl Perform Tcl Extension required stuff
TCLEXT_INIT

dnl Determine if a shared or static build is requested
TCC4TCL_TARGET="${TCLEXT_BUILD}"

dnl Configure TCC build options
AC_SUBST(TCC_CONFIGURE_OPTS)
TCC_CONFIGURE_OPTS=""

if test "${TCC4TCL_TARGET}" = "shared"; then
	dnl Determine how to make shared objects
	DC_GET_SHOBJFLAGS

	dnl Only export symbols we wish to expose
	TARGET="tcc4tcl.${SHOBJEXT}"
else
	TCC_EXTRA_CFLAGS="${TCC_EXTRA_CFLAGS} -DCONFIG_TCC_STATIC=1"

	AC_CHECK_TOOL([RANLIB], [ranlib])
	AC_CHECK_TOOL([AR], [ar])

	TARGET="tcc4tcl-static.a"
fi
AC_SUBST(TARGET)
AC_SUBST(TCC4TCL_TARGET)
AC_SUBST(TCC_EXTRA_CFLAGS)

dnl -- If cross-compiling, specify a "--cross-prefix" and define the CPU
if test "${host}" != "${build}"; then
	cross_prefix="`echo "${AR}" | sed 's@ .*$@@;s@^ar$@@;s@-ar$@@'`"
	if test -z "${cross_prefix}"; then
		cross_prefix="`echo "${CC}" | sed 's@ .*$@@;s@^[[^-]]*$@@;s@-[[^-]]*$@@'`"
	fi
	if test -z "${cross_prefix}"; then
		cross_prefix="${host_alias}"
	fi

	TCC_CONFIGURE_OPTS="${TCC_CONFIGURE_OPTS} --cross-prefix=${cross_prefix}- --cpu=${host_cpu} --os=${host_os}"
fi

no_dlopen='0'
AC_ARG_WITH([dlopen], AS_HELP_STRING([--without-dlopen], [do not define dlopen/dlclose/dlerror]), [
	if test "$withval" = "no"; then
		no_dlopen='1'
	else
		no_dlopen='0'
	fi
])

if test "$no_dlopen" = '1'; then
	CPPFLAGS="${CPPFLAGS} -DCONFIG_TCC_STATIC_NODLOPEN=1"
fi

dnl Determine if the compiler supports -Wno-unused-result
AC_CACHE_CHECK([if compiler supports -Wno-unused-result], [tcc4tcl_cv_compiler_wno_unused_result], [
	SAVE_CFLAGS="${CFLAGS}"
	CFLAGS="${SAVE_CFLAGS} -Wno-unused-result"
	AC_COMPILE_IFELSE([AC_LANG_SOURCE()], [
		tcc4tcl_cv_compiler_wno_unused_result='yes'
	], [
		tcc4tcl_cv_compiler_wno_unused_result='no'
	])
	CFLAGS="${SAVE_CFLAGS}"
])

if test "$tcc4tcl_cv_compiler_wno_unused_result" = 'yes'; then
	TCC_WNO_UNUSED_RESULT='-Wno-unused-result'
else
	TCC_WNO_UNUSED_RESULT=''
fi
AC_SUBST(TCC_WNO_UNUSED_RESULT)

dnl Determine HOST_PATH_SEPERATOR
case $host_os in
	*mingw*)
		HOST_PATH_SEPARATOR=';'
		;;
	*)
		HOST_PATH_SEPARATOR=':'
		;;
esac
AC_SUBST(HOST_PATH_SEPARATOR)

dnl Find a suitable awk
AC_CHECK_TOOLS(AWK, gawk awk, [false])

dnl This must be done last since it breaks the compilation
if test "${TCC4TCL_TARGET}" = "shared"; then
	DC_SETUP_STABLE_API([${srcdir}/tcc4tcl.vers], [tcc4tcl.syms])
fi

dnl Produce output
AC_OUTPUT(Makefile pkgIndex.tcl tcc4tcl.syms tcc/Makefile)
