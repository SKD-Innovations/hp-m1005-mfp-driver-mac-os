#include "m1005_pappl_usb.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pappl/pappl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define APP_VERSION "0.5.2"
#define DRIVER_NAME "hp-laserjet-m1005-600dpi"
#define XQX_MIME_TYPE "application/vnd.hp-xqx"
#define A4_WIDTH 4960U
#define PAPPL_A4_HEIGHT 7015U
#define M1005_A4_HEIGHT 7016U
#define A4_BYTES_PER_LINE 620U

extern char **environ;
extern void _papplPrinterInitDriverData(pappl_pr_driver_data_t *data);

typedef struct {
    FILE *pbm;
    char pbm_path[PATH_MAX];
    char xqx_path[PATH_MAX];
    unsigned page_height;
    unsigned lines_written;
    unsigned pages;
    bool failed;
} m1005_job_data_t;

static char encoder_path[PATH_MAX] = "build/m1005-xqx-encode";

static bool make_directory_tree(const char *path) {
    char current[PATH_MAX];
    int written = snprintf(current, sizeof(current), "%s", path);
    if (written < 0 || (size_t)written >= sizeof(current)) {
        return false;
    }

    for (char *slash = current + 1; *slash != '\0'; ++slash) {
        if (*slash != '/') {
            continue;
        }
        *slash = '\0';
        if (mkdir(current, 0700) < 0 && errno != EEXIST) {
            return false;
        }
        *slash = '/';
    }
    return mkdir(current, 0700) == 0 || errno == EEXIST;
}

static void cleanup_job_data(m1005_job_data_t *job_data) {
    if (job_data == NULL) {
        return;
    }
    if (job_data->pbm != NULL) {
        fclose(job_data->pbm);
    }
    if (job_data->pbm_path[0] != '\0') {
        unlink(job_data->pbm_path);
    }
    if (job_data->xqx_path[0] != '\0') {
        unlink(job_data->xqx_path);
    }
    free(job_data);
}

static bool make_temp_file(char *path, size_t path_size, const char *suffix,
                           FILE **stream) {
    int written = snprintf(path, path_size, "/private/tmp/m1005-%s-XXXXXX",
                           suffix);
    if (written < 0 || (size_t)written >= path_size) {
        return false;
    }

    int descriptor = mkstemp(path);
    if (descriptor < 0) {
        return false;
    }
    if (stream == NULL) {
        close(descriptor);
        return true;
    }

    *stream = fdopen(descriptor, "w+b");
    if (*stream == NULL) {
        close(descriptor);
        unlink(path);
        path[0] = '\0';
        return false;
    }
    return true;
}

