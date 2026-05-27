#include <cuda_runtime.h>
#include <cstdio>
#include <cstdint>
#define CK(c) do{cudaError_t e=(c);if(e!=cudaSuccess){printf("ERR %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));return 1;}}while(0)
__global__ void setk(uint64_t*o){*o=0x1234567800000009ull;}
int main(){
  CK(cudaSetDevice(0)); CK(cudaFree(0));
  uint64_t *d; CK(cudaMalloc(&d,8)); uint64_t h=0;
  CK(cudaMemset(d,0,8));
  setk<<<1,1>>>(d);
  cudaError_t le=cudaGetLastError(); printf("launch: %s\n",cudaGetErrorString(le));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(&h,d,8,cudaMemcpyDeviceToHost));
  printf("kernel wrote -> 0x%016llx %s\n",(unsigned long long)h, h==0x1234567800000009ull?"OK (kernels execute)":"FAIL (kernel exec broken)");
  // also test pure memcpy roundtrip
  uint64_t src=0xAABBCCDD11223344ull, dst=0; CK(cudaMemcpy(d,&src,8,cudaMemcpyHostToDevice)); CK(cudaMemcpy(&dst,d,8,cudaMemcpyDeviceToHost));
  printf("memcpy roundtrip -> 0x%016llx %s\n",(unsigned long long)dst, dst==src?"OK":"FAIL");
  return 0;
}
