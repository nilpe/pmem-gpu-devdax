// dax_pin_bisect.cu
// nvcc -O2 -std=c++17 -o dax_pin_bisect dax_pin_bisect.cu
//
// Usage:
//   ./dax_pin_bisect
//   ./dax_pin_bisect /dev/dax0.0
//   ./dax_pin_bisect /dev/dax0.0 400      # limit search to 400 GiB
//   ./dax_pin_bisect /dev/dax0.0 400 1024 # force device size=1024 GiB
//
// Notes:
//   - If stat().st_size == 0, tries:
//       /sys/class/dax/<name>/size
//       /sys/bus/dax/devices/<name>/size
//   - If still 0 and user_size_gib > 0, uses that.
//   - Uses 2 MiB aligned subrange for cudaHostRegister.

#include <cuda_runtime.h>

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void die(const char *msg) {
  std::fprintf(stderr, "FATAL: %s (errno=%d: %s)\n", msg, errno,
               std::strerror(errno));
  std::exit(EXIT_FAILURE);
}

static void die_cuda(const char *msg, cudaError_t err) {
  std::fprintf(stderr, "FATAL: %s: %s (%d)\n", msg, cudaGetErrorString(err),
               (int)err);
  std::exit(EXIT_FAILURE);
}

static size_t read_size_file(const std::string &path) {
  FILE *fp = std::fopen(path.c_str(), "r");
  if (!fp) {
    std::fprintf(stderr, "Info: could not open %s (errno=%d: %s)\n",
                 path.c_str(), errno, std::strerror(errno));
    return 0;
  }
  unsigned long long bytes = 0;
  if (std::fscanf(fp, "%llu", &bytes) != 1) {
    std::fprintf(stderr, "Info: could not parse %s\n", path.c_str());
    std::fclose(fp);
    return 0;
  }
  std::fclose(fp);
  return (size_t)bytes;
}

static size_t detect_dax_size(const char *dev_path,
                              unsigned long long user_size_gib) {
  const char *base = std::strrchr(dev_path, '/');
  const char *name = base ? (base + 1) : dev_path; // "dax0.0"

  // Try /sys/class/dax/<name>/size
  {
    std::string p = "/sys/class/dax/";
    p += name;
    p += "/size";
    size_t sz = read_size_file(p);
    if (sz > 0)
      return sz;
  }

  // Try /sys/bus/dax/devices/<name>/size
  {
    std::string p = "/sys/bus/dax/devices/";
    p += name;
    p += "/size";
    size_t sz = read_size_file(p);
    if (sz > 0)
      return sz;
  }

  if (user_size_gib > 0) {
    long double tmp = (long double)user_size_gib * 1024.0L * 1024.0L * 1024.0L;
    std::fprintf(stderr,
                 "Warning: sysfs size not found, falling back to user size: "
                 "%llu GiB\n",
                 user_size_gib);
    return (size_t)tmp;
  }

  return 0;
}