static bool encode_xqx(pappl_job_t *job, const char *pbm_path,
                       const char *xqx_path, int copies, const char *title,
                       const char *username) {
    char copies_value[32];
    snprintf(copies_value, sizeof(copies_value), "%d", copies);

    char *arguments[] = {
        encoder_path,
        "-r600x600", "-g4960x7016", "-p9", "-m1", "-n", copies_value,
        "-d1", "-s7", "-u88x84", "-l88x84", "-L3", "-T3",
        "-J", (char *)(title != NULL ? title : "Untitled"),
        "-U", (char *)(username != NULL ? username : "unknown"),
        NULL
    };

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        return false;
    }

    int result = posix_spawn_file_actions_addopen(
        &actions, STDIN_FILENO, pbm_path, O_RDONLY, 0);
    if (result == 0) {
        result = posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, xqx_path,
            O_WRONLY | O_CREAT | O_TRUNC, 0600);
    }

    pid_t process = 0;
    if (result == 0) {
        result = posix_spawn(&process, encoder_path, &actions, NULL, arguments,
                             environ);
    }
    posix_spawn_file_actions_destroy(&actions);
    if (result != 0) {
        return false;
    }

    int status = 0;
    for (;;) {
        result = waitpid(process, &status, WNOHANG);
        if (result == process) {
            break;
        }
        if (result < 0 && errno != EINTR) {
            return false;
        }
        if (job != NULL && papplJobIsCanceled(job)) {
            (void)kill(process, SIGTERM);
            do {
                result = waitpid(process, &status, 0);
            } while (result < 0 && errno == EINTR);
            return false;
        }
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000L};
        (void)nanosleep(&delay, NULL);
    }

    return result == process && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static bool send_xqx(pappl_job_t *job, pappl_device_t *device,
                     const char *path) {
    FILE *input = fopen(path, "rb");
    if (input == NULL) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unable to open encoded XQX: %s",
                    strerror(errno));
        return false;
    }

    unsigned char buffer[65536];
    bool success = true;
    bool wrote_data = false;
    size_t total_written = 0;
    papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Starting M1005 USB transmission.");
    m1005PapplUSBBeginJob(device, job);
    while (!papplJobIsCanceled(job)) {
        size_t bytes = fread(buffer, 1, sizeof(buffer), input);
        if (bytes == 0) {
            if (ferror(input)) {
                papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                            "Unable to read encoded XQX: %s", strerror(errno));
                success = false;
            }
            break;
        }
        ssize_t written = m1005PapplUSBWrite(device, buffer, bytes);
        if (written > 0) {
            wrote_data = true;
            total_written += (size_t)written;
        }
        if (written != (ssize_t)bytes) {
            if (!papplJobIsCanceled(job)) {
                papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                            "Unable to send XQX data to the printer.");
                success = false;
            }
            break;
        }
    }

    fclose(input);
    if ((papplJobIsCanceled(job) && wrote_data) || !success) {
        m1005PapplUSBRequestReset(device);
    }
    m1005PapplUSBEndJob(device);
    if (papplJobIsCanceled(job)) {
        papplLogJob(job, PAPPL_LOGLEVEL_INFO,
                    "USB transmission canceled after %lu bytes; reset requested.",
                    (unsigned long)total_written);
    } else if (success) {
        papplLogJob(job, PAPPL_LOGLEVEL_INFO,
                    "Completed M1005 USB transmission of %lu bytes.",
                    (unsigned long)total_written);
    }
    return success;
}

static bool print_xqx_file(pappl_job_t *job, pappl_pr_options_t *options,
                           pappl_device_t *device) {
    (void)options;
    return send_xqx(job, device, papplJobGetFilename(job));
}

static bool raster_start_job(pappl_job_t *job, pappl_pr_options_t *options,
                             pappl_device_t *device) {
    (void)options;
    (void)device;

    m1005_job_data_t *job_data = calloc(1, sizeof(*job_data));
    if (job_data == NULL ||
        !make_temp_file(job_data->pbm_path, sizeof(job_data->pbm_path), "pbm",
                        &job_data->pbm) ||
        !make_temp_file(job_data->xqx_path, sizeof(job_data->xqx_path), "xqx",
                        NULL)) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                    "Unable to create temporary encoder files: %s",
                    strerror(errno));
        cleanup_job_data(job_data);
        return false;
    }

    papplJobSetData(job, job_data);
    return true;
}

static bool raster_start_page(pappl_job_t *job, pappl_pr_options_t *options,
                              pappl_device_t *device, unsigned page) {
    (void)device;
    (void)page;
    m1005_job_data_t *job_data = papplJobGetData(job);
    const cups_page_header2_t *header = &options->header;

    if (header->cupsWidth != A4_WIDTH ||
        (header->cupsHeight != PAPPL_A4_HEIGHT &&
         header->cupsHeight != M1005_A4_HEIGHT) ||
        header->cupsBitsPerPixel != 1 ||
        header->cupsBytesPerLine != A4_BYTES_PER_LINE ||
        header->cupsColorSpace != CUPS_CSPACE_K ||
        header->HWResolution[0] != 600 || header->HWResolution[1] != 600) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                    "Unsupported raster page %ux%ux%u at %ux%u dpi.",
                    header->cupsWidth, header->cupsHeight,
                    header->cupsBitsPerPixel, header->HWResolution[0],
                    header->HWResolution[1]);
        job_data->failed = true;
        return false;
    }

    if (fprintf(job_data->pbm, "P4\n%u %u\n", A4_WIDTH,
                M1005_A4_HEIGHT) < 0) {
        job_data->failed = true;
        return false;
    }
    job_data->page_height = header->cupsHeight;
    job_data->lines_written = 0;
    return true;
}

