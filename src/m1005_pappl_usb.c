#include "m1005_pappl_usb.h"
#include "m1005_usb_io.h"

#include <libusb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define HP_VENDOR_ID 0x03f0
#define M1005_PRODUCT_ID 0x3b17
#define PRINTER_CLASS 7
#define TRANSFER_TIMEOUT_MS 10000

typedef struct {
    libusb_context *context;
    libusb_device *device;
    libusb_device_handle *handle;
    int interface_number;
    uint8_t bulk_in_endpoint;
    uint8_t bulk_out_endpoint;
    pappl_job_t *active_job;
    m1005_usb_io_t io;
    bool reset_requested;
} m1005_usb_device_t;

static int bulk_transfer(void *context, uint8_t endpoint,
                         unsigned char *buffer, int length, int *transferred,
                         unsigned timeout_ms) {
    m1005_usb_device_t *usb = context;
    return libusb_bulk_transfer(usb->handle, endpoint, buffer, length,
                                transferred, timeout_ms);
}

static int clear_halt(void *context, uint8_t endpoint) {
    m1005_usb_device_t *usb = context;
    return libusb_clear_halt(usb->handle, endpoint);
}

static bool job_cancelled(void *context) {
    m1005_usb_device_t *usb = context;
    return usb->active_job != NULL && papplJobIsCanceled(usb->active_job);
}

static int find_interface(libusb_device *device, int *interface_number,
                          uint8_t *bulk_in_endpoint,
                          uint8_t *bulk_out_endpoint) {
    struct libusb_config_descriptor *config = NULL;
    int result = libusb_get_active_config_descriptor(device, &config);
    if (result != LIBUSB_SUCCESS) {
        return result;
    }

    result = LIBUSB_ERROR_NOT_FOUND;
    for (uint8_t i = 0; i < config->bNumInterfaces; ++i) {
        const struct libusb_interface *interface = &config->interface[i];
        for (int a = 0; a < interface->num_altsetting; ++a) {
            const struct libusb_interface_descriptor *alternate =
                &interface->altsetting[a];
            if (alternate->bInterfaceClass != PRINTER_CLASS) {
                continue;
            }

            uint8_t input = 0;
            uint8_t output = 0;
            for (uint8_t e = 0; e < alternate->bNumEndpoints; ++e) {
                const struct libusb_endpoint_descriptor *endpoint =
                    &alternate->endpoint[e];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
                    LIBUSB_TRANSFER_TYPE_BULK) {
                    continue;
                }
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                    LIBUSB_ENDPOINT_IN) {
                    input = endpoint->bEndpointAddress;
                } else {
                    output = endpoint->bEndpointAddress;
                }
            }

            if (output != 0) {
                *interface_number = alternate->bInterfaceNumber;
                *bulk_in_endpoint = input;
                *bulk_out_endpoint = output;
                result = LIBUSB_SUCCESS;
                goto done;
            }
        }
    }

done:
    libusb_free_config_descriptor(config);
    return result;
}

static libusb_device *find_device(libusb_context *context) {
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) {
        return NULL;
    }

    libusb_device *match = NULL;
    for (ssize_t i = 0; i < count; ++i) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[i], &descriptor) ==
                LIBUSB_SUCCESS &&
            descriptor.idVendor == HP_VENDOR_ID &&
            descriptor.idProduct == M1005_PRODUCT_ID) {
            match = libusb_ref_device(devices[i]);
            break;
        }
    }

    libusb_free_device_list(devices, 1);
    return match;
}

static bool device_list(pappl_device_cb_t callback, void *data,
                        pappl_deverror_cb_t error_callback, void *error_data) {
    libusb_context *context = NULL;
    int result = libusb_init(&context);
    if (result != LIBUSB_SUCCESS) {
        if (error_callback != NULL) {
            char message[256];
            snprintf(message, sizeof(message), "Unable to initialize libusb: %s",
                     libusb_error_name(result));
            error_callback(message, error_data);
        }
        return false;
    }

    libusb_device *device = find_device(context);
    bool stopped = false;
    if (device != NULL) {
        stopped = callback("HP LaserJet M1005 MFP (USB)", M1005_USB_URI,
                           M1005_DEVICE_ID, data);
        libusb_unref_device(device);
    }

    libusb_exit(context);
    return stopped;
}

