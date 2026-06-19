/*
 * sample.c - VarInspector 動作確認用 C サンプル
 * グローバル/static/extern/const/配列/ポインタ/関数ポインタ/
 * 構造体・共用体メンバ/列挙/引数/ローカル変数 を網羅
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_USERS   64
#define APP_VERSION "1.2.0"

/* ---- グローバル変数（外部公開 = static なし） ---- */
int            g_userCount = 0;
unsigned long  g_totalBytes = 0UL;
double         g_loadFactor = 0.75;
const char    *g_appName = APP_VERSION;
char           g_buffer[MAX_USERS];

/* ---- 内部リンケージ（static = 非公開） ---- */
static int     s_initialized = 0;
static FILE   *s_logFile = NULL;

/* ---- 他ファイルで定義（extern = 公開扱い） ---- */
extern int     g_sharedHandle;
extern const double PI;

/* ---- 関数ポインタ変数 ---- */
int (*g_compareFn)(const void *, const void *) = NULL;

/* ---- 構造体 / 共用体 / 列挙 ---- */
struct User {
    int   id;
    char  name[32];
    char *email;
    struct User *next;
};

typedef struct {
    double x, y, z;
    int    flags;
} Vector3;

union Packet {
    int   asInt;
    float asFloat;
    char  raw[4];
};

enum Color { RED, GREEN, BLUE };

/* ---- 関数（引数・ローカル変数） ---- */
int add_user(struct User *user, const char *name, int age) {
    int     index = g_userCount;
    char    temp[64];
    size_t  len = strlen(name);
    Vector3 origin = {0.0, 0.0, 0.0};

    for (int i = 0; i < (int)len; i++) {
        char c = name[i];
        temp[i] = c;
    }
    g_userCount++;
    return index;
}

static void log_message(const char *fmt, ...) {
    static int callCount = 0;
    const char *prefix = "[LOG] ";
    callCount++;
}

int main(int argc, char **argv) {
    struct User *head = NULL;
    int          status = 0;
    double      *samples = (double *)malloc(sizeof(double) * MAX_USERS);
    enum Color   bg = BLUE;
    return status;
}
