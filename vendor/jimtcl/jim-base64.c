/*
 * Tcl-compatible binary encode/decode base64 commands.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE JIM TCL PROJECT ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * JIM TCL PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * The views and conclusions contained in the software and documentation
 * are those of the authors and should not be interpreted as representing
 * official policies, either expressed or implied, of the Jim Tcl Project.
 *
 * Based on code originally from Tcl 8.6:
 *
 * Copyright (c) 1997 Sun Microsystems, Inc.
 * Copyright (c) 1998-1999 Scriptics Corporation.
 *
 * See the file "tcl.license.terms" for information on usage and redistribution of
 * this file, and for a DISCLAIMER OF ALL WARRANTIES.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <jim.h>
#include <jimautoconf.h>

static const char B64Digits[65] = {
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H',
    'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
    'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
    'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n',
    'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', '0', '1', '2', '3',
    '4', '5', '6', '7', '8', '9', '+', '/',
    '='
};

/*
 *----------------------------------------------------------------------
 *
 * BinaryEncode64 --
 *
 *	This procedure implements the "binary encode base64" Tcl command.
 *
 * Results:
 *	The base64 encoded value prescribed by the input arguments.
 *
 *----------------------------------------------------------------------
 */

#define OUTPUT(c) \
    do {						\
	*cursor++ = (c);				\
	outindex++;					\
	if (maxlen > 0 && cursor != limit) {		\
	    if (outindex == maxlen) {			\
		memcpy(cursor, wrapchar, wrapcharlen);	\
		cursor += wrapcharlen;			\
		outindex = 0;				\
	    }						\
	}						\
	if (cursor > limit) {				\
	    Jim_SetResultString(interp, "limit hit", -1);			\
            return JIM_ERR; \
	}						\
    } while (0)

static int
BinaryEncode64(
    Jim_Interp *interp,
    int objc,
    Jim_Obj *const objv[])
{
    Jim_Obj *resultObj;
    const unsigned char *data, *limit;
    jim_wide maxlen = 0;
    const char *wrapchar = "\n";
    int wrapcharlen = 1;
    int index, purewrap = 1;
    int i, offset, size, outindex = 0, count = 0;
    enum { OPT_MAXLEN, OPT_WRAPCHAR };
    static const char *const optStrings[] = { "-maxlen", "-wrapchar", NULL };

    if (objc < 2 || objc % 2 != 0) {
	Jim_WrongNumArgs(interp, 1, objv,
		"?-maxlen len? ?-wrapchar char? data");
	return JIM_ERR;
    }
    for (i = 1; i < objc - 1; i += 2) {
	if (Jim_GetEnum(interp, objv[i], optStrings, &index, "option",
		0) != JIM_OK) {
	    return JIM_ERR;
	}
	switch (index) {
	case OPT_MAXLEN:
	    if (Jim_GetWide(interp, objv[i + 1], &maxlen) != JIM_OK) {
		return JIM_ERR;
	    }
	    if (maxlen < 0) {
		Jim_SetResult(interp, Jim_NewStringObj(interp,
			"line length out of range", -1));
		/* Jim_SetErrorCode(interp, "TCL", "BINARY", "ENCODE", */
		/* 	"LINE_LENGTH", (char *)NULL); */
		return JIM_ERR;
	    }
	    break;
	case OPT_WRAPCHAR:
            // FIXME (osnr): This is weird
	    wrapchar = (const char *)Jim_GetString(
		    objv[i + 1], &wrapcharlen);
	    if (wrapchar == NULL) {
		purewrap = 0;
		wrapchar = Jim_GetString(objv[i + 1], &wrapcharlen);
	    }
	    break;
	}
    }
    if (wrapcharlen == 0) {
	maxlen = 0;
    }

    data = (const unsigned char *)Jim_GetString(objv[objc - 1], &count);
    if (data == NULL) {
	return JIM_ERR;
    }
    resultObj = Jim_NewObj(interp);
    resultObj->typePtr = NULL;
    if (count > 0) {
	unsigned char *cursor = NULL;

	size = (((count * 4) / 3) + 3) & ~3;	/* ensure 4 byte chunks */
	if (maxlen > 0 && size > maxlen) {
	    int adjusted = size + (wrapcharlen * (size / maxlen));

	    if (size % maxlen == 0) {
		adjusted -= wrapcharlen;
	    }
	    size = adjusted;

	    if (purewrap == 0) {
		/* Wrapchar is (possibly) non-byte, so build result as
		 * general string, not bytearray */
		resultObj->bytes = Jim_Alloc(size);
                resultObj->length = size;
		cursor = (unsigned char *) resultObj->bytes;
	    }
	}
	if (cursor == NULL) {
            resultObj->bytes = Jim_Alloc(size);
            resultObj->length = size;
            cursor = (unsigned char *) resultObj->bytes;
	}
	limit = cursor + size;
	for (offset = 0; offset < count; offset += 3) {
	    unsigned char d[3] = {0, 0, 0};

	    for (i = 0; i < 3 && offset + i < count; ++i) {
		d[i] = data[offset + i];
	    }
	    OUTPUT(B64Digits[d[0] >> 2]);
	    OUTPUT(B64Digits[((d[0] & 0x03) << 4) | (d[1] >> 4)]);
	    if (offset + 1 < count) {
		OUTPUT(B64Digits[((d[1] & 0x0F) << 2) | (d[2] >> 6)]);
	    } else {
		OUTPUT(B64Digits[64]);
	    }
	    if (offset+2 < count) {
		OUTPUT(B64Digits[d[2] & 0x3F]);
	    } else {
		OUTPUT(B64Digits[64]);
	    }
	}
    }
    Jim_SetResult(interp, resultObj);
    return JIM_OK;
}
#undef OUTPUT


