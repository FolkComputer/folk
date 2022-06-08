AC_DEFUN([DC_SETUP_STABLE_API], [
	VERSIONSCRIPT="$1"
	SYMFILE="$2"

	DC_FIND_STRIP_AND_REMOVESYMS([$SYMFILE])
	DC_SETVERSIONSCRIPT([$VERSIONSCRIPT], [$SYMFILE])
])


AC_DEFUN([DC_SETVERSIONSCRIPT], [
	VERSIONSCRIPT="$1"
	SYMFILE="$2"
	TMPSYMFILE="${SYMFILE}.tmp"
	TMPVERSIONSCRIPT="${VERSIONSCRIPT}.tmp"

	echo "${SYMPREFIX}Test_Symbol" > "${TMPSYMFILE}"

	echo '{' > "${TMPVERSIONSCRIPT}"
	echo '	local:' >> "${TMPVERSIONSCRIPT}"
	echo "		${SYMPREFIX}Test_Symbol;" >> "${TMPVERSIONSCRIPT}"
	echo '};' >> "${TMPVERSIONSCRIPT}"

	SAVE_LDFLAGS="${LDFLAGS}"

	AC_MSG_CHECKING([for how to set version script])

	for tryaddldflags in "-Wl,--version-script,${TMPVERSIONSCRIPT}" "-Wl,-exported_symbols_list,${TMPSYMFILE}"; do
		LDFLAGS="${SAVE_LDFLAGS} ${tryaddldflags}"
		AC_TRY_LINK([void Test_Symbol(void) { return; }], [], [
			addldflags="`echo "${tryaddldflags}" | sed 's/\.tmp$//'`"

			break
		])
	done

	rm -f "${TMPSYMFILE}"
	rm -f "${TMPVERSIONSCRIPT}"

	LDFLAGS="${SAVE_LDFLAGS}"

	if test -n "${addldflags}"; then
		SHOBJLDFLAGS="${SHOBJLDFLAGS} ${addldflags}"

		AC_MSG_RESULT($addldflags)
	else
		AC_MSG_RESULT([don't know])
	fi

	AC_SUBST(SHOBJLDFLAGS)
])

AC_DEFUN([DC_FIND_STRIP_AND_REMOVESYMS], [
	SYMFILE="$1"

	dnl Determine how to strip executables
	AC_CHECK_TOOLS(OBJCOPY, objcopy gobjcopy, [false])
	AC_CHECK_TOOLS(STRIP, strip gstrip, [false])

	if test "x${STRIP}" = "xfalse"; then
		STRIP="${OBJCOPY}"
	fi

	WEAKENSYMS='true'
	REMOVESYMS='true'
	SYMPREFIX=''

	case $host_os in
		darwin*)
			SYMPREFIX="_"
			REMOVESYMS="${STRIP} -u -x"
			;;
		*)
			if test "x${OBJCOPY}" != "xfalse"; then
				WEAKENSYMS="${OBJCOPY} --keep-global-symbols=${SYMFILE}"
				REMOVESYMS="${OBJCOPY} --discard-all"
			elif test "x${STRIP}" != "xfalse"; then
				REMOVESYMS="${STRIP} -x"
			fi
			;;
	esac

	AC_SUBST(WEAKENSYMS)
	AC_SUBST(REMOVESYMS)
	AC_SUBST(SYMPREFIX)
])