static bool raster_write_line(pappl_job_t *job, pappl_pr_options_t *options,
                              pappl_device_t *device, unsigned y,
                              const unsigned char *line) {
    (void)options;
    (void)device;
    m1005_job_data_t *job_data = papplJobGetData(job);
    if (job_data->failed || y != job_data->lines_written ||
        fwrite(line, 1, A4_BYTES_PER_LINE, job_data->pbm) !=
            A4_BYTES_PER_LINE) {
        job_data->failed = true;
        return false;
    }
    job_data->lines_written++;
    return true;
}

static bool raster_end_page(pappl_job_t *job, pappl_pr_options_t *options,
                            pappl_device_t *device, unsigned page) {
    (void)options;
    (void)device;
    (void)page;
    m1005_job_data_t *job_data = papplJobGetData(job);
    if (job_data->failed || job_data->lines_written != job_data->page_height) {
        return false;
    }

    if (job_data->page_height == PAPPL_A4_HEIGHT) {
        unsigned char white[A4_BYTES_PER_LINE] = {0};
        if (fwrite(white, 1, sizeof(white), job_data->pbm) != sizeof(white)) {
            job_data->failed = true;
            return false;
        }
    }
    job_data->pages++;
    return true;
}

static bool raster_end_job(pappl_job_t *job, pappl_pr_options_t *options,
                           pappl_device_t *device) {
    m1005_job_data_t *job_data = papplJobGetData(job);
    papplJobSetData(job, NULL);

    if (job_data->pbm != NULL) {
        if (fclose(job_data->pbm) != 0) {
            job_data->failed = true;
        }
        job_data->pbm = NULL;
    }

    bool success = !job_data->failed && job_data->pages > 0;
    if (papplJobIsCanceled(job)) {
        success = true;
    } else if (success) {
        papplLogJob(job, PAPPL_LOGLEVEL_INFO,
                    "Starting isolated M1005 XQX encoder.");
        success = encode_xqx(job, job_data->pbm_path, job_data->xqx_path,
                             options->copies, papplJobGetName(job),
                             papplJobGetUsername(job));
        if (!success) {
            if (papplJobIsCanceled(job)) {
                papplLogJob(job, PAPPL_LOGLEVEL_INFO,
                            "XQX encoding stopped after cancellation.");
                success = true;
            } else {
                papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                            "The M1005 XQX encoder failed.");
            }
        } else {
            papplLogJob(job, PAPPL_LOGLEVEL_INFO,
                        "Completed isolated M1005 XQX encoding.");
        }
    }
    if (success && !papplJobIsCanceled(job)) {
        success = send_xqx(job, device, job_data->xqx_path);
    }

    cleanup_job_data(job_data);
    return success;
}

static const char *auto_add(const char *device_info, const char *device_uri,
                            const char *device_id, void *data) {
    (void)device_info;
    (void)device_id;
    (void)data;
    if (device_uri != NULL &&
        strncmp(device_uri, M1005_USB_SCHEME ":",
                strlen(M1005_USB_SCHEME) + 1) == 0) {
        return DRIVER_NAME;
    }
    return NULL;
}

