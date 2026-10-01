// Makes Steam's Launch Options behave the way they do on Linux.
#include "hooks.h"
#include "../core/macho.h"
#include "../util/log.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define NP_PARSE_SYM_POSIX \
    "_Z28V_ParseShellCommandLinePOSIXPKcR10CUtlVectorI10CUtlString10CUtlMemoryIS2_EEiPS0_"

typedef int (*fn_parse_shell)(const char *cmd, void *argv, int max, const char **rest);

static fn_parse_shell orig_parse_shell;

static size_t np_quote(char *out, const char *s) {
    size_t n = 0;

    out[n++] = '\'';
    for (; *s; s++) {
        if (*s == '\'') {
            memcpy(out + n, "'\\''", 4);
            n += 4;
        } else {
            out[n++] = *s;
        }
    }
    out[n++] = '\'';
    return n;
}

// Shell, followed by the command line as one argument.
static char *np_launch_shell(const char *cmd, const char *shell, int max, const char **rest) {
    // np_hook_parse_shell frees the wrapped copy before its caller reads *rest.
    if (!cmd || max != -1 || rest)
        return NULL;

    const char *lead = shell ? "" : "/bin/sh -c ";
    size_t      cap  = strlen(lead) + 4 * strlen(cmd) + 3
                     + (shell ? 4 * strlen(shell) + 3 : 0) + 1;
    char       *out  = malloc(cap);
    size_t      n    = strlen(lead);

    if (!out)
        return NULL;

    memcpy(out, lead, n);
    if (shell) {
        n += np_quote(out + n, shell);
        out[n++] = ' ';
    }
    n += np_quote(out + n, cmd);
    out[n] = 0;
    return out;
}

static int np_hook_parse_shell(const char *cmd, void *argv, int max, const char **rest) {
    const char *shell   = getenv("STEAM_GAME_LAUNCH_SHELL");
    char       *wrapped = np_launch_shell(cmd, shell, max, rest);

    if (wrapped)
        NP_LOG("[launch] handed to %s: %s", shell ? shell : "/bin/sh -c", cmd);

    int rc = orig_parse_shell(wrapped ? wrapped : cmd, argv, max, rest);
    free(wrapped);
    return rc;
}

void np_hooks_launch_install(const struct mach_header_64 *mh, intptr_t slide) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "launch")) {
        NP_WARN("[launch] DISABLED via NOTPROTON_DISABLE, launches keep running "
                "without a shell");
        return;
    }

    // dlsym takes the name without the leading underscore the symbol table carries.
    orig_parse_shell = (fn_parse_shell)dlsym(RTLD_DEFAULT, NP_PARSE_SYM_POSIX);
    if (!orig_parse_shell) {
        NP_WARN("[launch] V_ParseShellCommandLinePOSIX: unresolved, launches keep "
                "running without a shell");
        return;
    }

    int rebound = np_rebind_import(mh, slide, "_" NP_PARSE_SYM_POSIX,
                                   (void *)np_hook_parse_shell);
    if (rebound > 0)
        NP_LOG("[launch] V_ParseShellCommandLinePOSIX: %d import slot(s) rebound", rebound);
    else
        NP_WARN("[launch] V_ParseShellCommandLinePOSIX: no import slot in steamclient "
                "(rc=%d), launches keep running without a shell", rebound);
}
