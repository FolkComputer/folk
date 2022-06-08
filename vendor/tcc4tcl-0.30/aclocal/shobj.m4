dnl Usage:
dnl    DC_TEST_SHOBJFLAGS(shobjflags, shobjldflags, action-if-not-found)
dnl
AC_DEFUN([DC_TEST_SHOBJFLAGS], [
  AC_SUBST(SHOBJFLAGS)
  AC_SUBST(SHOBJCPPFLAGS)
  AC_SUBST(SHOBJLDFLAGS)

  OLD_LDFLAGS="$LDFLAGS"
  OLD_CFLAGS="$CFLAGS"
  OLD_CPPFLAGS="$CPPFLAGS"

  SHOBJFLAGS=""
  SHOBJCPPFLAGS=""
  SHOBJLDFLAGS=""

  CFLAGS="$OLD_CFLAGS $1"
  CPPFLAGS="$OLD_CPPFLAGS $2"
  LDFLAGS="$OLD_LDFLAGS $3"

  AC_TRY_LINK([#include <stdio.h>
int unrestst(void);], [ printf("okay\n"); unrestst(); return(0); ], [ SHOBJFLAGS="$1"; SHOBJCPPFLAGS="$2"; SHOBJLDFLAGS="$3" ], [
    LDFLAGS="$OLD_LDFLAGS"
    CFLAGS="$OLD_CFLAGS"
    CPPFLAGS="$OLD_CPPFLAGS"
    $4
  ])

  LDFLAGS="$OLD_LDFLAGS"
  CFLAGS="$OLD_CFLAGS"
  CPPFLAGS="$OLD_CPPFLAGS"
])

AC_DEFUN([DC_GET_SHOBJFLAGS], [
  AC_SUBST(SHOBJFLAGS)
  AC_SUBST(SHOBJCPPFLAGS)
  AC_SUBST(SHOBJLDFLAGS)

  DC_CHK_OS_INFO

  AC_MSG_CHECKING(how to create shared objects)

  if test -z "$SHOBJFLAGS" -a -z "$SHOBJLDFLAGS" -a -z "$SHOBJCPPFLAGS"; then
    DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-shared], [
      DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-shared -mimpure-text], [
        DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-shared -rdynamic -Wl,-G,-z,textoff], [
          DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-shared -Wl,-G], [
            DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-shared -dynamiclib -flat_namespace -undefined suppress -bind_at_load], [
              DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-dynamiclib -flat_namespace -undefined suppress -bind_at_load], [
                DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-Wl,-dynamiclib -Wl,-flat_namespace -Wl,-undefined,suppress -Wl,-bind_at_load], [
                  DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-dynamiclib -flat_namespace -undefined suppress], [
                    DC_TEST_SHOBJFLAGS([-fPIC], [-DPIC], [-dynamiclib], [
                      AC_MSG_RESULT(cant)
                      AC_MSG_ERROR([We are unable to make shared objects.])
                    ])
                  ])
                ])
              ])
            ])
          ])
        ])
      ])
    ])
  fi

  AC_MSG_RESULT($SHOBJCPPFLAGS $SHOBJFLAGS $SHOBJLDFLAGS)

  DC_SYNC_SHLIBOBJS
])

AC_DEFUN([DC_SYNC_SHLIBOBJS], [
  AC_SUBST(SHLIBOBJS)
  SHLIBOBJS=""
  for obj in $LIB@&t@OBJS; do
    SHLIBOBJS="$SHLIBOBJS `echo $obj | sed 's/\.o$/_shr.o/g'`"
  done
])

AC_DEFUN([DC_SYNC_RPATH], [
	AC_ARG_ENABLE([rpath], AS_HELP_STRING([--disable-rpath], [disable setting of rpath]), [
		if test "$enableval" = 'no'; then
			set_rpath='no'
		else
			set_rpath='yes'
		fi
	], [
		if test "$cross_compiling" = 'yes'; then
			set_rpath='no'
		else
			ifelse($1, [], [
				set_rpath='yes'
			], [
				set_rpath='$1'
			])
		fi
	])

	if test "$set_rpath" = 'yes'; then
		OLD_LDFLAGS="$LDFLAGS"

		AC_CACHE_CHECK([how to set rpath], [rsk_cv_link_set_rpath], [
			AC_LANG_PUSH(C)
			for tryrpath in "-Wl,-rpath" "-Wl,--rpath" "-Wl,-R"; do
				LDFLAGS="$OLD_LDFLAGS $tryrpath -Wl,/tmp"
				AC_LINK_IFELSE([AC_LANG_PROGRAM([], [ return(0); ])], [
					rsk_cv_link_set_rpath="$tryrpath"
					break
				])
			done
			AC_LANG_POP(C)
			unset tryrpath
		])

		LDFLAGS="$OLD_LDFLAGS"
		unset OLD_LDFLAGS

		ADDLDFLAGS=""
		for opt in $LDFLAGS $LIBS; do
			if echo "$opt" | grep '^-L' >/dev/null; then
				rpathdir="`echo "$opt" | sed 's@^-L *@@'`"
				ADDLDFLAGS="$ADDLDFLAGS $rsk_cv_link_set_rpath -Wl,$rpathdir"
			fi
		done
		unset opt

		LDFLAGS="$LDFLAGS $ADDLDFLAGS"

		unset ADDLDFLAGS
	fi
])

