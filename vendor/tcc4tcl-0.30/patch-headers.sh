#! /usr/bin/env bash

headers_dir="$1"

cd "${headers_dir}" || exit 1

# Android header fix-ups
## Do not abort compilation at header include time
if grep '^#error "No function renaming possible"' sys/cdefs.h >/dev/null 2>/dev/null; then
	awk '
/^#error "No function renaming possible"/{
	print "#define __RENAME(x) no renaming on this platform"
	next
}
{print}

/^#warning /{ next }
	' sys/cdefs.h > sys/cdefs.h.new
	rm -f sys/cdefs.h
	cat sys/cdefs.h.new > sys/cdefs.h
	rm -f sys/cdefs.h.new
fi

## loff_t depends on __GNUC__ for some reason
if awk -v retval=1 '/__GNUC__/{ getline; if ($0 ~ /__kernel_loff_t/) {retval=0} } END{exit retval}' asm/posix_types.h >/dev/null 2>/dev/null; then
	awk '/__GNUC__/{ getline; if ($0 ~ /__kernel_loff_t/) { print "#if 1"; print; next } } { print }' asm/posix_types.h > asm/posix_types.h.new
	rm -f asm/posix_types.h
	cat asm/posix_types.h.new > asm/posix_types.h
	rm -f asm/posix_types.h.new
fi

# Busted wrapper fix-up
if grep '__STDC_HOSTED__' stdint.h >/dev/null 2>/dev/null && grep '_GCC_WRAP_STDINT_H' stdint.h >/dev/null 2>/dev/null; then
	echo '#include_next <stdint.h>' > stdint.h
fi

if grep '__CLANG_LIMITS_H' limits.h >/dev/null 2>/dev/null; then
	echo '#include_next <limits.h>' > limits.h
fi

# MUSL libc expects GCC (bits/alltypes.h)
# FreeBSD expects some GCCisms (x86/_types.h)
for file in bits/alltypes.h x86/_types.h; do
	if grep '[[:space:]]__builtin_va_list[[:space:]]' "${file}" >/dev/null 2>/dev/null; then
		sed 's@[[:space:]]__builtin_va_list[[:space:]]@ char * @' "${file}" > "${file}.new"
		rm -f "${file}"
		cat "${file}.new" > "${file}"
		rm -f "${file}.new"
	fi
done

if grep __GNUCLIKE_BUILTIN_VARARGS x86/_types.h >/dev/null 2>/dev/null; then
	sed '/__GNUCLIKE_BUILTIN_VARARGS/ {h;s/.*/typedef char * __va_list;/;p;g;}' x86/_types.h > x86/_types.h.new
	rm -f x86/_types.h
	cat x86/_types.h.new > x86/_types.h
	rm -f x86/_types.h.new
fi
