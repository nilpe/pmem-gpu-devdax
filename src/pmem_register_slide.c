// cc -O2 -o pmem_register_slide pmem_register_slide.c
// ./pmem_register_slide [installed_gib] [gpu_usable_gib]

#include <stdio.h>
#include <stdlib.h>

#define BAR_WIDTH 40

static void print_bar(double value, double total) {
  int fill = (int)(value * BAR_WIDTH / total + 0.5);

  if (fill < 0)
    fill = 0;
  if (fill > BAR_WIDTH)
    fill = BAR_WIDTH;

  putchar('[');
  for (int i = 0; i < BAR_WIDTH; i++)
    putchar(i < fill ? '=' : '-');
  putchar(']');
}

int main(int argc, char **argv) {
  double installed_gib = argc > 1 ? atof(argv[1]) : 700.0;
  double gpu_usable_gib = argc > 2 ? atof(argv[2]) : 186.0;

  if (installed_gib <= 0.0)
    installed_gib = 1.0;
  if (gpu_usable_gib < 0.0)
    gpu_usable_gib = 0.0;
  if (gpu_usable_gib > installed_gib)
    gpu_usable_gib = installed_gib;

  puts("gpu-pmem-capacity");
  puts("-----------------");
  puts("PMem device       : /dev/dax0.0");
  printf("Estimated PMem    : %.0f GiB\n", installed_gib);
  puts("Probe method      : cudaHostRegister bisection");
  puts("");

  printf("GPU-usable PMem   : %.0f GiB / %.0f GiB  ",
         gpu_usable_gib, installed_gib);
  print_bar(gpu_usable_gib, installed_gib);
  printf("  %.1f%%\n", gpu_usable_gib * 100.0 / installed_gib);

  return 0;
}
