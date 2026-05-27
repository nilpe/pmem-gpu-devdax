#include <cuda_runtime.h>
#include <cstdio>
#include <cstdint>
#include <sys/prctl.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#define CK(c) do{cudaError_t e=(c);if(e!=cudaSuccess){printf("ERR %d %s\n",__LINE__,cudaGetErrorString(e));return 1;}}while(0)
int main(){
  prctl(PR_SET_THP_DISABLE,0,0,0,0);
  CK(cudaSetDevice(0)); CK(cudaFree(0));
  int fd=open("/dev/dax0.1",O_RDWR);
  size_t sz=2<<20; void*p=mmap(0,sz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
  CK(cudaHostRegister(p,sz,cudaHostRegisterPortable));
  volatile uint64_t* h=(volatile uint64_t*)p;
  uint64_t* d; CK(cudaMalloc(&d,8));
  // GPU-DMA write to PMem: put pattern in d, memcpy DtoH into PMem, CPU reads
  uint64_t pat=0xD1A0000000000007ull; CK(cudaMemcpy(d,&pat,8,cudaMemcpyHostToDevice));
  CK(cudaMemcpy((void*)h,d,8,cudaMemcpyDeviceToHost)); // device buffer -> PMem (DMA)
  printf("GPU-DMA write -> PMem: CPU reads 0x%016llx %s\n",(unsigned long long)h[0], h[0]==pat?"OK":"FAIL");
  // GPU-DMA read from PMem: CPU writes PMem, memcpy HtoD, copy back
  h[0]=0xD1A0000000000008ull; uint64_t back=0;
  CK(cudaMemcpy(d,(void*)h,8,cudaMemcpyHostToDevice)); // PMem -> device buffer (DMA)
  CK(cudaMemcpy(&back,d,8,cudaMemcpyDeviceToHost));
  printf("GPU-DMA read  <- PMem: GPU got 0x%016llx %s\n",(unsigned long long)back, back==0xD1A0000000000008ull?"OK":"FAIL");
  CK(cudaHostUnregister(p)); munmap(p,sz); close(fd); return 0;
}
