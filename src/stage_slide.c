// cc -O2 -o stage_slide stage_slide.c
// stage_slide <stage_label> <installed_gib> <usable_gib> <device> <note>
#include <stdio.h>
#include <stdlib.h>
#define BAR_WIDTH 44
static void print_bar(double v, double total) {
  int fill = total > 0 ? (int)(v * BAR_WIDTH / total + 0.5) : 0;
  if (fill < 0) fill = 0; if (fill > BAR_WIDTH) fill = BAR_WIDTH;
  putchar('[');
  for (int i = 0; i < BAR_WIDTH; i++) putchar(i < fill ? '#' : '.');
  putchar(']');
}
int main(int argc, char **argv) {
  const char *label = argc > 1 ? argv[1] : "stage";
  double installed  = argc > 2 ? atof(argv[2]) : 737.25;
  double usable     = argc > 3 ? atof(argv[3]) : 0.0;
  const char *dev   = argc > 4 ? argv[4] : "/dev/dax0.1";
  const char *note  = argc > 5 ? argv[5] : "";
  if (installed <= 0) installed = 1;
  if (usable < 0) usable = 0; if (usable > installed) usable = installed;
  printf("==========================================================\n");
  printf(" gpu-pmem-capacity   [%s]\n", label);
  printf("==========================================================\n");
  printf(" PMem device     : %s (devdax)\n", dev);
  printf(" Installed PMem  : %.2f GiB\n", installed);
  printf(" Probe method    : cudaHostRegister() bisection (2 MiB step)\n");
  if (note[0]) printf(" Limiting factor : %s\n", note);
  printf("\n");
  printf(" GPU-usable PMem : %7.2f / %7.2f GiB  ", usable, installed);
  print_bar(usable, installed);
  printf("  %5.1f%%\n", usable * 100.0 / installed);
  printf("==========================================================\n");
  return 0;
}
