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
