#include <errno.h>
#include <libusb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HP_VENDOR_ID 0x03f0
#define M1005_PRODUCT_ID 0x3b17
#define PRINTER_CLASS 7
#define TRANSFER_CHUNK 16384
#define TRANSFER_TIMEOUT_MS 10000

static volatile sig_atomic_t interrupted = 0;

static void handle_signal(int signal_number) {
    (void)signal_number;
    interrupted = 1;
}

static const char *transfer_type(uint8_t attributes) {
    switch (attributes & LIBUSB_TRANSFER_TYPE_MASK) {
        case LIBUSB_TRANSFER_TYPE_CONTROL: return "control";
        case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "isochronous";
        case LIBUSB_TRANSFER_TYPE_BULK: return "bulk";
        case LIBUSB_TRANSFER_TYPE_INTERRUPT: return "interrupt";
        default: return "unknown";
    }
}

static void print_device_layout(libusb_device *device,
                                const struct libusb_device_descriptor *descriptor) {
    printf("device %04x:%04x USB %x.%02x, %u configuration(s)\n",
           descriptor->idVendor, descriptor->idProduct,
           descriptor->bcdUSB >> 8, descriptor->bcdUSB & 0xff,
           descriptor->bNumConfigurations);

    for (uint8_t config_index = 0; config_index < descriptor->bNumConfigurations;
         ++config_index) {
        struct libusb_config_descriptor *config = NULL;
        int rc = libusb_get_config_descriptor(device, config_index, &config);
        if (rc != LIBUSB_SUCCESS) {
            fprintf(stderr, "cannot read configuration %u: %s\n",
                    config_index, libusb_error_name(rc));
            continue;
        }

        printf("configuration %u: value=%u interfaces=%u attributes=0x%02x max-power=%u mA\n",
               config_index, config->bConfigurationValue, config->bNumInterfaces,
               config->bmAttributes, config->MaxPower * 2);
        for (uint8_t interface_index = 0; interface_index < config->bNumInterfaces;
             ++interface_index) {
            const struct libusb_interface *interface = &config->interface[interface_index];
            for (int alternate_index = 0; alternate_index < interface->num_altsetting;
                 ++alternate_index) {
                const struct libusb_interface_descriptor *alternate =
                    &interface->altsetting[alternate_index];
                printf("  interface %u alt %u: class=%u subclass=%u protocol=%u endpoints=%u%s\n",
                       alternate->bInterfaceNumber, alternate->bAlternateSetting,
                       alternate->bInterfaceClass, alternate->bInterfaceSubClass,
                       alternate->bInterfaceProtocol, alternate->bNumEndpoints,
                       alternate->bInterfaceClass == PRINTER_CLASS ? " [printer]" : "");
                for (uint8_t endpoint_index = 0;
                     endpoint_index < alternate->bNumEndpoints; ++endpoint_index) {
                    const struct libusb_endpoint_descriptor *endpoint =
                        &alternate->endpoint[endpoint_index];
                    printf("    endpoint 0x%02x: %s %s max-packet=%u interval=%u\n",
                           endpoint->bEndpointAddress,
                           (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                                   LIBUSB_ENDPOINT_IN ? "IN" : "OUT",
                           transfer_type(endpoint->bmAttributes),
                           endpoint->wMaxPacketSize, endpoint->bInterval);
                }
            }
        }
        libusb_free_config_descriptor(config);
    }
}

static int find_printer_interface(libusb_device *device, int *interface_number,
                                  uint8_t *bulk_out_endpoint) {
    struct libusb_config_descriptor *config = NULL;
    int rc = libusb_get_active_config_descriptor(device, &config);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "cannot read active configuration: %s\n", libusb_error_name(rc));
        return rc;
    }

    rc = LIBUSB_ERROR_NOT_FOUND;
    for (uint8_t index = 0; index < config->bNumInterfaces; ++index) {
        const struct libusb_interface *interface = &config->interface[index];
        for (int alternate_index = 0; alternate_index < interface->num_altsetting;
             ++alternate_index) {
            const struct libusb_interface_descriptor *alternate =
                &interface->altsetting[alternate_index];
            if (alternate->bInterfaceClass != PRINTER_CLASS) {
                continue;
            }
            for (uint8_t endpoint_index = 0;
                 endpoint_index < alternate->bNumEndpoints; ++endpoint_index) {
                const struct libusb_endpoint_descriptor *endpoint =
                    &alternate->endpoint[endpoint_index];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) ==
                        LIBUSB_TRANSFER_TYPE_BULK &&
                    (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                        LIBUSB_ENDPOINT_OUT) {
                    *interface_number = alternate->bInterfaceNumber;
                    *bulk_out_endpoint = endpoint->bEndpointAddress;
                    rc = LIBUSB_SUCCESS;
                    break;
                }
            }
        }
    }

    libusb_free_config_descriptor(config);
    return rc;
}

static void print_port_status(libusb_device_handle *handle, int interface_number) {
    unsigned char status = 0;
    int rc = libusb_control_transfer(
        handle,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
        1, 0, (uint16_t)interface_number, &status, 1, TRANSFER_TIMEOUT_MS);
    if (rc < 0) {
        printf("printer port status unavailable: %s\n", libusb_error_name(rc));
        return;
    }
    printf("printer port status: 0x%02x (selected=%s paper-empty=%s error=%s)\n",
           status, (status & 0x10) ? "yes" : "no",
           (status & 0x20) ? "yes" : "no",
           (status & 0x08) ? "no" : "yes");
}