/*
 *----------------------------------------------------------------------
 *
 * BinaryDecode64 --
 *
 *	Decode a base64 encoded string.
 *
 * Results:
 *	Interp result set to an byte array object
 *
 * Side effects:
 *	None
 *
 *----------------------------------------------------------------------
 */

static int
BinaryDecode64(
    Jim_Interp *interp,
    int objc,
    Jim_Obj *const objv[])
{
    Jim_Obj *resultObj = NULL;
    unsigned char *data, *datastart, *dataend, c = '\0';
    unsigned char *begin = NULL;
    unsigned char *cursor = NULL;
    int strict = 0;
    int i, index, cut = 0;
    int size, count = 0;
    int ucs4;
    enum { OPT_STRICT };
    static const char *const optStrings[] = { "-strict", NULL };

    if (objc < 2 || objc > 3) {
	Jim_WrongNumArgs(interp, 1, objv, "?options? data");
	return JIM_ERR;
    }
    for (i = 1; i < objc - 1; ++i) {
	if (Jim_GetEnum(interp, objv[i], optStrings, &index, "option",
		0) != JIM_OK) {
	    return JIM_ERR;
	}
	switch (index) {
	case OPT_STRICT:
	    strict = 1;
	    break;
	}
    }

    resultObj = Jim_NewObj(interp);
    resultObj->typePtr = NULL;
    data = (unsigned char *)Jim_GetString(objv[objc - 1], &count);

    datastart = data;
    dataend = data + count;
    size = ((count + 3) & ~3) * 3 / 4;
    resultObj->bytes = Jim_Alloc(size);
    resultObj->length = size;
    begin = cursor = (unsigned char *)resultObj->bytes;
    while (data < dataend) {
	unsigned long value = 0;

	/*
	 * Decode the current block. Each base64 block consists of four input
	 * characters A-Z, a-z, 0-9, +, or /. Each character supplies six bits
	 * of output data, so each block's output is 24 bits (three bytes) in
	 * length. The final block can be shorter by one or two bytes, denoted
	 * by the input ending with one or two ='s, respectively.
	 */

	for (i = 0; i < 4; i++) {
	    /*
	     * Get the next input character. At end of input, pad with at most
	     * two ='s. If more than two ='s would be needed, instead discard
	     * the block read thus far.
	     */

	    if (data < dataend) {
		c = *data++;
	    } else if (i > 1) {
		c = '=';
	    } else {
		if (strict && i <= 1) {
		    /*
		     * Single resp. unfulfilled char (each 4th next single
		     * char) is rather bad64 error case in strict mode.
		     */

		    goto bad64;
		}
		cut += 3;
		break;
	    }

	    /*
	     * Load the character into the block value. Handle ='s specially
	     * because they're only valid as the last character or two of the
	     * final block of input. Unless strict mode is enabled, skip any
	     * input whitespace characters.
	     */

	    if (cut) {
		if (c == '=' && i > 1) {
		    value <<= 6;
		    cut++;
		} else if (!strict) {
		    i--;
		} else {
		    goto bad64;
		}
	    } else if (c >= 'A' && c <= 'Z') {
		value = (value << 6) | ((c - 'A') & 0x3F);
	    } else if (c >= 'a' && c <= 'z') {
		value = (value << 6) | ((c - 'a' + 26) & 0x3F);
	    } else if (c >= '0' && c <= '9') {
		value = (value << 6) | ((c - '0' + 52) & 0x3F);
	    } else if (c == '+') {
		value = (value << 6) | 0x3E;
	    } else if (c == '/') {
		value = (value << 6) | 0x3F;
	    } else if (c == '=' && (!strict || i > 1)) {
		/*
		 * "=" and "a=" is rather bad64 error case in strict mode.
		 */

		value <<= 6;
		if (i) {
		    cut++;
		}
	    } else if (strict) {
		goto bad64;
	    } else {
		i--;
	    }
	}
	*cursor++ = UCHAR((value >> 16) & 0xFF);
	*cursor++ = UCHAR((value >> 8) & 0xFF);
	*cursor++ = UCHAR(value & 0xFF);

	/*
	 * Since = is only valid within the final block, if it was encountered
	 * but there are still more input characters, confirm that strict mode
	 * is off and all subsequent characters are whitespace.
	 */

	if (cut && data < dataend) {
	    if (strict) {
		goto bad64;
	    }
	}
    }
    resultObj->length = cursor - begin - cut;
    // Jim_SetByteArrayLength(resultObj, cursor - begin - cut);
    Jim_SetResult(interp, resultObj);
    return JIM_OK;

  bad64:
    // if (pure) {
	ucs4 = c;
    // } else {
	/* The decoder is byte-oriented. If we saw a byte that's not a
	 * valid member of the base64 alphabet, it could be the lead byte
	 * of a multi-byte character. */

	/* Safe because we know data is NUL-terminated */
	// TclUtfToUniChar((const char *)(data - 1), &ucs4);
    // }

    Jim_SetResultFormatted(interp,
	    "invalid base64 character \"%c\" (U+%06X) at position %"
	    "zu", ucs4, ucs4, data - datastart - 1);
    // Jim_SetErrorCode(interp, "TCL", "BINARY", "DECODE", "INVALID", (char *)NULL);
    Jim_DecrRefCount(interp, resultObj);
    return JIM_ERR;
}


int Jim_base64Init(Jim_Interp *interp)
{
    Jim_PackageProvideCheck(interp, "base64");
    Jim_CreateCommand(interp, "binary encode base64", BinaryEncode64, NULL, NULL);
    Jim_CreateCommand(interp, "binary decode base64", BinaryDecode64, NULL, NULL);
    return JIM_OK;
}