AC_DEFUN([DC_CHK_OS_INFO], [
	AC_CANONICAL_HOST
	AC_SUBST(SHOBJEXT)
	AC_SUBST(SHOBJFLAGS)
	AC_SUBST(SHOBJCPPFLAGS)
	AC_SUBST(SHOBJLDFLAGS)
	AC_SUBST(CFLAGS)
	AC_SUBST(CPPFLAGS)
	AC_SUBST(AREXT)

	if test "$dc_cv_dc_chk_os_info_called" != '1'; then
		dc_cv_dc_chk_os_info_called='1'

		AC_MSG_CHECKING(host operating system)
		AC_MSG_RESULT($host_os)

		SHOBJEXT="so"
		AREXT="a"

		case $host_os in
			darwin*)
				SHOBJEXT="dylib"
				;;
			hpux*)
				case "$host_cpu" in
					ia64)
						SHOBJEXT="so"
						;;
					*)
						SHOBJEXT="sl"
						;;
				esac
				;;
			mingw32|mingw32msvc*)
				SHOBJEXT="dll"
				AREXT='lib'
				CFLAGS="$CFLAGS -mms-bitfields"
				CPPFLAGS="$CPPFLAGS -mms-bitfields"
				SHOBJCPPFLAGS="-DPIC"
				SHOBJLDFLAGS='-shared -Wl,--dll -Wl,--enable-auto-image-base -Wl,--output-def,$[@].def,--out-implib,$[@].a'
				;;
			msvc)
				SHOBJEXT="dll"
				AREXT='lib'
				CFLAGS="$CFLAGS -nologo"
				SHOBJCPPFLAGS='-DPIC'
				SHOBJLDFLAGS='/LD /LINK /NODEFAULTLIB:MSVCRT'
				;;
			cygwin*)
				SHOBJEXT="dll"
				SHOBJFLAGS="-fPIC"
				SHOBJCPPFLAGS="-DPIC"
				CFLAGS="$CFLAGS -mms-bitfields"
				CPPFLAGS="$CPPFLAGS -mms-bitfields"
				SHOBJLDFLAGS='-shared -Wl,--enable-auto-image-base -Wl,--output-def,$[@].def,--out-implib,$[@].a'
				;;
		esac
	fi
])

AC_DEFUN([SHOBJ_SET_SONAME], [
	SAVE_LDFLAGS="$LDFLAGS"

	AC_MSG_CHECKING([how to specify soname])

	for try in "-Wl,--soname,$1" "Wl,-install_name,$1" '__fail__'; do
		LDFLAGS="$SAVE_LDFLAGS"

		if test "${try}" = '__fail__'; then
			AC_MSG_RESULT([can't])

			break
		fi

		LDFLAGS="${LDFLAGS} ${try}"
		AC_TRY_LINK([void TestTest(void) { return; }], [], [
			LDFLAGS="${SAVE_LDFLAGS}"
			SHOBJLDFLAGS="${SHOBJLDFLAGS} ${try}"

			AC_MSG_RESULT([$try])

			break
		])
	done

	AC_SUBST(SHOBJLDFLAGS)
])

dnl $1 = Description to show user
dnl $2 = Libraries to link to
dnl $3 = Variable to update (optional; default LIBS)
dnl $4 = Action to run if found
dnl $5 = Action to run if not found
AC_DEFUN([SHOBJ_DO_STATIC_LINK_LIB], [
        ifelse($3, [], [
                define([VAR_TO_UPDATE], [LIBS])
        ], [
                define([VAR_TO_UPDATE], [$3])
        ])  


	AC_MSG_CHECKING([for how to statically link to $1])

	trylink_ADD_LDFLAGS=''
	for arg in $VAR_TO_UPDATE; do
		case "${arg}" in
			-L*)
				trylink_ADD_LDFLAGS="${arg}"
				;;
		esac
	done

	SAVELIBS="$LIBS"
	staticlib=""
	found="0"
	dnl HP/UX uses -Wl,-a,archive ... -Wl,-a,shared_archive
	dnl Linux and Solaris us -Wl,-Bstatic ... -Wl,-Bdynamic
	AC_LANG_PUSH([C])
	for trylink in "-Wl,-a,archive $2 -Wl,-a,shared_archive" "-Wl,-Bstatic $2 -Wl,-Bdynamic" "$2"; do
		if echo " ${LDFLAGS} " | grep ' -static ' >/dev/null; then
			if test "${trylink}" != "$2"; then
				continue
			fi
		fi

		LIBS="${SAVELIBS} ${trylink_ADD_LDFLAGS} ${trylink}"

		AC_LINK_IFELSE([AC_LANG_PROGRAM([], [])], [
			staticlib="${trylink}"
			found="1"

			break
		])
	done
	AC_LANG_POP([C])
	LIBS="${SAVELIBS}"

	if test "${found}" = "1"; then
		new_RESULT=''
		SAVERESULT="$VAR_TO_UPDATE"
		for lib in ${SAVERESULT}; do
			addlib='1'
			for removelib in $2; do
				if test "${lib}" = "${removelib}"; then
					addlib='0'
					break
				fi
			done

			if test "$addlib" = '1'; then
				new_RESULT="${new_RESULT} ${lib}"
			fi
		done
		VAR_TO_UPDATE="${new_RESULT} ${staticlib}"

		AC_MSG_RESULT([${staticlib}])

		$4
	else
		AC_MSG_RESULT([cant])

		$5
	fi
])

