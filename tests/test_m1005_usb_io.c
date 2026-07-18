#include "m1005_usb_io.h"

#include <assert.h>
#include <libusb.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int result;
    int transferred;
} event_t;

typedef struct {
    const event_t *events;
    size_t num_events;
    size_t next_event;
    int calls;
    int clear_calls;
    int cancel_after_calls;
} mock_t;

static int mock_transfer(void *context, uint8_t endpoint, unsigned char *buffer,
                         int length, int *transferred, unsigned timeout_ms) {
    (void)endpoint;
    (void)buffer;
    (void)timeout_ms;
    mock_t *mock = context;
    mock->calls++;
    if (mock->next_event >= mock->num_events) {
        *transferred = length;
        return LIBUSB_SUCCESS;
    }
    event_t event = mock->events[mock->next_event++];
    *transferred = event.transferred;
    return event.result;
}

static int mock_clear_halt(void *context, uint8_t endpoint) {
    (void)endpoint;
    mock_t *mock = context;
    mock->clear_calls++;
    return LIBUSB_SUCCESS;
}

static bool mock_cancelled(void *context) {
    mock_t *mock = context;
    return mock->cancel_after_calls >= 0 &&
           mock->calls >= mock->cancel_after_calls;
}

static m1005_usb_io_t make_io(mock_t *mock) {
    m1005_usb_io_t io = {
        .context = mock,
        .bulk_transfer = mock_transfer,
        .clear_halt = mock_clear_halt,
        .is_cancelled = mock_cancelled,
        .timeout_ms = 1000,
        .max_retries = 5,
        .retry_delay_ms = 0
    };
    return io;
}

int main(void) {
    unsigned char data[40000];
    memset(data, 0xa5, sizeof(data));

    const event_t partial_events[] = {
        {LIBUSB_SUCCESS, 1000},
        {LIBUSB_SUCCESS, 15384}
    };
    mock_t partial = {partial_events, 2, 0, 0, 0, -1};
    m1005_usb_io_t io = make_io(&partial);
    assert(m1005USBWriteAll(&io, 0x02, data, 20000) == 20000);
    assert(partial.calls == 3);

    const event_t timeout_events[] = {
        {LIBUSB_ERROR_TIMEOUT, 4096},
        {LIBUSB_SUCCESS, 12288}
    };
    mock_t timeout = {timeout_events, 2, 0, 0, 0, -1};
    io = make_io(&timeout);
    assert(m1005USBWriteAll(&io, 0x02, data, 20000) == 20000);
    assert(timeout.calls == 3);

    const event_t stall_events[] = {
        {LIBUSB_ERROR_PIPE, 0},
        {LIBUSB_SUCCESS, 16384}
    };
    mock_t stall = {stall_events, 2, 0, 0, 0, -1};
    io = make_io(&stall);
    assert(m1005USBWriteAll(&io, 0x02, data, 20000) == 20000);
    assert(stall.clear_calls == 1);

    const event_t retry_events[] = {
        {LIBUSB_ERROR_TIMEOUT, 0}, {LIBUSB_ERROR_TIMEOUT, 0},
        {LIBUSB_ERROR_TIMEOUT, 0}, {LIBUSB_ERROR_TIMEOUT, 0},
        {LIBUSB_ERROR_TIMEOUT, 0}, {LIBUSB_ERROR_TIMEOUT, 0}
    };
    mock_t retry = {retry_events, 6, 0, 0, 0, -1};
    io = make_io(&retry);
    assert(m1005USBWriteAll(&io, 0x02, data, 1000) == -1);
    assert(retry.calls == 6);
    assert(io.reset_requested);

    mock_t cancel = {NULL, 0, 0, 0, 0, 1};
    io = make_io(&cancel);
    assert(m1005USBWriteAll(&io, 0x02, data, 20000) == 16384);
    assert(cancel.calls == 1);
    assert(io.last_error == LIBUSB_ERROR_INTERRUPTED);
    assert(io.reset_requested);

    const event_t gone_events[] = {{LIBUSB_ERROR_NO_DEVICE, 0}};
    mock_t gone = {gone_events, 1, 0, 0, 0, -1};
    io = make_io(&gone);
    assert(m1005USBWriteAll(&io, 0x02, data, 1000) == -1);
    assert(gone.calls == 1);
    assert(io.last_error == LIBUSB_ERROR_NO_DEVICE);

    puts("M1005 USB retry state-machine tests passed.");
    return 0;
}