static bool driver_callback(pappl_system_t *system, const char *driver_name,
                            const char *device_uri, const char *device_id,
                            pappl_pr_driver_data_t *driver_data,
                            ipp_t **driver_attributes, void *data) {
    (void)system;
    (void)device_uri;
    (void)device_id;
    (void)data;
    if (driver_name == NULL || strcmp(driver_name, DRIVER_NAME) != 0 ||
        driver_data == NULL || driver_attributes == NULL) {
        return false;
    }

    driver_data->printfile_cb = print_xqx_file;
    driver_data->rstartjob_cb = raster_start_job;
    driver_data->rstartpage_cb = raster_start_page;
    driver_data->rwriteline_cb = raster_write_line;
    driver_data->rendpage_cb = raster_end_page;
    driver_data->rendjob_cb = raster_end_job;
    driver_data->format = XQX_MIME_TYPE;

    snprintf(driver_data->make_and_model, sizeof(driver_data->make_and_model),
             "HP LaserJet M1005 MFP");
    driver_data->kind = PAPPL_KIND_DOCUMENT;
    driver_data->ppm = 14;
    driver_data->orient_default = IPP_ORIENT_NONE;
    driver_data->quality_default = IPP_QUALITY_HIGH;
    driver_data->scaling_default = PAPPL_SCALING_AUTO;

    driver_data->color_supported = PAPPL_COLOR_MODE_MONOCHROME;
    driver_data->color_default = PAPPL_COLOR_MODE_MONOCHROME;
    driver_data->raster_types = PAPPL_PWG_RASTER_TYPE_BLACK_1;
    driver_data->force_raster_type = PAPPL_PWG_RASTER_TYPE_BLACK_1;

    driver_data->num_resolution = 1;
    driver_data->x_resolution[0] = 600;
    driver_data->y_resolution[0] = 600;
    driver_data->x_default = 600;
    driver_data->y_default = 600;

    driver_data->duplex = PAPPL_DUPLEX_NONE;
    driver_data->sides_supported = PAPPL_SIDES_ONE_SIDED;
    driver_data->sides_default = PAPPL_SIDES_ONE_SIDED;
    driver_data->left_right = 373;
    driver_data->bottom_top = 356;
    driver_data->borderless = false;

    driver_data->num_media = 1;
    driver_data->media[0] = "iso_a4_210x297mm";
    driver_data->num_source = 1;
    driver_data->source[0] = "main";
    driver_data->num_type = 1;
    driver_data->type[0] = "stationery";
    driver_data->num_bin = 1;
    driver_data->bin[0] = "face-down";

    pwg_media_t *a4 = pwgMediaForPWG("iso_a4_210x297mm");
    pappl_media_col_t *ready = &driver_data->media_ready[0];
    snprintf(ready->size_name, sizeof(ready->size_name), "iso_a4_210x297mm");
    snprintf(ready->source, sizeof(ready->source), "main");
    snprintf(ready->type, sizeof(ready->type), "stationery");
    ready->size_width = a4->width;
    ready->size_length = a4->length;
    ready->left_margin = ready->right_margin = driver_data->left_right;
    ready->top_margin = ready->bottom_margin = driver_data->bottom_top;
    driver_data->media_default = *ready;

    *driver_attributes = NULL;
    return true;
}

static int dither_self_test(void) {
    pappl_pr_driver_data_t driver_data;
    pappl_dither_t original_graphics;
    pappl_dither_t original_photo;
    ipp_t *driver_attributes = NULL;
    bool graphics_values[256] = {false};
    bool photo_values[256] = {false};
    unsigned graphics_unique = 0;
    unsigned photo_unique = 0;

    _papplPrinterInitDriverData(&driver_data);
    memcpy(original_graphics, driver_data.gdither, sizeof(original_graphics));
    memcpy(original_photo, driver_data.pdither, sizeof(original_photo));

    if (!driver_callback(NULL, DRIVER_NAME, NULL, NULL, &driver_data,
                         &driver_attributes, NULL)) {
        fputs("Unable to configure driver data for dither self-test.\n",
              stderr);
        return 1;
    }

    for (size_t index = 0; index < sizeof(driver_data.gdither); ++index) {
        unsigned graphics = ((unsigned char *)driver_data.gdither)[index];
        unsigned photo = ((unsigned char *)driver_data.pdither)[index];
        if (!graphics_values[graphics]) {
            graphics_values[graphics] = true;
            graphics_unique++;
        }
        if (!photo_values[photo]) {
            photo_values[photo] = true;
            photo_unique++;
        }
    }

    if (memcmp(original_graphics, driver_data.gdither,
               sizeof(original_graphics)) != 0 ||
        memcmp(original_photo, driver_data.pdither, sizeof(original_photo)) !=
            0 ||
        graphics_unique < 200 || photo_unique != 256 ||
        driver_data.quality_default != IPP_QUALITY_HIGH ||
        driver_data.color_supported != PAPPL_COLOR_MODE_MONOCHROME) {
        fprintf(stderr,
                "Invalid halftone configuration (%u graphics levels, %u "
                "photo levels).\n",
                graphics_unique, photo_unique);
        return 1;
    }

    printf("halftone=enabled\ngraphics-levels=%u\nphoto-levels=%u\n"
           "default-quality=high\ncolor-modes=monochrome\n",
           graphics_unique, photo_unique);
    return 0;
}

