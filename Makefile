CC := clang
AR := ar
CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror
VENDOR := vendor/foo2xqx
BUILD := build
ARTIFACTS := artifacts

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS := $(shell pkg-config --libs libusb-1.0)
OPENSSL_CFLAGS := $(shell pkg-config --cflags openssl)
OPENSSL_LIBS := $(shell pkg-config --libs openssl)
CUPS_CFLAGS := $(shell cups-config --cflags)
CUPS_LIBS := $(shell cups-config --libs)
PAPPL_DIR := external/pappl
PAPPL_LIB := $(PAPPL_DIR)/pappl/libpappl.a
PAPPL_CONFIG := $(PAPPL_DIR)/config.status
PAPPL_CFLAGS := -I$(PAPPL_DIR) $(CUPS_CFLAGS) $(LIBUSB_CFLAGS) $(OPENSSL_CFLAGS)
PAPPL_LIBS := $(PAPPL_LIB) $(CUPS_LIBS) $(LIBUSB_LIBS) $(OPENSSL_LIBS) \
	-framework AppKit -framework CoreFoundation -framework SystemConfiguration \
	-framework IOKit -lpam -ldl -lpthread

.PHONY: all clean phase2 phase2-test phase3 phase3-test phase4 phase4-test \
	probe claim test validate

all: phase2 phase3 $(BUILD)/m1005-usb $(BUILD)/generate-test-pbm \
	$(BUILD)/generate-test-raster

phase2: $(BUILD)/m1005-xqx-encode $(BUILD)/m1005-xqx-decode

phase3: $(BUILD)/m1005-printer-app

phase4: phase3 $(BUILD)/test-m1005-usb-io

$(BUILD) $(ARTIFACTS):
	mkdir -p $@

$(BUILD)/jbig.o: $(VENDOR)/jbig.c $(VENDOR)/jbig.h $(VENDOR)/jbig_ar.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(VENDOR) -c $< -o $@

$(BUILD)/jbig_ar.o: $(VENDOR)/jbig_ar.c $(VENDOR)/jbig_ar.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(VENDOR) -c $< -o $@

$(BUILD)/libjbig-m1005.a: $(BUILD)/jbig.o $(BUILD)/jbig_ar.o
	$(AR) rcs $@ $^

$(BUILD)/m1005-xqx-encode.o: $(VENDOR)/foo2xqx.c $(VENDOR)/jbig.h $(VENDOR)/xqx.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(VENDOR) -c $< -o $@

$(BUILD)/m1005-xqx-encode: $(BUILD)/m1005-xqx-encode.o $(BUILD)/libjbig-m1005.a
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/m1005-xqx-decode.o: $(VENDOR)/xqxdecode.c $(VENDOR)/jbig.h $(VENDOR)/xqx.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(VENDOR) -c $< -o $@

$(BUILD)/m1005-xqx-decode: $(BUILD)/m1005-xqx-decode.o $(BUILD)/libjbig-m1005.a
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/generate-test-pbm: src/generate_test_pbm.c | $(BUILD)
	$(CC) $(CFLAGS) $< -o $@

$(BUILD)/generate-test-raster: src/generate_test_raster.c | $(BUILD)
	$(CC) $(CFLAGS) $(CUPS_CFLAGS) $< -o $@ $(CUPS_LIBS)

$(BUILD)/m1005-usb: src/m1005_usb.c | $(BUILD)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $< -o $@ $(LIBUSB_LIBS)

$(PAPPL_CONFIG):
	@test -x $(PAPPL_DIR)/configure || \
		(echo "Missing PAPPL source; see README.md Phase 3 bootstrap instructions." && false)
	cd $(PAPPL_DIR) && CFLAGS='-mmacosx-version-min=26.0 -arch arm64' \
		./configure --prefix=/private/tmp/m1005-pappl --enable-libusb \
		--disable-libjpeg --disable-libpng --enable-static --disable-shared \
		--with-tls=openssl

$(PAPPL_LIB): $(PAPPL_CONFIG)
	$(MAKE) -C $(PAPPL_DIR)/pappl libpappl.a

$(BUILD)/m1005-printer-app: src/m1005_printer_app.c src/m1005_pappl_usb.c \
		src/m1005_pappl_usb.h src/m1005_usb_io.c src/m1005_usb_io.h \
		$(PAPPL_LIB) $(BUILD)/m1005-xqx-encode | $(BUILD)
	$(CC) $(CFLAGS) $(PAPPL_CFLAGS) src/m1005_printer_app.c \
		src/m1005_pappl_usb.c src/m1005_usb_io.c -o $@ $(PAPPL_LIBS)

