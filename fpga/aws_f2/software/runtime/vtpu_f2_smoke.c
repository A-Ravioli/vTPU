#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <fpga_pci.h>

#ifndef FPGA_APP_PF
#define FPGA_APP_PF 0
#endif

#ifndef APP_PF_BAR0
#define APP_PF_BAR0 0
#endif

#define REG_CONTROL 0x00000000u
#define REG_STATUS 0x00000004u
#define REG_ERROR_CODE 0x00000008u
#define COUNTER_BASE 0x00000100u
#define INSTR_BASE 0x00001000u
#define HBM_BASE 0x00100000u

#define HBM_A 0x0000u
#define HBM_B 0x0100u
#define HBM_C 0x0200u
#define TILE_BYTES (16u * 16u)
#define RESULT_BYTES (16u * 16u * 4u)

typedef struct {
  int slot;
  const char *program_path;
  const char *a_path;
  const char *b_path;
  uint32_t timeout_ms;
} options_t;

static void usage(const char *argv0) {
  fprintf(stderr,
          "usage: %s --slot N --program program.hex --a a.bin --b b.bin [--timeout-ms N]\n",
          argv0);
}

static bool parse_u32(const char *text, uint32_t *out) {
  char *end = NULL;
  errno = 0;
  unsigned long value = strtoul(text, &end, 0);
  if (errno || end == text || *end != '\0' || value > UINT32_MAX) return false;
  *out = (uint32_t)value;
  return true;
}

static bool parse_hex_u32(const char *text, uint32_t *out) {
  char *end = NULL;
  errno = 0;
  unsigned long value = strtoul(text, &end, 16);
  if (errno || end == text || *end != '\0' || value > UINT32_MAX) return false;
  *out = (uint32_t)value;
  return true;
}

static int parse_args(int argc, char **argv, options_t *opts) {
  opts->slot = 0;
  opts->timeout_ms = 5000;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--slot") && i + 1 < argc) {
      opts->slot = atoi(argv[++i]);
    } else if (!strcmp(argv[i], "--program") && i + 1 < argc) {
      opts->program_path = argv[++i];
    } else if (!strcmp(argv[i], "--a") && i + 1 < argc) {
      opts->a_path = argv[++i];
    } else if (!strcmp(argv[i], "--b") && i + 1 < argc) {
      opts->b_path = argv[++i];
    } else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opts->timeout_ms)) return -1;
    } else {
      return -1;
    }
  }
  return (opts->program_path && opts->a_path && opts->b_path) ? 0 : -1;
}

static uint8_t *read_file_exact(const char *path, size_t expected) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    return NULL;
  }
  uint8_t *buf = calloc(expected, 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  size_t got = fread(buf, 1, expected, f);
  int extra = fgetc(f);
  fclose(f);
  if (got != expected || extra != EOF) {
    fprintf(stderr, "%s: expected %zu bytes, got %zu%s\n", path, expected, got, extra == EOF ? "" : "+");
    free(buf);
    return NULL;
  }
  return buf;
}

static int poke_checked(pci_bar_handle_t handle, uint32_t addr, uint32_t value) {
  int rc = fpga_pci_poke(handle, addr, value);
  if (rc) fprintf(stderr, "poke failed addr=0x%08" PRIx32 " rc=%d\n", addr, rc);
  return rc;
}

static int peek_checked(pci_bar_handle_t handle, uint32_t addr, uint32_t *value) {
  int rc = fpga_pci_peek(handle, addr, value);
  if (rc) fprintf(stderr, "peek failed addr=0x%08" PRIx32 " rc=%d\n", addr, rc);
  return rc;
}

static int write_hbm(pci_bar_handle_t handle, uint32_t offset, const uint8_t *data, size_t len) {
  for (size_t i = 0; i < len; i += 4) {
    uint32_t word = 0;
    size_t remain = len - i;
    size_t chunk = remain < 4 ? remain : 4;
    memcpy(&word, data + i, chunk);
    if (poke_checked(handle, HBM_BASE + offset + (uint32_t)i, word)) return -1;
  }
  return 0;
}

static int read_hbm(pci_bar_handle_t handle, uint32_t offset, uint8_t *data, size_t len) {
  for (size_t i = 0; i < len; i += 4) {
    uint32_t word = 0;
    if (peek_checked(handle, HBM_BASE + offset + (uint32_t)i, &word)) return -1;
    size_t remain = len - i;
    size_t chunk = remain < 4 ? remain : 4;
    memcpy(data + i, &word, chunk);
  }
  return 0;
}