static void set_encoder_path(const char *program) {
    const char *override = getenv("M1005_ENCODER_PATH");
    if (override != NULL && override[0] != '\0') {
        snprintf(encoder_path, sizeof(encoder_path), "%s", override);
        return;
    }

    char resolved[PATH_MAX];
    if (realpath(program, resolved) == NULL) {
        char executable[PATH_MAX];
        uint32_t executable_size = sizeof(executable);
        if (_NSGetExecutablePath(executable, &executable_size) != 0 ||
            realpath(executable, resolved) == NULL) {
            return;
        }
    }
    char *slash = strrchr(resolved, '/');
    if (slash == NULL) {
        return;
    }
    *slash = '\0';
    snprintf(encoder_path, sizeof(encoder_path), "%s/m1005-xqx-encode", resolved);
}

static int self_test(const char *input, const char *output) {
    if (!encode_xqx(NULL, input, output, 1, "M1005 Phase 1", "Codex")) {
        fprintf(stderr, "Phase 3 encoder bridge self-test failed.\n");
        return 1;
    }
    printf("driver=%s\n", DRIVER_NAME);
    printf("media=iso_a4_210x297mm\nresolution=600x600\n");
    printf("color=monochrome\nsides=one-sided\n");
    printf("raster=image/pwg-raster,image/urf\nusb=%04x:%04x\n", 0x03f0,
           0x3b17);
    return 0;
}

static int run_mainloop(int argc, char *argv[]) {
    m1005PapplUSBRegister();
    pappl_pr_driver_t drivers[] = {
        {DRIVER_NAME, "HP LaserJet M1005 MFP (600 dpi)", NULL, NULL}
    };
    return papplMainloop(argc, argv, APP_VERSION,
                         "HP LaserJet M1005 MFP Printer Application",
                         (int)(sizeof(drivers) / sizeof(drivers[0])), drivers,
                         auto_add, driver_callback, NULL, NULL, NULL, NULL, NULL);
}

static int run_managed_service(char *program) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] != '/') {
        fputs("HOME is not an absolute path; managed service cannot start.\n",
              stderr);
        return 1;
    }

    char data_directory[PATH_MAX];
    char spool_option[PATH_MAX + 32];
    char log_directory[PATH_MAX];
    char log_option[PATH_MAX + 32];
    int data_written = snprintf(data_directory, sizeof(data_directory),
                                "%s/Library/Application Support/M1005Printer",
                                home);
    int spool_written = snprintf(spool_option, sizeof(spool_option),
                                 "spool-directory=%s/spool", data_directory);
    int log_written = snprintf(log_directory, sizeof(log_directory),
                               "%s/Library/Logs/M1005Printer", home);
    int option_written = snprintf(log_option, sizeof(log_option),
                                  "log-file=%s/service.log", log_directory);
    if (data_written < 0 || (size_t)data_written >= sizeof(data_directory) ||
        spool_written < 0 || (size_t)spool_written >= sizeof(spool_option) ||
        log_written < 0 || (size_t)log_written >= sizeof(log_directory) ||
        option_written < 0 || (size_t)option_written >= sizeof(log_option) ||
        !make_directory_tree(data_directory) ||
        !make_directory_tree(log_directory)) {
        fprintf(stderr, "Unable to create managed service directories: %s\n",
                strerror(errno));
        return 1;
    }
    if (setenv("XDG_CONFIG_HOME", data_directory, 1) < 0) {
        fprintf(stderr, "Unable to configure managed service state path: %s\n",
                strerror(errno));
        return 1;
    }

    char *managed_argv[] = {
        program,
        "server",
        "-o", spool_option,
        "-o", "server-port=8765",
        "-o", "log-level=info",
        "-o", log_option,
        "-o", "server-options=no-tls",
        NULL
    };
    return run_mainloop(12, managed_argv);
}

int main(int argc, char *argv[]) {
    set_encoder_path(argv[0]);
    if (argc == 1 && strstr(argv[0], "m1005-printer-service") != NULL) {
        return run_managed_service(argv[0]);
    }
    if (argc == 2 && strcmp(argv[1], "--usb-status") == 0) {
        bool present = m1005PapplUSBIsPresent();
        puts(present ? "connected" : "disconnected");
        return present ? 0 : 1;
    }
    if (argc == 2 && strcmp(argv[1], "--managed-service") == 0) {
        return run_managed_service(argv[0]);
    }
    if (argc == 2 && strcmp(argv[1], "--dither-self-test") == 0) {
        return dither_self_test();
    }
    if (argc == 4 && strcmp(argv[1], "--self-test") == 0) {
        return self_test(argv[2], argv[3]);
    }
    return run_mainloop(argc, argv);
}
