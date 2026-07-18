#define _POSIX_C_SOURCE 200809L

#include "m1005_usb_io.h"

#include <errno.h>
#include <libusb.h>
#include <limits.h>
#include <time.h>

#define M1005_USB_TRANSFER_CHUNK 16384U

static void retry_delay(unsigned milliseconds) {
    if (milliseconds == 0) {
        return;
    }
    struct timespec delay = {
        .tv_sec = (time_t)(milliseconds / 1000U),
        .tv_nsec = (long)(milliseconds % 1000U) * 1000000L
    };
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

static bool retryable_error(int error) {
    return error == LIBUSB_ERROR_TIMEOUT || error == LIBUSB_ERROR_INTERRUPTED ||
           error == LIBUSB_ERROR_BUSY || error == LIBUSB_ERROR_IO ||
           error == LIBUSB_ERROR_PIPE;
}

static ssize_t partial_or_error(size_t requested, size_t remaining) {
    return remaining < requested ? (ssize_t)(requested - remaining) : -1;
}

ssize_t m1005USBWriteAll(m1005_usb_io_t *io, uint8_t endpoint,
                         const void *buffer, size_t bytes) {
    if (io == NULL || io->bulk_transfer == NULL || buffer == NULL ||
        bytes > (size_t)SSIZE_MAX) {
        return -1;
    }

    const unsigned char *current = buffer;
    size_t remaining = bytes;
    unsigned retries = 0;
    io->last_error = LIBUSB_SUCCESS;
    io->reset_requested = false;

    while (remaining > 0) {
        if (io->is_cancelled != NULL && io->is_cancelled(io->context)) {
            io->last_error = LIBUSB_ERROR_INTERRUPTED;
            io->reset_requested = true;
            return partial_or_error(bytes, remaining);
        }

        int requested = remaining > M1005_USB_TRANSFER_CHUNK
                            ? (int)M1005_USB_TRANSFER_CHUNK
                            : (int)remaining;
        int transferred = 0;
        int result = io->bulk_transfer(io->context, endpoint,
                                       (unsigned char *)current, requested,
                                       &transferred, io->timeout_ms);
        if (transferred < 0 || transferred > requested) {
            result = LIBUSB_ERROR_IO;
            transferred = 0;
        }

        if (transferred > 0) {
            current += transferred;
            remaining -= (size_t)transferred;
            retries = 0;
            if (remaining == 0) {
                io->last_error = LIBUSB_SUCCESS;
                return (ssize_t)bytes;
            }
            if (result == LIBUSB_SUCCESS || result == LIBUSB_ERROR_TIMEOUT) {
                continue;
            }
        }

        if (result == LIBUSB_SUCCESS) {
            result = LIBUSB_ERROR_IO;
        }
        io->last_error = result;

        if (result == LIBUSB_ERROR_PIPE && io->clear_halt != NULL &&
            io->clear_halt(io->context, endpoint) != LIBUSB_SUCCESS) {
            io->reset_requested = true;
            return partial_or_error(bytes, remaining);
        }
        if (!retryable_error(result) || retries++ >= io->max_retries) {
            io->reset_requested = true;
            return partial_or_error(bytes, remaining);
        }
        retry_delay(io->retry_delay_ms);
    }

    return (ssize_t)bytes;
}
