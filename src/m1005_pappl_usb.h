#ifndef M1005_PAPPL_USB_H
#define M1005_PAPPL_USB_H

#include <pappl/pappl.h>

#define M1005_USB_SCHEME "m1005usb"
#define M1005_USB_URI "m1005usb://HP/LaserJet%20M1005%20MFP"
#define M1005_DEVICE_ID \
    "MFG:HP;MDL:LaserJet M1005 MFP;CMD:ACL;CLS:PRINTER;" \
    "DES:HP LaserJet M1005 MFP;"

void m1005PapplUSBRegister(void);
void m1005PapplUSBRequestReset(pappl_device_t *device);

#endif
