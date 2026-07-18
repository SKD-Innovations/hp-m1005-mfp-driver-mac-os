#ifndef M1005_USB_IO_H
#define M1005_USB_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef int (*m1005_usb_bulk_transfer_cb_t)(void *context, uint8_t endpoint,
                                            unsigned char *buffer, int length,
                                            int *transferred,
                                            unsigned timeout_ms);
typedef int (*m1005_usb_clear_halt_cb_t)(void *context, uint8_t endpoint);
typedef bool (*m1005_usb_cancel_cb_t)(void *context);

typedef struct {
    void *context;
    m1005_usb_bulk_transfer_cb_t bulk_transfer;
    m1005_usb_clear_halt_cb_t clear_halt;
    m1005_usb_cancel_cb_t is_cancelled;
    unsigned timeout_ms;
    unsigned max_retries;
    unsigned retry_delay_ms;
    int last_error;
    bool reset_requested;
} m1005_usb_io_t;

ssize_t m1005USBWriteAll(m1005_usb_io_t *io, uint8_t endpoint,
                         const void *buffer, size_t bytes);

#endif
