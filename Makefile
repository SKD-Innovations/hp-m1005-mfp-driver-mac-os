CC := clang
AR := ar
CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror
VENDOR := vendor/foo2xqx
BUILD := build
ARTIFACTS := artifacts

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS := $(shell pkg-config --libs libusb-1.0)

.PHONY: all clean phase2 phase2-test probe claim test validate

all: phase2 $(BUILD)/m1005-usb $(BUILD)/generate-test-pbm

phase2: $(BUILD)/m1005-xqx-encode $(BUILD)/m1005-xqx-decode

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

$(BUILD)/m1005-usb: src/m1005_usb.c | $(BUILD)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $< -o $@ $(LIBUSB_LIBS)

$(ARTIFACTS)/m1005-a4-600.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@

$(ARTIFACTS)/m1005-a4-600.xqx: $(ARTIFACTS)/m1005-a4-600.pbm $(BUILD)/m1005-xqx-encode
	$(BUILD)/m1005-xqx-encode -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Phase 1" -U "Codex" \
		< $< > $@

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

probe: $(BUILD)/m1005-usb
	$< --probe

claim: $(BUILD)/m1005-usb
	$< --claim

phase2-test: all
	sh tests/test_phase2.sh

test: phase2-test validate-job-control

clean:
	rm -rf $(BUILD) $(ARTIFACTS)