static int send_file(libusb_device_handle *handle, uint8_t endpoint, const char *path) {
    FILE *input = fopen(path, "rb");
    if (input == NULL) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    unsigned char buffer[TRANSFER_CHUNK];
    size_t total = 0;
    int result = 0;
    while (!interrupted) {
        size_t count = fread(buffer, 1, sizeof(buffer), input);
        if (count == 0) {
            if (ferror(input)) {
                fprintf(stderr, "cannot read %s: %s\n", path, strerror(errno));
                result = 1;
            }
            break;
        }

        size_t offset = 0;
        while (offset < count && !interrupted) {
            int transferred = 0;
            int rc = libusb_bulk_transfer(handle, endpoint, buffer + offset,
                                          (int)(count - offset), &transferred,
                                          TRANSFER_TIMEOUT_MS);
            if (rc != LIBUSB_SUCCESS) {
                fprintf(stderr, "USB write failed after %zu bytes: %s\n",
                        total, libusb_error_name(rc));
                result = 1;
                goto done;
            }
            if (transferred <= 0) {
                fprintf(stderr, "USB write made no progress after %zu bytes\n", total);
                result = 1;
                goto done;
            }
            offset += (size_t)transferred;
            total += (size_t)transferred;
        }
    }

done:
    fclose(input);
    if (interrupted) {
        fprintf(stderr, "USB transmission cancelled after %zu bytes\n", total);
        return 130;
    }
    if (result == 0) {
        printf("sent %zu bytes to endpoint 0x%02x\n", total, endpoint);
    }
    return result;
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s --probe | --claim | --send FILE\n"
            "  --probe       enumerate descriptors without claiming an interface\n"
            "  --claim       claim interface 1, read status, and release it\n"
            "  --send FILE   claim interface 1 and transmit an XQX stream\n",
            program);
}

int main(int argc, char **argv) {
    enum { MODE_NONE, MODE_PROBE, MODE_CLAIM, MODE_SEND } mode = MODE_NONE;
    const char *path = NULL;
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
        mode = MODE_PROBE;
    } else if (argc == 2 && strcmp(argv[1], "--claim") == 0) {
        mode = MODE_CLAIM;
    } else if (argc == 3 && strcmp(argv[1], "--send") == 0) {
        mode = MODE_SEND;
        path = argv[2];
    } else {
        usage(argv[0]);
        return 2;
    }

    libusb_context *context = NULL;
    int rc = libusb_init(&context);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "cannot initialize libusb: %s\n", libusb_error_name(rc));
        return 1;
    }

    libusb_device **devices = NULL;
    ssize_t device_count = libusb_get_device_list(context, &devices);
    if (device_count < 0) {
        fprintf(stderr, "cannot enumerate USB devices: %s\n",
                libusb_error_name((int)device_count));
        libusb_exit(context);
        return 1;
    }

    libusb_device *device = NULL;
    struct libusb_device_descriptor descriptor;
    for (ssize_t index = 0; index < device_count; ++index) {
        struct libusb_device_descriptor candidate;
        rc = libusb_get_device_descriptor(devices[index], &candidate);
        if (rc == LIBUSB_SUCCESS && candidate.idVendor == HP_VENDOR_ID &&
            candidate.idProduct == M1005_PRODUCT_ID) {
            device = libusb_ref_device(devices[index]);
            descriptor = candidate;
            break;
        }
    }
    libusb_free_device_list(devices, 1);

    if (device == NULL) {
        fprintf(stderr, "HP LaserJet M1005 (%04x:%04x) is not visible to libusb\n",
                HP_VENDOR_ID, M1005_PRODUCT_ID);
        libusb_exit(context);
        return 1;
    }
    print_device_layout(device, &descriptor);

    if (mode == MODE_PROBE) {
        libusb_unref_device(device);
        libusb_exit(context);
        return 0;
    }

    libusb_device_handle *handle = NULL;
    rc = libusb_open(device, &handle);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "device is visible but cannot be opened: %s (%d)\n",
                libusb_error_name(rc), rc);
        libusb_unref_device(device);
        libusb_exit(context);
        return 1;
    }

    int interface_number = -1;
    uint8_t bulk_out_endpoint = 0;
    rc = find_printer_interface(device, &interface_number, &bulk_out_endpoint);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "no bulk OUT endpoint found on a printer-class interface\n");
        libusb_close(handle);
        libusb_unref_device(device);
        libusb_exit(context);
        return 1;
    }

    int kernel_active = libusb_kernel_driver_active(handle, interface_number);
    if (kernel_active >= 0) {
        printf("kernel driver on interface %d: %s\n", interface_number,
               kernel_active ? "active" : "inactive");
    } else {
        printf("kernel driver state on interface %d: %s\n", interface_number,
               libusb_error_name(kernel_active));
    }

    rc = libusb_claim_interface(handle, interface_number);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "cannot claim printer interface %d: %s\n",
                interface_number, libusb_error_name(rc));
        libusb_close(handle);
        libusb_unref_device(device);
        libusb_exit(context);
        return 1;
    }
    printf("claimed printer interface %d; bulk OUT endpoint is 0x%02x\n",
           interface_number, bulk_out_endpoint);
    print_port_status(handle, interface_number);

    int result = 0;
    if (mode == MODE_SEND) {
        result = send_file(handle, bulk_out_endpoint, path);
        print_port_status(handle, interface_number);
    }

    rc = libusb_release_interface(handle, interface_number);
    if (rc != LIBUSB_SUCCESS) {
        fprintf(stderr, "warning: cannot release printer interface: %s\n",
                libusb_error_name(rc));
    }
    libusb_close(handle);
    libusb_unref_device(device);
    libusb_exit(context);
    return result;
}
