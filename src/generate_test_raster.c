#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define WIDTH 4960U
#define INPUT_HEIGHT 7016U
#define OUTPUT_HEIGHT 7015U
#define PBM_BYTES_PER_LINE 620U

static bool read_header(FILE *input) {
    char magic[3] = {0};
    unsigned width = 0;
    unsigned height = 0;
    return fgets(magic, sizeof(magic), input) != NULL &&
           strcmp(magic, "P4") == 0 &&
           fscanf(input, "%u %u", &width, &height) == 2 &&
           fgetc(input) == '\n' && width == WIDTH && height == INPUT_HEIGHT;
}

int main(int argc, char *argv[]) {
    if ((argc != 4 && argc != 5) ||
        (strcmp(argv[1], "pwg") != 0 && strcmp(argv[1], "urf") != 0)) {
        fprintf(stderr,
                "usage: %s pwg|urf INPUT.pbm OUTPUT.raster [PAGES]\n",
                argv[0]);
        return 2;
    }

    unsigned pages = 1;
    if (argc == 5) {
        char *end = NULL;
        unsigned long parsed = strtoul(argv[4], &end, 10);
        if (end == argv[4] || *end != '\0' || parsed == 0 || parsed > 100) {
            fprintf(stderr, "invalid page count: %s\n", argv[4]);
            return 2;
        }
        pages = (unsigned)parsed;
    }

    FILE *input = fopen(argv[2], "rb");
    if (input == NULL || !read_header(input)) {
        fprintf(stderr, "invalid 4960x7016 raw PBM input\n");
        if (input != NULL) {
            fclose(input);
        }
        return 1;
    }
    long raster_offset = ftell(input);
    if (raster_offset < 0) {
        fclose(input);
        return 1;
    }

    int output_fd = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (output_fd < 0) {
        fprintf(stderr, "cannot create %s: %s\n", argv[3], strerror(errno));
        fclose(input);
        return 1;
    }

    bool urf = strcmp(argv[1], "urf") == 0;
    cups_raster_t *raster = cupsRasterOpen(
        output_fd, urf ? CUPS_RASTER_WRITE_APPLE : CUPS_RASTER_WRITE_PWG);
    cups_page_header2_t header;
    cupsRasterInitPWGHeader(&header, pwgMediaForPWG("iso_a4_210x297mm"),
                            urf ? "sgray_8" : "black_1", 600, 600,
                            "one-sided", NULL);
    header.cupsInteger[CUPS_RASTER_PWG_TotalPageCount] = pages;

    bool success = raster != NULL && header.cupsWidth == WIDTH &&
                   header.cupsHeight == OUTPUT_HEIGHT;
    unsigned char packed[PBM_BYTES_PER_LINE];
    unsigned char gray[WIDTH];
    for (unsigned page = 0; success && page < pages; ++page) {
        if (fseek(input, raster_offset, SEEK_SET) != 0 ||
            cupsRasterWriteHeader2(raster, &header) == 0) {
            success = false;
            break;
        }
        for (unsigned y = 0; success && y < OUTPUT_HEIGHT; ++y) {
            if (fread(packed, 1, sizeof(packed), input) != sizeof(packed)) {
                success = false;
                break;
            }
            if (urf) {
                for (unsigned x = 0; x < WIDTH; ++x) {
                    gray[x] =
                        (packed[x / 8] & (0x80U >> (x & 7U))) ? 0 : 255;
                }
                success = cupsRasterWritePixels(raster, gray, sizeof(gray)) ==
                          sizeof(gray);
            } else {
                success =
                    cupsRasterWritePixels(raster, packed, sizeof(packed)) ==
                    sizeof(packed);
            }
        }
    }

    if (raster != NULL) {
        cupsRasterClose(raster);
    } else {
        close(output_fd);
    }
    fclose(input);
    if (!success) {
        fprintf(stderr, "failed to create %s raster test page\n", argv[1]);
        unlink(argv[3]);
        return 1;
    }

    printf("created %u-page %s A4 600 dpi test raster: %s\n", pages,
           argv[1], argv[3]);
    return 0;
}
