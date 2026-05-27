// dax_pin_split.cu
// nvcc -O2 -std=c++17 -o dax_pin_split dax_pin_split.cu
//
// Break the single-cudaHostRegister 512 GiB wall (nv.c page_table alloc hits
// 2 GiB = INT_MAX) by registering the device in several < 512 GiB chunks of ONE
// contiguous mmap. Under CUDA UVA each registered host range is device-addressable
// at the same VA, so adjacent chunks form one contiguous device-accessible region.
//
// Usage: ./dax_pin_split [/dev/dax0.1] [chunk_gib=384] [total_gib=all]

#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <unistd.h>

#define CK(call) do { cudaError_t e=(call); if(e!=cudaSuccess){ \
  std::fprintf(stderr,"FATAL %s:%d %s -> %s\n",__FILE__,__LINE__,#call,cudaGetErrorString(e)); \
  std::exit(1);} } while(0)

static const size_t GiB = 1ull<<30;
static const size_t ALIGN = 2ull<<20; // 2 MiB

// Note: GPU access is exercised via the DMA/copy engine (cudaMemcpy), not a
// compute kernel — the installed CUDA 13 toolkit dropped Volta (sm_70), so
// kernels won't run on this V100, but the DMA path (what PATCH.md relies on)
// works regardless of kernel arch.

int main(int argc, char **argv) {
  prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0); // devdax needs THP for 2 MiB faults

  const char *path = argc > 1 ? argv[1] : "/dev/dax0.1";
  double chunk_gib = argc > 2 ? atof(argv[2]) : 384.0; // must be < 512
  double total_gib = argc > 3 ? atof(argv[3]) : 0.0;

  CK(cudaSetDevice(0)); CK(cudaFree(0));

  int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0) { perror("open"); return 1; }

  size_t dev_size = 0;
  { char p[256]; const char *b=strrchr(path,'/'); const char*nm=b?b+1:path;
    snprintf(p,sizeof p,"/sys/bus/dax/devices/%s/size",nm);
    FILE*f=fopen(p,"r"); if(f){ unsigned long long s=0; if(fscanf(f,"%llu",&s)==1) dev_size=s; fclose(f);} }
  if (dev_size == 0) { fprintf(stderr,"could not read device size\n"); return 1; }

  void *raw = mmap(nullptr, dev_size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
  if (raw == MAP_FAILED) { perror("mmap"); return 1; }
  uintptr_t a = ((uintptr_t)raw + ALIGN-1) & ~(uintptr_t)(ALIGN-1);
  size_t usable = ((dev_size - (a-(uintptr_t)raw)) / ALIGN) * ALIGN;
  if (total_gib > 0) { size_t lim=(size_t)(total_gib*GiB)/ALIGN*ALIGN; if(lim<usable) usable=lim; }
  char *base = (char*)a;

  size_t chunk = (size_t)(chunk_gib*GiB)/ALIGN*ALIGN;
  if (chunk == 0 || chunk >= 512ull*GiB) { fprintf(stderr,"chunk must be in (0,512) GiB\n"); return 1; }

  printf("Device       : %s\n", path);
  printf("Usable span  : %.2f GiB (one contiguous mmap @ %p)\n", usable/(double)GiB, base);
  printf("Chunk size   : %.2f GiB  (page_table per chunk = %.3f GiB, must be < 2.0)\n",
         chunk/(double)GiB, (chunk/4096.0*16.0)/GiB);
  printf("--------------------------------------------------------------\n");

  // Register adjacent chunks covering the whole span.
  std::vector<std::pair<void*,size_t>> regs;
  size_t off = 0; int idx = 0;
  while (off < usable) {
    size_t sz = chunk; if (off + sz > usable) sz = usable - off;
    void *p = base + off;
    cudaError_t e = cudaHostRegister(p, sz, cudaHostRegisterPortable);
    printf("chunk %d: register [%.2f .. %.2f) GiB (%.2f GiB) -> %s\n",
           idx, off/(double)GiB, (off+sz)/(double)GiB, sz/(double)GiB,
           e==cudaSuccess?"OK":cudaGetErrorString(e));
    if (e != cudaSuccess) {
      fprintf(stderr,"  registration failed; unwinding\n");
      for (auto &r: regs) cudaHostUnregister(r.first);
      return 2;
    }
    regs.push_back({p,sz}); off += sz; idx++;
  }
  printf("--------------------------------------------------------------\n");
  printf("REGISTERED total: %.2f GiB across %zu chunks\n", off/(double)GiB, regs.size());

  // Whole span is one contiguous host VA (single mmap); prove every part is
  // GPU-DMA accessible by round-tripping 8 bytes through a device buffer at the
  // start, each chunk boundary, and the very end.
  std::vector<size_t> qidx;            // qword offsets into the span
  qidx.push_back(0);
  for (size_t i=1;i<regs.size();++i) qidx.push_back(((char*)regs[i].first-base)/8);
  qidx.push_back(usable/8 - 1);
  volatile uint64_t *hbase = (volatile uint64_t*)base;
  uint64_t *d_buf; CK(cudaMalloc(&d_buf, 8));
  int bad=0;
  for (size_t k=0;k<qidx.size();++k) {
    void *hp = (void*)&hbase[qidx[k]];
    double at = (qidx[k]*8)/(double)GiB;
    // GPU-DMA write: device buffer -> PMem, then CPU reads it back.
    uint64_t wpat = 0xD1A0DA7A00000000ull | (uint64_t)k;
    CK(cudaMemcpy(d_buf, &wpat, 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(hp, d_buf, 8, cudaMemcpyDeviceToHost));   // DMA -> PMem
    bool w_ok = (hbase[qidx[k]] == wpat);
    // GPU-DMA read: CPU writes PMem, GPU DMAs it out, copy back.
    uint64_t rpat = 0xC0FFEE0000000000ull | (uint64_t)k, got=0;
    hbase[qidx[k]] = rpat;
    CK(cudaMemcpy(d_buf, hp, 8, cudaMemcpyHostToDevice));   // DMA <- PMem
    CK(cudaMemcpy(&got, d_buf, 8, cudaMemcpyDeviceToHost));
    bool r_ok = (got == rpat);
    printf("  DMA @ %7.2f GiB : write %s, read %s\n", at,
           w_ok?"OK":"FAIL", r_ok?"OK":"FAIL");
    if(!w_ok||!r_ok) bad++;
  }
  printf("--------------------------------------------------------------\n");
  printf("RESULT: %.2f GiB contiguous & GPU-DMA accessible via %zu-way split: %s\n",
         off/(double)GiB, regs.size(), bad?"FAILED":"VERIFIED");

  cudaFree(d_buf);
  for (auto &r: regs) cudaHostUnregister(r.first);
  munmap(raw, dev_size); close(fd);
  return bad?3:0;
}
