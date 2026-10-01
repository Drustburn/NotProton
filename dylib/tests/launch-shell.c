#include "../hooks/hook_launch.c"

#include <stdio.h>

int   np_log_level = 0;
FILE *np_log_file  = NULL;

int np_rebind_import(const struct mach_header_64 *mh, intptr_t slide,
                     const char *symbol, void *replacement) {
    (void)mh; (void)slide; (void)symbol; (void)replacement;
    return -1;
}

int np_hooks_env_lists_label(const char *var, const char *label) {
    (void)var; (void)label;
    return 0;
}

static int         failures;
static const char *shell;

static void wraps(const char *in, const char *want) {
    char *got = np_launch_shell(in, shell, -1, NULL);

    if (!got || strcmp(got, want) != 0) {
        printf("FAIL %s\n  want: %s\n  got:  %s\n", in, want, got ? got : "(unchanged)");
        failures++;
    } else {
        printf("  ok    %s\n", in);
    }
    free(got);
}

int main(void) {
    printf("== a NAME=VALUE prefix reaches the shell that promotes it ==\n");
    wraps("LSFGM_ENV=1 /g/game.exe", "/bin/sh -c 'LSFGM_ENV=1 /g/game.exe'");
    wraps("A=1 B=2 /g/game.exe", "/bin/sh -c 'A=1 B=2 /g/game.exe'");
    wraps("A=1 /g/game.exe -windowed", "/bin/sh -c 'A=1 /g/game.exe -windowed'");
    wraps("  A=1 /g/game.exe", "/bin/sh -c '  A=1 /g/game.exe'");

    wraps("A=1", "/bin/sh -c 'A=1'");

    printf("== the quotes Steam substitutes survive byte for byte ==\n");
    wraps("A=1 \"/Program Files/game.exe\"",
          "/bin/sh -c 'A=1 \"/Program Files/game.exe\"'");
    wraps("A='x y' /g/game.exe", "/bin/sh -c 'A='\\''x y'\\'' /g/game.exe'");
    wraps("A=1 '/p/.'/run waitforexitandrun '/g/g 64.exe'",
          "/bin/sh -c 'A=1 '\\''/p/.'\\''/run waitforexitandrun '\\''/g/g 64.exe'\\'''");

    printf("== what only a shell would act on reaches one ==\n");
    wraps("/g/game.exe > /tmp/log", "/bin/sh -c '/g/game.exe > /tmp/log'");
    wraps("/g/game.exe | tee /tmp/log", "/bin/sh -c '/g/game.exe | tee /tmp/log'");
    wraps("/g/game.exe && echo done", "/bin/sh -c '/g/game.exe && echo done'");
    wraps("/g/game.exe; echo done", "/bin/sh -c '/g/game.exe; echo done'");
    wraps("/g/game.exe $HOME", "/bin/sh -c '/g/game.exe $HOME'");
    wraps("/g/game.exe \"$HOME\"", "/bin/sh -c '/g/game.exe \"$HOME\"'");
    wraps("/g/game.exe ~/save", "/bin/sh -c '/g/game.exe ~/save'");
    wraps("/g/game.exe *.cfg", "/bin/sh -c '/g/game.exe *.cfg'");

    printf("== a plain command line reaches the shell too, as on Linux ==\n");
    wraps("/g/game.exe", "/bin/sh -c '/g/game.exe'");
    wraps("/g/game.exe -windowed", "/bin/sh -c '/g/game.exe -windowed'");
    wraps("\"/Program Files/game.exe\" -windowed",
          "/bin/sh -c '\"/Program Files/game.exe\" -windowed'");
    wraps("gamemoderun /g/game.exe", "/bin/sh -c 'gamemoderun /g/game.exe'");
    wraps("/g/game.exe '$HOME'", "/bin/sh -c '/g/game.exe '\\''$HOME'\\'''");
    wraps("", "/bin/sh -c ''");
    wraps(";touch ~", "/bin/sh -c ';touch ~'");

    printf("== STEAM_GAME_LAUNCH_SHELL stands in for /bin/sh -c as one argument ==\n");
    shell = "/usr/bin/env";
    wraps("A=1 /g/game.exe", "'/usr/bin/env' 'A=1 /g/game.exe'");
    shell = "/opt/my shell";
    wraps("/g/game.exe", "'/opt/my shell' '/g/game.exe'");
    shell = "";
    wraps("/g/game.exe", "'' '/g/game.exe'");
    shell = NULL;

    printf("== a capped argument count keeps the caller on its own buffer ==\n");
    const char *rest = NULL;
    char       *got  = np_launch_shell("A=1 /g/game.exe", NULL, 2, NULL);

    if (got) {
        printf("FAIL a capped count must not rewrite, but it became: %s\n", got);
        failures++;
    } else {
        printf("  ok    a capped count is left alone\n");
    }
    free(got);

    got = np_launch_shell("A=1 /g/game.exe", NULL, -1, &rest);
    if (got) {
        printf("FAIL a remainder request must not rewrite, but it became: %s\n", got);
        failures++;
    } else {
        printf("  ok    a remainder request is left alone\n");
    }
    free(got);

    if (failures) {
        printf("\n%d assertion(s) failed\n", failures);
        return 1;
    }
    printf("\n==> launch-shell: all assertions hold\n");
    return 0;
}
