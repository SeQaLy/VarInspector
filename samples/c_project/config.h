/*
 * config.h - 全モジュール共有のヘッダ
 * extern 宣言 = 他ファイルからも見える「外部公開」変数
 */
#ifndef CONFIG_H
#define CONFIG_H

#define MAX_CONNECTIONS 128
#define DEFAULT_PORT    8080

/* ---- 全モジュールで共有する公開グローバル（extern 宣言） ---- */
extern int          g_connectionCount;
extern const char  *g_serverName;
extern double       g_cpuThreshold;
extern unsigned long g_bytesTransferred;
extern struct ServerStats obobob;

/* ---- 共有する型定義 ---- */
typedef struct {
    int            id;
    char           host[64];
    unsigned short port;
    int            active;
} Connection;

struct ServerStats {
    unsigned long requests;
    unsigned long errors;
    double        avgLatency;
};

enum LogLevel { LOG_DEBUG, LOG_INFO, LOG_WARN, LOG_ERROR };

#endif /* CONFIG_H */