static int load_program_hex(pci_bar_handle_t handle, const char *path, size_t *num_instr) {
  FILE *f = fopen(path, "r");
  if (!f) {
    perror(path);
    return -1;
  }
  char line[128];
  size_t pc = 0;
  while (fgets(line, sizeof(line), f)) {
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '\0' || *p == '\n' || *p == '#') continue;
    size_t n = strcspn(p, "\r\n");
    p[n] = '\0';
    if (n != 32) {
      fprintf(stderr, "%s: instruction line must be 32 hex chars, got %zu\n", path, n);
      fclose(f);
      return -1;
    }
    for (int lane = 0; lane < 4; lane++) {
      char chunk[9] = {0};
      memcpy(chunk, p + (3 - lane) * 8, 8);
      uint32_t word = 0;
      if (!parse_hex_u32(chunk, &word)) {
        fprintf(stderr, "%s: bad hex word '%s'\n", path, chunk);
        fclose(f);
        return -1;
      }
      if (poke_checked(handle, INSTR_BASE + (uint32_t)(pc * 16 + lane * 4), word)) {
        fclose(f);
        return -1;
      }
    }
    pc++;
  }
  fclose(f);
  *num_instr = pc;
  return 0;
}

static void compute_expected(const int8_t *a, const int8_t *b, int32_t *c) {
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      int32_t acc = 0;
      for (int k = 0; k < 16; k++) {
        acc += (int32_t)a[i * 16 + k] * (int32_t)b[k * 16 + j];
      }
      c[i * 16 + j] = acc;
    }
  }
}

static int poll_done(pci_bar_handle_t handle, uint32_t timeout_ms) {
  const uint64_t timeout_ns = (uint64_t)timeout_ms * 1000000ull;
  struct timespec start;
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (true) {
    uint32_t status = 0;
    if (peek_checked(handle, REG_STATUS, &status)) return -1;
    if (status & 0x4u) {
      uint32_t code = 0;
      (void)peek_checked(handle, REG_ERROR_CODE, &code);
      fprintf(stderr, "vTPU error status=0x%08" PRIx32 " code=0x%08" PRIx32 "\n", status, code);
      return -1;
    }
    if ((status & 0x1u) && !(status & 0x2u)) return 0;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t elapsed_ns = (uint64_t)(now.tv_sec - start.tv_sec) * 1000000000ull +
                          (uint64_t)(now.tv_nsec - start.tv_nsec);
    if (elapsed_ns > timeout_ns) {
      fprintf(stderr, "timed out waiting for vTPU completion\n");
      return -1;
    }
  }
}

static uint64_t read_counter(pci_bar_handle_t handle, uint32_t index) {
  uint32_t lo = 0, hi = 0;
  (void)peek_checked(handle, COUNTER_BASE + index * 8, &lo);
  (void)peek_checked(handle, COUNTER_BASE + index * 8 + 4, &hi);
  return ((uint64_t)hi << 32) | lo;
}

int main(int argc, char **argv) {
  options_t opts = {0};
  if (parse_args(argc, argv, &opts)) {
    usage(argv[0]);
    return 2;
  }

  uint8_t *a = read_file_exact(opts.a_path, TILE_BYTES);
  uint8_t *b = read_file_exact(opts.b_path, TILE_BYTES);
  if (!a || !b) return 1;

  int32_t expected[16 * 16];
  compute_expected((const int8_t *)a, (const int8_t *)b, expected);

  pci_bar_handle_t handle = PCI_BAR_HANDLE_INIT;
  int rc = fpga_pci_attach(opts.slot, FPGA_APP_PF, APP_PF_BAR0, 0, &handle);
  if (rc) {
    fprintf(stderr, "fpga_pci_attach failed slot=%d rc=%d\n", opts.slot, rc);
    return 1;
  }

  size_t program_instructions = 0;
  int status = 1;
  if (poke_checked(handle, REG_CONTROL, 2)) goto out;
  if (load_program_hex(handle, opts.program_path, &program_instructions)) goto out;
  if (write_hbm(handle, HBM_A, a, TILE_BYTES)) goto out;
  if (write_hbm(handle, HBM_B, b, TILE_BYTES)) goto out;
  if (poke_checked(handle, REG_CONTROL, 1)) goto out;
  if (poll_done(handle, opts.timeout_ms)) goto out;

  uint8_t raw_result[RESULT_BYTES];
  if (read_hbm(handle, HBM_C, raw_result, RESULT_BYTES)) goto out;
  if (memcmp(raw_result, expected, RESULT_BYTES) != 0) {
    fprintf(stderr, "result mismatch\n");
    for (int i = 0; i < 16 * 16; i++) {
      int32_t got = 0;
      memcpy(&got, raw_result + i * 4, 4);
      if (got != expected[i]) {
        fprintf(stderr, "  idx=%d got=%" PRId32 " expected=%" PRId32 "\n", i, got, expected[i]);
        break;
      }
    }
    goto out;
  }

  printf("vTPU F2 smoke PASS (%zu instructions)\n", program_instructions);
  printf("  cycles      : %" PRIu64 "\n", read_counter(handle, 0));
  printf("  instructions: %" PRIu64 "\n", read_counter(handle, 1));
  printf("  dma_bytes   : %" PRIu64 "\n", read_counter(handle, 2));
  printf("  hbm_stall   : %" PRIu64 "\n", read_counter(handle, 4));
  status = 0;

out:
  fpga_pci_detach(handle);
  free(a);
  free(b);
  return status;
}