static bool device_open(pappl_device_t *device, const char *device_uri,
                        const char *job_name) {
    (void)job_name;

    if (strcmp(device_uri, M1005_USB_URI) != 0) {
        papplDeviceError(device, "Unsupported M1005 device URI '%s'.", device_uri);
        return false;
    }

    m1005_usb_device_t *usb = calloc(1, sizeof(*usb));
    if (usb == NULL) {
        papplDeviceError(device, "Unable to allocate USB state.");
        return false;
    }
    usb->interface_number = -1;

    int result = libusb_init(&usb->context);
    if (result == LIBUSB_SUCCESS) {
        usb->device = find_device(usb->context);
        if (usb->device == NULL) {
            result = LIBUSB_ERROR_NO_DEVICE;
        }
    }
    if (result == LIBUSB_SUCCESS) {
        result = libusb_open(usb->device, &usb->handle);
    }
    if (result == LIBUSB_SUCCESS) {
        result = find_interface(usb->device, &usb->interface_number,
                                &usb->bulk_in_endpoint,
                                &usb->bulk_out_endpoint);
    }
    if (result == LIBUSB_SUCCESS) {
        result = libusb_claim_interface(usb->handle, usb->interface_number);
    }

    if (result != LIBUSB_SUCCESS) {
        papplDeviceError(device, "Unable to open HP LaserJet M1005 USB printer: %s",
                         libusb_error_name(result));
        if (usb->handle != NULL) {
            libusb_close(usb->handle);
        }
        if (usb->device != NULL) {
            libusb_unref_device(usb->device);
        }
        if (usb->context != NULL) {
            libusb_exit(usb->context);
        }
        free(usb);
        return false;
    }

    usb->io.context = usb;
    usb->io.bulk_transfer = bulk_transfer;
    usb->io.clear_halt = clear_halt;
    usb->io.is_cancelled = job_cancelled;
    usb->io.timeout_ms = 1000;
    usb->io.max_retries = 5;
    usb->io.retry_delay_ms = 100;
    papplDeviceSetData(device, usb);
    return true;
}

static void device_close(pappl_device_t *device) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    if (usb == NULL) {
        return;
    }

    bool reset = false;
    if (usb->reset_requested) {
        reset = libusb_reset_device(usb->handle) == LIBUSB_SUCCESS;
    }
    if (!reset) {
        (void)libusb_release_interface(usb->handle, usb->interface_number);
    }

    libusb_close(usb->handle);
    libusb_unref_device(usb->device);
    libusb_exit(usb->context);
    free(usb);
    papplDeviceSetData(device, NULL);
}

static ssize_t device_write(pappl_device_t *device, const void *buffer,
                            size_t bytes) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    ssize_t result = m1005USBWriteAll(&usb->io, usb->bulk_out_endpoint, buffer,
                                      bytes);
    usb->reset_requested = usb->reset_requested || usb->io.reset_requested;
    if (result != (ssize_t)bytes) {
        papplDeviceError(device, "M1005 USB write failed: %s",
                         libusb_error_name(usb->io.last_error));
    }
    return result;
}

static ssize_t device_read(pappl_device_t *device, void *buffer, size_t bytes) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    if (usb->bulk_in_endpoint == 0) {
        return 0;
    }

    int requested = bytes > INT32_MAX ? INT32_MAX : (int)bytes;
    int transferred = 0;
    int result = libusb_bulk_transfer(usb->handle, usb->bulk_in_endpoint, buffer,
                                      requested, &transferred, 1000);
    if (result == LIBUSB_ERROR_TIMEOUT) {
        return 0;
    }
    if (result != LIBUSB_SUCCESS) {
        papplDeviceError(device, "M1005 USB read failed: %s",
                         libusb_error_name(result));
        return -1;
    }
    return transferred;
}

static pappl_preason_t device_status(pappl_device_t *device) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    unsigned char status = 0;
    int result = libusb_control_transfer(
        usb->handle,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_CLASS |
            LIBUSB_RECIPIENT_INTERFACE,
        1, 0, (uint16_t)usb->interface_number, &status, 1,
        TRANSFER_TIMEOUT_MS);
    if (result < 0) {
        return PAPPL_PREASON_OFFLINE;
    }

    pappl_preason_t reasons = PAPPL_PREASON_NONE;
    if ((status & 0x10) == 0) {
        reasons |= PAPPL_PREASON_OFFLINE;
    }
    if ((status & 0x20) != 0) {
        reasons |= PAPPL_PREASON_MEDIA_EMPTY;
    }
    if ((status & 0x08) == 0) {
        reasons |= PAPPL_PREASON_OTHER;
    }
    return reasons;
}

static char *device_id(pappl_device_t *device, char *buffer, size_t buffer_size) {
    (void)device;
    if (buffer_size > 0) {
        snprintf(buffer, buffer_size, "%s", M1005_DEVICE_ID);
    }
    return buffer;
}

void m1005PapplUSBRegister(void) {
    papplDeviceAddScheme(M1005_USB_SCHEME, PAPPL_DEVTYPE_CUSTOM_LOCAL,
                         device_list, device_open, device_close, device_read,
                         device_write, device_status, device_id);
}

void m1005PapplUSBBeginJob(pappl_device_t *device, pappl_job_t *job) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    if (usb != NULL) {
        usb->active_job = job;
    }
}

void m1005PapplUSBEndJob(pappl_device_t *device) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    if (usb != NULL) {
        usb->active_job = NULL;
    }
}

ssize_t m1005PapplUSBWrite(pappl_device_t *device, const void *buffer,
                           size_t bytes) {
    return device_write(device, buffer, bytes);
}

void m1005PapplUSBRequestReset(pappl_device_t *device) {
    m1005_usb_device_t *usb = papplDeviceGetData(device);
    if (usb != NULL) {
        usb->reset_requested = true;
    }
}
