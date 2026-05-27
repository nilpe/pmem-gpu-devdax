#include <cuda_runtime.h>
#include <cstdio>
#include <sys/prctl.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#define LOG(...) do{fprintf(stderr,__VA_ARGS__);fflush(stderr);}while(0)
static const char* E(cudaError_t e){return cudaGetErrorString(e);}
int main(){
  int before = prctl(PR_GET_THP_DISABLE,0,0,0,0);
  int r = prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0);   // re-enable THP for this process
  int after = prctl(PR_GET_THP_DISABLE,0,0,0,0);
  LOG("THP_DISABLE before=%d set_ret=%d after=%d\n", before, r, after);
  cudaSetDevice(0); cudaFree(0);
  int fd=open("/dev/dax0.1",O_RDWR); LOG("open fd=%d\n",fd);
  size_t sz=2ull<<20;
  void* p=mmap(nullptr,sz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  LOG("mmap=%p\n",p);
  volatile unsigned char* b=(volatile unsigned char*)p;
  LOG("READ b[0]...\n"); unsigned char rd=b[0]; LOG("READ ok=0x%02x\n",rd);
  LOG("WRITE b[0]...\n"); b[0]=0x5a; LOG("WRITE ok readback=0x%02x\n",b[0]);
  cudaError_t e=cudaHostRegister(p,sz,cudaHostRegisterPortable);
  LOG("dax register 2MiB Portable -> %s\n", e==cudaSuccess?"OK":E(e));
  if(e==cudaSuccess) cudaHostUnregister(p);
  munmap(p,sz); close(fd); LOG("done\n");
  return 0;
}
