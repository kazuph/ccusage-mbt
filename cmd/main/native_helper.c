#include <time.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "moonbit.h"

int utc_to_local_date(int year, int month, int day, int hour, int min, int sec) {
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_hour = hour;
    tm.tm_min = min;
    tm.tm_sec = sec;

    time_t epoch = timegm(&tm);

    struct tm local;
    localtime_r(&epoch, &local);

    return (local.tm_year + 1900) * 10000 + (local.tm_mon + 1) * 100 + local.tm_mday;
}

// Get file modification date as local YYYYMMDD int
int c_file_mtime_date(moonbit_string_t path_str, int32_t path_len) {
    char path[4096];
    int plen = path_len < 4095 ? path_len : 4095;
    for (int i = 0; i < plen; i++) path[i] = (char)(path_str[i] & 0xFF);
    path[plen] = '\0';
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    struct tm local;
    localtime_r(&st.st_mtime, &local);
    return (local.tm_year + 1900) * 10000 + (local.tm_mon + 1) * 100 + local.tm_mday;
}

// --- Streaming line-by-line file reader with pre-filter ---
static FILE* current_file = NULL;
// Reusable getline buffer
static char* line_buf = NULL;
static size_t line_buf_cap = 0;

int c_open_file(moonbit_string_t path_str, int32_t path_len) {
    if (current_file) { fclose(current_file); current_file = NULL; }
    char path[4096];
    int plen = path_len < 4095 ? path_len : 4095;
    for (int i = 0; i < plen; i++) {
        path[i] = (char)(path_str[i] & 0xFF);
    }
    path[plen] = '\0';
    current_file = fopen(path, "r");
    return current_file ? 1 : 0;
}

// Helper: convert UTF-8 buffer (len bytes) to MoonBit string
static moonbit_string_t utf8_to_mbt(const unsigned char* buf, long len) {
    if (len <= 0) return moonbit_make_string(0, 0);

    // Pass 1: count UTF-16 code units
    long utf16_len = 0;
    for (long i = 0; i < len; ) {
        unsigned char c = buf[i];
        if (c < 0x80) { utf16_len++; i++; }
        else if (c < 0xE0) { utf16_len++; i += 2; }
        else if (c < 0xF0) { utf16_len++; i += 3; }
        else { utf16_len += 2; i += 4; }
    }

    moonbit_string_t ms = moonbit_make_string((int32_t)utf16_len, 0);

    // Pass 2: convert
    long j = 0;
    for (long i = 0; i < len; ) {
        unsigned char c = buf[i];
        if (c < 0x80) {
            ms[j++] = (uint16_t)c;
            i++;
        } else if (c < 0xE0 && i + 1 < len) {
            ms[j++] = (uint16_t)(((c & 0x1F) << 6) | (buf[i+1] & 0x3F));
            i += 2;
        } else if (c < 0xF0 && i + 2 < len) {
            ms[j++] = (uint16_t)(((c & 0x0F) << 12) | ((buf[i+1] & 0x3F) << 6) | (buf[i+2] & 0x3F));
            i += 3;
        } else if (c >= 0xF0 && i + 3 < len) {
            uint32_t cp = ((c & 0x07) << 18) | ((buf[i+1] & 0x3F) << 12) | ((buf[i+2] & 0x3F) << 6) | (buf[i+3] & 0x3F);
            cp -= 0x10000;
            ms[j++] = (uint16_t)(0xD800 + (cp >> 10));
            ms[j++] = (uint16_t)(0xDC00 + (cp & 0x3FF));
            i += 4;
        } else {
            ms[j++] = 0xFFFD;
            i++;
        }
    }

    return ms;
}

// Pre-filter needle: "input_tokens"
static const char FILTER_NEEDLE[] = "\"input_tokens\"";
static const int FILTER_NEEDLE_LEN = 14;

// Read next line that contains "input_tokens".
// Lines without this marker are skipped at C level (no UTF-16 conversion).
// Returns empty string for EOF.
moonbit_string_t c_read_line_ffi(void) {
    while (1) {
        if (!current_file) return moonbit_make_string(0, 0);

        ssize_t len = getline(&line_buf, &line_buf_cap, current_file);

        if (len < 0) {
            fclose(current_file);
            current_file = NULL;
            return moonbit_make_string(0, 0);
        }

        // Strip trailing newline/carriage return
        while (len > 0 && (line_buf[len-1] == '\n' || line_buf[len-1] == '\r')) len--;

        if (len == 0) continue;

        // Fast pre-filter: skip lines without "input_tokens"
        line_buf[len] = '\0';
        if (strstr(line_buf, FILTER_NEEDLE) == NULL) continue;

        moonbit_string_t result = utf8_to_mbt((const unsigned char*)line_buf, len);
        return result;
    }
}

int c_is_eof(void) {
    return current_file == NULL ? 1 : 0;
}

void c_close_file(void) {
    if (current_file) { fclose(current_file); current_file = NULL; }
}

