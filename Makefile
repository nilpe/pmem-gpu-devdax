# Build the probes/tools. Requires nvcc (CUDA) and a C compiler.
# NOTE: CUDA 13 dropped Volta (sm_70); compute kernels won't run on a V100,
# but these tools only use cudaHostRegister + cudaMemcpy (DMA), which work.
NVCC ?= nvcc
CC   ?= cc
NVCCFLAGS ?= -O2 -std=c++17

all: dax_pin_bisect dax_pin_split pmem_register_slide stage_slide libsysinfo_hook.so

dax_pin_bisect: src/dax_pin_bisect.cu
	$(NVCC) $(NVCCFLAGS) -o $@ $<
dax_pin_split: src/dax_pin_split.cu
	$(NVCC) $(NVCCFLAGS) -o $@ $<
pmem_register_slide: src/pmem_register_slide.c
	$(CC) -O2 -o $@ $<
stage_slide: src/stage_slide.c
	$(CC) -O2 -o $@ $<
libsysinfo_hook.so: src/sysinfo_hook.c
	$(CC) -shared -fPIC -o $@ $< -ldl

clean:
	rm -f dax_pin_bisect dax_pin_split pmem_register_slide stage_slide libsysinfo_hook.so
.PHONY: all clean