int main(int argc, char **argv) {
  const char *path = "/dev/dax0.0";
  if (argc >= 2) {
    path = argv[1];
  }

  // arg2: max search size in GiB (optional)
  unsigned long long max_gib_user = 0;
  if (argc >= 3) {
    max_gib_user = std::strtoull(argv[2], nullptr, 10);
  }

  // arg3: device size override in GiB (optional)
  unsigned long long dev_gib_override = 0;
  if (argc >= 4) {
    dev_gib_override = std::strtoull(argv[3], nullptr, 10);
  }

  // Re-enable THP for this process. The launching environment may inherit
  // PR_SET_THP_DISABLE (MMF_DISABLE_THP); without THP, faulting a devdax
  // mapping (2 MiB aligned, PMD-sized faults) cannot be satisfied and the
  // first access to the mmap'd region dies with SIGBUS. Clearing the flag
  // is unprivileged and only affects this process.
  if (prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0) != 0) {
    std::fprintf(stderr, "Warning: prctl(PR_SET_THP_DISABLE,0) failed "
                         "(errno=%d: %s); devdax access may SIGBUS\n",
                 errno, std::strerror(errno));
  }

  std::printf("DAX pinned memory bisection test\n");
  std::printf("Device path : %s\n", path);
  if (max_gib_user > 0) {
    std::printf("User max    : %llu GiB\n", max_gib_user);
  }
  if (dev_gib_override > 0) {
    std::printf("Dev size ov : %llu GiB\n", dev_gib_override);
  }

  // Initialize CUDA
  cudaError_t cerr = cudaSetDevice(0);
  if (cerr != cudaSuccess) {
    die_cuda("cudaSetDevice(0) failed", cerr);
  }
  cerr = cudaFree(0);
  if (cerr != cudaSuccess) {
    die_cuda("cudaFree(0) for context init failed", cerr);
  }

  int fd = ::open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    die("open() failed");
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    die("fstat() failed");
  }

  size_t dev_size = (size_t)st.st_size;

  if (dev_size == 0 || dev_gib_override > 0) {
    if (dev_size == 0) {
      std::fprintf(stderr,
                   "Info: stat().st_size == 0, trying sysfs / override\n");
    }
    if (dev_gib_override > 0) {
      dev_size = detect_dax_size(path, dev_gib_override);
    } else {
      dev_size = detect_dax_size(path, 0);
    }
  }

  if (dev_size == 0) {
    std::fprintf(stderr,
                 "FATAL: could not determine device size "
                 "(st_size=0 and sysfs size not found and no override)\n");
    ::close(fd);
    return EXIT_FAILURE;
  }

  double dev_gib = dev_size / (1024.0 * 1024.0 * 1024.0);
  std::printf("Device size : %zu bytes (%.2f GiB)\n", dev_size, dev_gib);

  // Map whole device
  void *raw =
      ::mmap(nullptr, dev_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (raw == MAP_FAILED) {
    die("mmap() failed");
  }
  std::printf("Mapped      : %p .. %p\n", raw,
              (void *)((char *)raw + dev_size));

  // 2 MiB aligned subrange
  const size_t ALIGN = 2ULL * 1024ULL * 1024ULL;
  uintptr_t raw_addr = (uintptr_t)raw;
  uintptr_t aligned_addr = (raw_addr + ALIGN - 1) & ~(uintptr_t)(ALIGN - 1);

  size_t delta = (size_t)(aligned_addr - raw_addr);
  if (delta >= dev_size) {
    std::fprintf(
        stderr,
        "FATAL: alignment shift >= dev_size (delta=%zu, dev_size=%zu)\n", delta,
        dev_size);
    munmap(raw, dev_size);
    close(fd);
    return EXIT_FAILURE;
  }

  size_t aligned_size = dev_size - delta;
  aligned_size = (aligned_size / ALIGN) * ALIGN;
  if (aligned_size == 0) {
    std::fprintf(stderr, "FATAL: aligned_size == 0 after 2MiB alignment\n");
    munmap(raw, dev_size);
    close(fd);
    return EXIT_FAILURE;
  }

  void *base = (void *)aligned_addr;
  std::printf("Aligned base: %p, usable size: %zu bytes (%.2f GiB)\n", base,
              aligned_size, aligned_size / (1024.0 * 1024.0 * 1024.0));

  // limit by user max if given
  size_t max_bytes = aligned_size;
  if (max_gib_user > 0) {
    long double tmp = (long double)max_gib_user * 1024.0L * 1024.0L * 1024.0L;
    if (tmp < (long double)max_bytes) {
      max_bytes = (size_t)tmp;
    }
  }

  max_bytes = (max_bytes / ALIGN) * ALIGN;
  if (max_bytes == 0) {
    std::fprintf(stderr,
                 "Nothing to test (max_bytes==0 after limit and align)\n");
    munmap(raw, dev_size);
    close(fd);
    return 0;
  }

  std::printf("Search range: [2MiB, %zu] bytes (%.2f GiB), step=%zu bytes\n",
              max_bytes, max_bytes / (1024.0 * 1024.0 * 1024.0), ALIGN);
  std::fflush(stdout);

  size_t low = ALIGN;
  size_t high = max_bytes;
  size_t best = 0;

  while (low <= high) {
    size_t mid = low + (high - low) / 2;
    mid = (mid / ALIGN) * ALIGN;
    if (mid < ALIGN)
      mid = ALIGN;

    double mid_gib = mid / (1024.0 * 1024.0 * 1024.0);
    std::printf("Try cudaHostRegister(%p, %zu bytes) [%.2f GiB]\n", base, mid,
                mid_gib);
    std::fflush(stdout);

    cerr = cudaHostRegister(base, mid, cudaHostRegisterPortable);
    if (cerr == cudaSuccess) {
      std::printf("  -> OK\n");
      best = mid;

      cudaError_t uerr = cudaHostUnregister(base);
      if (uerr != cudaSuccess) {
        die_cuda("cudaHostUnregister failed", uerr);
      }

      low = mid + ALIGN;
    } else {
      std::printf("  -> FAIL: %s (%d)\n", cudaGetErrorString(cerr), (int)cerr);
      if (mid <= ALIGN) {
        break;
      }
      high = mid - ALIGN;
    }

    if (high < low) {
      break;
    }
  }

  std::printf("\nRESULT:\n");
  if (best == 0) {
    std::printf("  No tested size succeeded.\n");
  } else {
    double best_gib = best / (1024.0 * 1024.0 * 1024.0);
    std::printf("  Best successful size: %zu bytes (%.2f GiB)\n", best,
                best_gib);
  }

  munmap(raw, dev_size);
  close(fd);

  return 0;
}
