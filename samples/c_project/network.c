/*
 * network.c - 通信モジュール
 * 共有グローバルを更新しつつ、自分専用の static 状態を持つ
 */
#include "config.h"

/* ---- network モジュール内部の状態（非公開） ---- */
static Connection s_pool[MAX_CONNECTIONS];
static int        s_poolHead = 0;
static struct ServerStats s_stats;

/* ---- 公開: 他モジュールから参照できる統計値（config.h で extern 宣言済み） ---- */
unsigned long g_bytesTransferred = 0UL;

int open_connection(const char *host, unsigned short port) {
    Connection *conn = &s_pool[s_poolHead];
    int         slot = s_poolHead;
    unsigned    flags = 0;

    conn->port = (port != 0) ? port : DEFAULT_PORT;
    g_connectionCount++;
    s_poolHead++;
    s_stats.requests++;
    return slot;
}

static void reset_pool(void) {
    int idx = 0;
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        s_pool[i].active = 0;
    }
    s_poolHead = 0;
}
