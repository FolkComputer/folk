// oracle.c -- dump the token stream of Jim Tcl's own script tokenizer.
//
// This is a test oracle for tclparse.tcl. It compiles vendor/jimtcl/jim.c
// into this translation unit so that it can call the tokenizer
// (JimParseScript), which is static in jim.c and so not reachable through
// jim.h. Word and {*} grouping mirrors ScriptObjAddTokens and
// JimCountWordTokens in jim.c.
//
// Build:  make -C research/extract
// Usage:  oracle FILE          (tokenizes FILE as a script)
//
// Output, one record per line, tab-separated:
//   C <line>                   start of a command
//   W <expand:0|1> <ntokens>   start of a word
//   T <type> <line> <hex>      token; <hex> is the token's bytes
//   M <char> <line>            unterminated construct (missing <char>)

#include "jim.c"

static const char *ttName(int tt) {
    switch (tt) {
    case JIM_TT_STR: return "str";
    case JIM_TT_ESC: return "esc";
    case JIM_TT_VAR: return "var";
    case JIM_TT_DICTSUGAR: return "dictsugar";
    case JIM_TT_EXPRSUGAR: return "exprsugar";
    case JIM_TT_CMD: return "cmd";
    default: return "?";
    }
}

static void emitToken(const ParseToken *t) {
    printf("T\t%s\t%d\t", ttName(t->type), t->line);
    for (int i = 0; i < t->len; i++) {
        printf("%02x", (unsigned char) t->token[i]);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s FILE\n", argv[0]);
        return 2;
    }
    FILE *fp = fopen(argv[1], "rb");
    if (fp == NULL) { perror(argv[1]); return 2; }
    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char *text = malloc(len + 1);
    if (fread(text, 1, len, fp) != (size_t) len) { perror("fread"); return 2; }
    text[len] = '\0';
    fclose(fp);

    struct JimParserCtx parser;
    ParseTokenList tokenlist;
    ScriptTokenListInit(&tokenlist);

    JimParserInit(&parser, text, (int) len, 1, 0);
    while (!parser.eof) {
        JimParseScript(&parser);
        ScriptAddToken(&tokenlist, parser.tstart, parser.tend - parser.tstart + 1,
                       parser.tt, parser.tline, parser.tcol);
    }
    ScriptAddToken(&tokenlist, text + len, 0, JIM_TT_EOF, 0, 0);

    int inCommand = 0;
    for (int i = 0; i < tokenlist.count; ) {
        while (tokenlist.list[i].type == JIM_TT_SEP) { i++; }

        ParseToken *t = &tokenlist.list[i];
        if (TOKEN_IS_SEP(t->type)) {
            // EOL or EOF: end of the current command.
            inCommand = 0;
            if (t->type == JIM_TT_EOF) { break; }
            i++;
            continue;
        }

        // Same test as JimCountWordTokens.
        int expand = 0;
        if (t->type == JIM_TT_STR && !TOKEN_IS_SEP(t[1].type) &&
            ((t->len == 1 && *t->token == '*') ||
             (t->len == 6 && strncmp(t->token, "expand", 6) == 0))) {
            expand = 1;
            t++; i++;
        }
        int count = 0;
        while (!TOKEN_IS_SEP(t[count].type)) { count++; }

        if (!inCommand) {
            printf("C\t%d\n", t->line);
            inCommand = 1;
        }
        printf("W\t%d\t%d\n", expand, count);
        for (int j = 0; j < count; j++) { emitToken(&t[j]); }
        i += count;
    }
    if (parser.missing.ch != ' ') {
        printf("M\t%c\t%d\n", parser.missing.ch, parser.missing.line);
    }
    return 0;
}
