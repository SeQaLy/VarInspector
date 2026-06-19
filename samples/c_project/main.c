/*
 * main.c - エントリポイント
 * config.h 経由で他モジュールの公開変数・型を利用する
 */
#include "config.h"
#include <stdio.h>

/* ---- main モジュールのグローバル ---- */
int          g_exitCode = 0;          /* 公開 */
static int   s_argCache = 0;          /* 非公開 */
const double kVersion = 2.0;          /* 公開（const）*/

int main(int argc, char **argv) {
    enum LogLevel level   = LOG_INFO;
    Connection    primary;
    const char   *cfgFile = "app.conf";
    int           ok      = 0;
    double        thr     = g_cpuThreshold;

    s_argCache = argc;
    ok = load_config(cfgFile);
    return g_exitCode;
}
