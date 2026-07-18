#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    PAGE_WIDTH = 4960,
    PAGE_HEIGHT = 7016,
    ROW_BYTES = (PAGE_WIDTH + 7) / 8
};

static uint8_t *page;

static void set_pixel(int x, int y) {
    if (x < 0 || x >= PAGE_WIDTH || y < 0 || y >= PAGE_HEIGHT) {
        return;
    }
    page[(size_t)y * ROW_BYTES + (size_t)x / 8] |= (uint8_t)(0x80u >> (x & 7));
}

static void fill_rect(int x, int y, int width, int height) {
    for (int yy = y; yy < y + height; ++yy) {
        for (int xx = x; xx < x + width; ++xx) {
            set_pixel(xx, yy);
        }
    }
}

static void outline_rect(int x, int y, int width, int height, int thickness) {
    fill_rect(x, y, width, thickness);
    fill_rect(x, y + height - thickness, width, thickness);
    fill_rect(x, y, thickness, height);
    fill_rect(x + width - thickness, y, thickness, height);
}

static const uint8_t font_letters[26][7] = {
    {14,17,17,31,17,17,17}, {30,17,17,30,17,17,30},
    {14,17,16,16,16,17,14}, {30,17,17,17,17,17,30},
    {31,16,16,30,16,16,31}, {31,16,16,30,16,16,16},
    {14,17,16,23,17,17,15}, {17,17,17,31,17,17,17},
    {14,4,4,4,4,4,14},      {7,2,2,2,2,18,12},
    {17,18,20,24,20,18,17}, {16,16,16,16,16,16,31},
    {17,27,21,21,17,17,17}, {17,25,21,19,17,17,17},
    {14,17,17,17,17,17,14}, {30,17,17,30,16,16,16},
    {14,17,17,17,21,18,13}, {30,17,17,30,20,18,17},
    {15,16,16,14,1,1,30},   {31,4,4,4,4,4,4},
    {17,17,17,17,17,17,14}, {17,17,17,17,17,10,4},
    {17,17,17,21,21,21,10}, {17,17,10,4,10,17,17},
    {17,17,10,4,4,4,4},     {31,1,2,4,8,16,31}
};

static const uint8_t font_digits[10][7] = {
    {14,17,19,21,25,17,14}, {4,12,4,4,4,4,14},
    {14,17,1,2,4,8,31},     {30,1,1,14,1,1,30},
    {2,6,10,18,31,2,2},     {31,16,16,30,1,1,30},
    {14,16,16,30,17,17,14}, {31,1,2,4,8,8,8},
    {14,17,17,14,17,17,14}, {14,17,17,15,1,1,14}
};

static uint8_t glyph_row(char ch, int row) {
    if (ch >= 'A' && ch <= 'Z') {
        return font_letters[ch - 'A'][row];
    }
    if (ch >= '0' && ch <= '9') {
        return font_digits[ch - '0'][row];
    }
    if (ch == '-') {
        return row == 3 ? 31 : 0;
    }
    if (ch == '.') {
        return row == 6 ? 4 : 0;
    }
    return 0;
}

static void draw_text(int x, int y, const char *text, int scale) {
    for (size_t index = 0; text[index] != '\0'; ++index) {
        for (int row = 0; row < 7; ++row) {
            uint8_t bits = glyph_row(text[index], row);
            for (int column = 0; column < 5; ++column) {
                if (bits & (1u << (4 - column))) {
                    fill_rect(x + (int)index * 6 * scale + column * scale,
                              y + row * scale, scale, scale);
                }
            }
        }
    }
}

static void draw_density_patch(int x, int y, int width, int height, int period) {
    outline_rect(x, y, width, height, 4);
    for (int yy = y + 8; yy < y + height - 8; ++yy) {
        for (int xx = x + 8; xx < x + width - 8; ++xx) {
            if (((xx + yy) % period) == 0) {
                set_pixel(xx, yy);
            }
        }
    }
}

static int write_page(FILE *output, const char *path) {
    if (fprintf(output, "P4\n%d %d\n", PAGE_WIDTH, PAGE_HEIGHT) < 0 ||
        fwrite(page, ROW_BYTES, PAGE_HEIGHT, output) != PAGE_HEIGHT) {
        fprintf(stderr, "cannot write %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static void render_page(int page_number, int page_count) {
    memset(page, 0, (size_t)ROW_BYTES * PAGE_HEIGHT);
    outline_rect(112, 112, PAGE_WIDTH - 224, PAGE_HEIGHT - 224, 8);
    draw_text(320, 360, "HP LASERJET M1005", 34);
    draw_text(320, 720, "MACOS 26 PHASE 1", 28);
    draw_text(320, 1040, "A4 600 DPI", 28);

    for (int index = 0; index < 10; ++index) {
        fill_rect(320 + index * 390, 1450, 40 + index * 24, 220);
    }

    draw_density_patch(320, 1900, 1100, 800, 8);
    draw_density_patch(1930, 1900, 1100, 800, 4);
    draw_density_patch(3540, 1900, 1100, 800, 2);
    draw_text(650, 2780, "LIGHT", 18);
    draw_text(2240, 2780, "MEDIUM", 18);
    draw_text(3840, 2780, "DARK", 18);

    for (int y = 3300; y <= 5900; y += 260) {
        fill_rect(320, y, PAGE_WIDTH - 640, 4);
    }
    for (int x = 320; x <= PAGE_WIDTH - 320; x += 360) {
        fill_rect(x, 3300, 4, 2604);
    }

    fill_rect(PAGE_WIDTH / 2 - 220, 6250, 440, 8);
    fill_rect(PAGE_WIDTH / 2 - 4, 6030, 8, 440);
    outline_rect(PAGE_WIDTH / 2 - 120, 6130, 240, 240, 6);

    if (page_count == 1) {
        draw_text(1500, 6600, "PHASE 1 TEST", 22);
    } else {
        char page_label[32];
        snprintf(page_label, sizeof(page_label), "PAGE %d OF %d", page_number, page_count);
        draw_text(1600, 6600, page_label, 22);
    }
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s output.pbm [page-count]\n", argv[0]);
        return 2;
    }

    int page_count = 1;
    if (argc == 3) {
        char *end = NULL;
        long parsed = strtol(argv[2], &end, 10);
        if (end == argv[2] || *end != '\0' || parsed < 1 || parsed > 10) {
            fprintf(stderr, "page-count must be between 1 and 10\n");
            return 2;
        }
        page_count = (int)parsed;
    }

    page = calloc((size_t)ROW_BYTES, PAGE_HEIGHT);
    if (page == NULL) {
        fprintf(stderr, "cannot allocate test page\n");
        return 1;
    }

    FILE *output = fopen(argv[1], "wb");
    if (output == NULL) {
        fprintf(stderr, "cannot open %s: %s\n", argv[1], strerror(errno));
        free(page);
        return 1;
    }

    int result = 0;
    for (int page_number = 1; page_number <= page_count; ++page_number) {
        render_page(page_number, page_count);
        if (write_page(output, argv[1]) != 0) {
            result = 1;
            break;
        }
    }

    if (fclose(output) != 0) {
        fprintf(stderr, "cannot close %s: %s\n", argv[1], strerror(errno));
        result = 1;
    }

    free(page);
    return result;
}