// Extract substring from MoonBit string (UTF-16 code unit level)
moonbit_string_t c_substring(moonbit_string_t str, int32_t start, int32_t end) {
    int32_t len = end - start;
    if (len <= 0) return moonbit_make_string(0, 0);
    moonbit_string_t result = moonbit_make_string(len, 0);
    for (int32_t i = 0; i < len; i++) {
        result[i] = str[start + i];
    }
    return result;
}

// Return day of week (0=Sunday) for a local YYYYMMDD date
int c_day_of_week(int yyyymmdd) {
    int y = yyyymmdd / 10000;
    int m = (yyyymmdd % 10000) / 100;
    int d = yyyymmdd % 100;
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_year = y - 1900;
    tm.tm_mon = m - 1;
    tm.tm_mday = d;
    tm.tm_hour = 12;
    mktime(&tm);
    return tm.tm_wday;
}

// ============================================================
// Fast field extraction (avoids full JSON parse + UTF-16 conv)
// ============================================================

// Extract integer value after a JSON field name (e.g. "\"input_tokens\"")
static long fast_extract_int(const char* buf, const char* field) {
    const char* p = strstr(buf, field);
    if (!p) return 0;
    p += strlen(field);
    while (*p == ':' || *p == ' ' || *p == '\t') p++;
    long val = 0;
    while (*p >= '0' && *p <= '9') {
        val = val * 10 + (*p - '0');
        p++;
    }
    return val;
}

// Extract string value after a JSON field (e.g. "\"model\"")
// Copies to out buffer, returns length
static int fast_extract_str(const char* buf, const char* field, char* out, int max_len) {
    const char* p = strstr(buf, field);
    if (!p) { out[0] = '\0'; return 0; }
    p += strlen(field);
    while (*p && *p != '"') p++;
    if (*p == '"') p++;
    int i = 0;
    while (*p && *p != '"' && i < max_len - 1) {
        out[i++] = *p++;
    }
    out[i] = '\0';
    return i;
}

// Same but searching from a given offset
static int fast_extract_str_from(const char* buf, int offset, const char* field, char* out, int max_len) {
    const char* p = strstr(buf + offset, field);
    if (!p) { out[0] = '\0'; return 0; }
    p += strlen(field);
    while (*p && *p != '"') p++;
    if (*p == '"') p++;
    int i = 0;
    while (*p && *p != '"' && i < max_len - 1) {
        out[i++] = *p++;
    }
    out[i] = '\0';
    return i;
}

// ============================================================
// Dedup hash set (FNV-1a based, open addressing)
// ============================================================
#define DEDUP_SIZE (1 << 18)  // 256K slots
static uint64_t dedup_table[DEDUP_SIZE];
static uint8_t  dedup_flags[DEDUP_SIZE];

void c_dedup_reset(void) {
    memset(dedup_flags, 0, sizeof(dedup_flags));
}