$(BUILD)/test-m1005-usb-io: tests/test_m1005_usb_io.c src/m1005_usb_io.c \
		src/m1005_usb_io.h | $(BUILD)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -Isrc tests/test_m1005_usb_io.c \
		src/m1005_usb_io.c -o $@ $(LIBUSB_LIBS)

$(ARTIFACTS)/m1005-a4-600.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@

$(ARTIFACTS)/m1005-a4-600.xqx: $(ARTIFACTS)/m1005-a4-600.pbm $(BUILD)/m1005-xqx-encode
	$(BUILD)/m1005-xqx-encode -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Phase 1" -U "Codex" \
		< $< > $@

$(ARTIFACTS)/m1005-a4-600.pwg: $(ARTIFACTS)/m1005-a4-600.pbm \
		$(BUILD)/generate-test-raster
	$(BUILD)/generate-test-raster pwg $< $@

$(ARTIFACTS)/m1005-a4-600.urf: $(ARTIFACTS)/m1005-a4-600.pbm \
		$(BUILD)/generate-test-raster
	$(BUILD)/generate-test-raster urf $< $@

$(ARTIFACTS)/m1005-a4-600.decode.txt: $(ARTIFACTS)/m1005-a4-600.xqx $(BUILD)/m1005-xqx-decode
	$(BUILD)/m1005-xqx-decode $< > $@

validate: $(ARTIFACTS)/m1005-a4-600.decode.txt
	grep -q 'XQX_MAGIC' $<
	grep -q 'XQXI_RESOLUTION_X, 600' $<
	grep -q 'XQXI_RESOLUTION_Y, 600' $<
	grep -q 'XQXI_DMPAPER, 9' $<
	grep -q 'XQX_END_DOC' $<
	shasum -a 256 $(ARTIFACTS)/m1005-a4-600.pbm $(ARTIFACTS)/m1005-a4-600.xqx

$(ARTIFACTS)/m1005-a4-600-2page.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@ 2

$(ARTIFACTS)/m1005-a4-600-2page.xqx: $(ARTIFACTS)/m1005-a4-600-2page.pbm $(BUILD)/m1005-xqx-encode
	$(BUILD)/m1005-xqx-encode -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Multi Page" -U "Codex" \
		< $< > $@

$(ARTIFACTS)/m1005-a4-600-2copies.xqx: $(ARTIFACTS)/m1005-a4-600.pbm $(BUILD)/m1005-xqx-encode
	$(BUILD)/m1005-xqx-encode -r600x600 -g4960x7016 -p9 -m1 -n2 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Two Copies" -U "Codex" \
		< $< > $@

.PHONY: validate-job-control
validate-job-control: $(ARTIFACTS)/m1005-a4-600-2page.xqx $(ARTIFACTS)/m1005-a4-600-2copies.xqx $(BUILD)/m1005-xqx-decode
	@test `$(BUILD)/m1005-xqx-decode $(ARTIFACTS)/m1005-a4-600-2page.xqx | grep -c 'XQX_START_PAGE'` -eq 2
	@$(BUILD)/m1005-xqx-decode $(ARTIFACTS)/m1005-a4-600-2copies.xqx | grep -q 'XQXI_COPIES, 2'
	shasum -a 256 $(ARTIFACTS)/m1005-a4-600-2page.xqx $(ARTIFACTS)/m1005-a4-600-2copies.xqx

$(ARTIFACTS)/m1005-cancel-stress.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@ 1 noise

$(ARTIFACTS)/m1005-cancel-stress.xqx: $(ARTIFACTS)/m1005-cancel-stress.pbm $(BUILD)/m1005-xqx-encode
	$(BUILD)/m1005-xqx-encode -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Cancel Test" -U "Codex" \
		< $< > $@

$(ARTIFACTS)/m1005-cancel-stress.pwg: $(ARTIFACTS)/m1005-cancel-stress.pbm \
		$(BUILD)/generate-test-raster
	$(BUILD)/generate-test-raster pwg $< $@ 8

probe: $(BUILD)/m1005-usb
	$< --probe

claim: $(BUILD)/m1005-usb
	$< --claim

phase2-test: all
	sh tests/test_phase2.sh

phase3-test: phase3 $(ARTIFACTS)/m1005-a4-600.pbm \
		$(ARTIFACTS)/m1005-a4-600.pwg $(ARTIFACTS)/m1005-a4-600.urf
	sh tests/test_phase3.sh

phase4-test: phase4
	$(BUILD)/test-m1005-usb-io

test: phase2-test phase3-test phase4-test validate-job-control

clean:
	rm -rf $(BUILD) $(ARTIFACTS)
