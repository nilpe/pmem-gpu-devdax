#!/usr/bin/env bash
cd "$(dirname "$0")"; INST=737.25
bar(){ awk -v v="$1" -v t="$2" 'BEGIN{w=40;f=int(v*w/t+0.5);if(f>w)f=w;s="[";for(i=0;i<w;i++)s=s (i<f?"#":".");s=s"]";printf "%s %5.1f%%",s,v*100.0/t}'; }
printf '================================================================================\n'
printf ' GPU-usable PMem on /dev/dax0.1  (installed %.2f GiB)\n' "$INST"
printf ' nova01 / Tesla V100-PCIE-32GB / drv 580.159.03 / kernel 6.8.0-106-generic\n'
printf ' probe: cudaHostRegister bisection (stages0-4) ; DMA-verified split (stage5)\n'
printf '================================================================================\n'
row(){ printf ' %-37s %7.2f GiB %s\n' "$1" "$2" "$(bar "$2" "$INST")"; }
row "0  stock (no patch)"               203.47
row "1  +sysinfo hook (userspace)"      207.16
row "2  +nv-dma get_num_physpages"      512.00
row "3  +os-mlock page-array vmalloc"   512.00
row "4  +nv.c pte-array vmalloc (ALL)"  512.00
row "5  split: 2x<512G + ALL patches"   737.25
printf '================================================================================\n'
printf ' walls: [0] CUDA totalram 204G   [1] kernel get_num_physpages 207G\n'
printf '        [2-4] single nv.c page_table alloc = 2GiB(INT_MAX) -> 512G ceiling\n'
printf '        [5] split into <512G chunks of one mmap -> full device, DMA-verified\n'
printf '================================================================================\n'