static uint64_t fnv1a(const char* data, int len) {
    uint64_t h = 14695981039346656037ULL;
    for (int i = 0; i < len; i++) {
        h ^= (uint64_t)(unsigned char)data[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// Returns 1 if duplicate (already seen), 0 if new
static int dedup_check(const char* key, int key_len) {
    if (key_len == 0) return 0;
    uint64_t h = fnv1a(key, key_len);
    uint32_t idx = (uint32_t)(h & (DEDUP_SIZE - 1));
    for (int probe = 0; probe < 64; probe++) {
        uint32_t pos = (idx + probe) & (DEDUP_SIZE - 1);
        if (!dedup_flags[pos]) {
            dedup_flags[pos] = 1;
            dedup_table[pos] = h;
            return 0;
        }
        if (dedup_table[pos] == h) return 1;
    }
    return 0;
}

// ============================================================
// Fast Claude Code line reader + parser
// ============================================================
static char g_model_buf[128];
static int  g_model_len = 0;
static int  g_date = 0;
static int  g_inp = 0, g_out = 0, g_cc = 0, g_cr = 0;

// Read next valid Claude entry, extract fields in C.
// Returns date (YYYYMMDD) or 0 for EOF.
int c_fast_read_claude(int since, int until) {
    while (1) {
        if (!current_file) return 0;
        ssize_t len = getline(&line_buf, &line_buf_cap, current_file);
        if (len < 0) { fclose(current_file); current_file = NULL; return 0; }
        while (len > 0 && (line_buf[len-1] == '\n' || line_buf[len-1] == '\r')) len--;
        if (len == 0) continue;
        line_buf[len] = '\0';

        // Pre-filter
        if (!strstr(line_buf, "\"input_tokens\"")) continue;

        // Extract timestamp
        char ts[32];
        int ts_len = fast_extract_str(line_buf, "\"timestamp\"", ts, sizeof(ts));
        if (ts_len < 19) continue;
        int y  = (ts[0]-'0')*1000+(ts[1]-'0')*100+(ts[2]-'0')*10+(ts[3]-'0');
        int mo = (ts[5]-'0')*10+(ts[6]-'0');
        int d  = (ts[8]-'0')*10+(ts[9]-'0');
        int h  = (ts[11]-'0')*10+(ts[12]-'0');
        int mi = (ts[14]-'0')*10+(ts[15]-'0');
        int sc = (ts[17]-'0')*10+(ts[18]-'0');
        int date = utc_to_local_date(y, mo, d, h, mi, sc);
        if (date == 0 || date < since || date > until) continue;

        // Must have "message" and "usage"
        const char* msg_pos = strstr(line_buf, "\"message\"");
        if (!msg_pos) continue;
        const char* usage_pos = strstr(msg_pos, "\"usage\"");
        if (!usage_pos) continue;

        // Extract model from message object
        int msg_off = (int)(msg_pos - line_buf);
        fast_extract_str_from(line_buf, msg_off, "\"model\"", g_model_buf, sizeof(g_model_buf));
        if (g_model_buf[0] == '\0') continue;
        g_model_len = (int)strlen(g_model_buf);

        // Dedup: message.id + requestId
        char mid[128] = "", rid[128] = "";
        fast_extract_str_from(line_buf, msg_off, "\"id\"", mid, sizeof(mid));
        fast_extract_str(line_buf, "\"requestId\"", rid, sizeof(rid));
        if (mid[0] || rid[0]) {
            char dk[260];
            int dk_len = snprintf(dk, sizeof(dk), "%s:%s", mid, rid);
            if (dedup_check(dk, dk_len)) continue;
        }

        // Extract usage tokens (search from usage position for safety)
        g_inp = (int)fast_extract_int(usage_pos, "\"input_tokens\"");
        g_out = (int)fast_extract_int(usage_pos, "\"output_tokens\"");
        g_cc  = (int)fast_extract_int(usage_pos, "\"cache_creation_input_tokens\"");
        g_cr  = (int)fast_extract_int(usage_pos, "\"cache_read_input_tokens\"");

        g_date = date;
        return date;
    }
}

moonbit_string_t c_get_model(void) {
    return utf8_to_mbt((const unsigned char*)g_model_buf, g_model_len);
}
int c_get_inp(void) { return g_inp; }
int c_get_out(void) { return g_out; }
int c_get_cc(void)  { return g_cc; }
int c_get_cr(void)  { return g_cr; }

// ============================================================
// Codex session reader (tail-read for last token_count)
// ============================================================
static int g_codex_inp = 0, g_codex_cached = 0;
static int g_codex_out = 0, g_codex_reasoning = 0;

// Extract local date from Codex path: .../sessions/YYYY/MM/DD/file.jsonl
static int date_from_codex_path(const char* path) {
    const char* p = strstr(path, "/sessions/");
    if (!p) return 0;
    p += 10;
    if (strlen(p) < 10) return 0;
    int yy = (p[0]-'0')*1000+(p[1]-'0')*100+(p[2]-'0')*10+(p[3]-'0');
    int mm = (p[5]-'0')*10+(p[6]-'0');
    int dd = (p[8]-'0')*10+(p[9]-'0');
    return yy*10000 + mm*100 + dd;
}

// Read Codex session, find last token_count, extract cumulative totals.
// Returns date (YYYYMMDD) or 0 on failure.
int c_read_codex_session(moonbit_string_t path_str, int32_t path_len) {
    char path[4096];
    int plen = path_len < 4095 ? path_len : 4095;
    for (int i = 0; i < plen; i++) path[i] = (char)(path_str[i] & 0xFF);
    path[plen] = '\0';

    int date = date_from_codex_path(path);
    if (date == 0) return 0;

    FILE* f = fopen(path, "r");
    if (!f) return 0;

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);

    static const long tail_sizes[] = {65536, 262144, 0};
    char* buf = NULL;
    int found = 0;

    g_codex_inp = 0; g_codex_cached = 0;
    g_codex_out = 0; g_codex_reasoning = 0;

    for (int attempt = 0; attempt < 3 && !found; attempt++) {
        long read_size = tail_sizes[attempt] == 0 ? file_size : tail_sizes[attempt];
        if (read_size > file_size) read_size = file_size;
        long offset = file_size - read_size;
        fseek(f, offset, SEEK_SET);
        buf = (char*)realloc(buf, read_size + 1);
        long bytes_read = (long)fread(buf, 1, read_size, f);
        buf[bytes_read] = '\0';

        // Find last "token_count" entry
        const char* last_tc = NULL;
        const char* search = buf;
        while ((search = strstr(search, "\"token_count\"")) != NULL) {
            last_tc = search;
            search++;
        }
        if (last_tc) {
            found = 1;
            const char* tu = strstr(last_tc, "\"total_token_usage\"");
            if (tu) {
                g_codex_inp       = (int)fast_extract_int(tu, "\"input_tokens\"");
                g_codex_cached    = (int)fast_extract_int(tu, "\"cached_input_tokens\"");
                g_codex_out       = (int)fast_extract_int(tu, "\"output_tokens\"");
                g_codex_reasoning = (int)fast_extract_int(tu, "\"reasoning_output_tokens\"");
            }
        }
    }
    free(buf);
    fclose(f);
    g_date = date;
    return found ? date : 0;
}

int c_codex_inp(void)       { return g_codex_inp; }
int c_codex_cached(void)    { return g_codex_cached; }
int c_codex_out(void)       { return g_codex_out; }
int c_codex_reasoning(void) { return g_codex_reasoning; }
