CC := clang
AR := ar
CFLAGS := -O2 -Wall -Wextra -Wpedantic
UPSTREAM := upstream/foo2zjs
BUILD := build
ARTIFACTS := artifacts

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS := $(shell pkg-config --libs libusb-1.0)

.PHONY: all clean probe claim validate

all: $(BUILD)/foo2xqx $(BUILD)/xqxdecode $(BUILD)/m1005-usb $(BUILD)/generate-test-pbm

$(BUILD) $(ARTIFACTS):
	mkdir -p $@

$(BUILD)/jbig.o: $(UPSTREAM)/jbig.c $(UPSTREAM)/jbig.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(UPSTREAM) -c $< -o $@

$(BUILD)/jbig_ar.o: $(UPSTREAM)/jbig_ar.c $(UPSTREAM)/jbig_ar.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(UPSTREAM) -c $< -o $@

$(BUILD)/libjbig-local.a: $(BUILD)/jbig.o $(BUILD)/jbig_ar.o
	$(AR) rcs $@ $^

$(BUILD)/foo2xqx.o: $(UPSTREAM)/foo2xqx.c $(UPSTREAM)/jbig.h $(UPSTREAM)/xqx.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(UPSTREAM) -c $< -o $@

$(BUILD)/foo2xqx: $(BUILD)/foo2xqx.o $(BUILD)/libjbig-local.a
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/xqxdecode.o: $(UPSTREAM)/xqxdecode.c $(UPSTREAM)/jbig.h $(UPSTREAM)/xqx.h | $(BUILD)
	$(CC) $(CFLAGS) -I$(UPSTREAM) -c $< -o $@

$(BUILD)/xqxdecode: $(BUILD)/xqxdecode.o $(BUILD)/libjbig-local.a
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/generate-test-pbm: src/generate_test_pbm.c | $(BUILD)
	$(CC) $(CFLAGS) $< -o $@

$(BUILD)/m1005-usb: src/m1005_usb.c | $(BUILD)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $< -o $@ $(LIBUSB_LIBS)

$(ARTIFACTS)/m1005-a4-600.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@

$(ARTIFACTS)/m1005-a4-600.xqx: $(ARTIFACTS)/m1005-a4-600.pbm $(BUILD)/foo2xqx
	$(BUILD)/foo2xqx -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Phase 1" -U "Codex" \
		< $< > $@

$(ARTIFACTS)/m1005-a4-600.decode.txt: $(ARTIFACTS)/m1005-a4-600.xqx $(BUILD)/xqxdecode
	$(BUILD)/xqxdecode $< > $@

validate: $(ARTIFACTS)/m1005-a4-600.decode.txt
	grep -q 'XQX_MAGIC' $<
	grep -q 'XQXI_RESOLUTION_X, 600' $<
	grep -q 'XQXI_RESOLUTION_Y, 600' $<
	grep -q 'XQXI_DMPAPER, 9' $<
	grep -q 'XQX_END_DOC' $<
	shasum -a 256 $(ARTIFACTS)/m1005-a4-600.pbm $(ARTIFACTS)/m1005-a4-600.xqx

$(ARTIFACTS)/m1005-a4-600-2page.pbm: $(BUILD)/generate-test-pbm | $(ARTIFACTS)
	$< $@ 2

$(ARTIFACTS)/m1005-a4-600-2page.xqx: $(ARTIFACTS)/m1005-a4-600-2page.pbm $(BUILD)/foo2xqx
	$(BUILD)/foo2xqx -r600x600 -g4960x7016 -p9 -m1 -n1 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Multi Page" -U "Codex" \
		< $< > $@

$(ARTIFACTS)/m1005-a4-600-2copies.xqx: $(ARTIFACTS)/m1005-a4-600.pbm $(BUILD)/foo2xqx
	$(BUILD)/foo2xqx -r600x600 -g4960x7016 -p9 -m1 -n2 -d1 -s7 \
		-u88x84 -l88x84 -L3 -T3 -J "M1005 Two Copies" -U "Codex" \
		< $< > $@

.PHONY: validate-job-control
validate-job-control: $(ARTIFACTS)/m1005-a4-600-2page.xqx $(ARTIFACTS)/m1005-a4-600-2copies.xqx
	@test `$(BUILD)/xqxdecode $(ARTIFACTS)/m1005-a4-600-2page.xqx | grep -c 'XQX_START_PAGE'` -eq 2
	@$(BUILD)/xqxdecode $(ARTIFACTS)/m1005-a4-600-2copies.xqx | grep -q 'XQXI_COPIES, 2'
	shasum -a 256 $(ARTIFACTS)/m1005-a4-600-2page.xqx $(ARTIFACTS)/m1005-a4-600-2copies.xqx

probe: $(BUILD)/m1005-usb
	$< --probe

claim: $(BUILD)/m1005-usb
	$< --claim

clean:
	rm -rf $(BUILD) $(ARTIFACTS)
