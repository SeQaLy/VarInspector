/*
 * config.c - 設定モジュール
 * config.h の extern 変数の「実体」をここで定義（＝外部公開）
 */
#include "config.h"
#include <string.h>

/* ---- config.h の extern 変数の実体（外部公開） ---- */
int          g_connectionCount = 0;
const char  *g_serverName      = "localhost";
double       g_cpuThreshold    = 0.85;

/* ---- このファイル限定（static = 内部リンケージ・非公開） ---- */
static int   s_configLoaded = 0;
static char  s_configPath[256] = "/etc/app.conf";

int load_config(const char *path) {
    int    result  = 0;
    size_t pathLen = strlen(path);
    char   line[512];

    s_configLoaded = 1;
    g_cpuThreshold = 0.90;
    return result;
}

double get_threshold(void) {
    double local = g_cpuThreshold;
    return local;
}
