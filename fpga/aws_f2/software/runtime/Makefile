CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
LDLIBS ?= -lfpga_mgmt

all: vtpu_f2_smoke

vtpu_f2_smoke: vtpu_f2_smoke.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f vtpu_f2_smoke

.PHONY: all clean

