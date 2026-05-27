# cudaHostRegister() DEVDAX パッチガイド

NVIDIA ドライバ 580.126.09 + kernel 6.8.12 で DEVDAX (ZONE_DEVICE) の
不揮発性メモリを `cudaHostRegister()` するために必要なパッチ。

検証済み: 700 GiB の cudaHostRegister + DMA read/write 成功

---

## 1. 制限の全貌と必要なパッチ

```
cudaHostRegister(devdax_ptr, 700 GiB)

  [制限1] CUDA ランタイム (ユーザ空間)
  │  sysinfo().totalram (186 GiB) と比較 → 186 GiB 超で拒否
  │  → パッチ 1: LD_PRELOAD sysinfo フック
  │
  [制限2] nv-dma.c (カーネル glue)
  │  get_num_physpages() (186 GiB) と比較 → 190 GiB 超で拒否
  │  → パッチ 2: if(0) に置換
  │
  [制限3] os-mlock.c (カーネル glue)
  │  os_alloc_mem() で struct page* 配列を一括 vmalloc
  │  700 GiB → 1.4 GB 配列 → GFP_KERNEL で失敗
  │  → パッチ 3: __vmalloc + __GFP_RETRY_MAYFAIL
  │
  [制限4] nv.c (カーネル glue)
  │  nvos_create_alloc() で nvidia_pte_t 配列を kvzalloc
  │  700 GiB → 2.7 GB 配列 → GFP_KERNEL で失敗
  │  → パッチ 4: __vmalloc + __GFP_ZERO + __GFP_RETRY_MAYFAIL
  │
  ✓ 全パッチ適用で 700 GiB 成功
```

---

## 2. パッチ一覧

### パッチ 1: sysinfo LD_PRELOAD フック (ユーザ空間)

CUDA ランタイムが `sysinfo()` で `totalram` を取得し、登録サイズと比較する制限を回避。

ファイル: `sysinfo_hook.c` (新規作成)

```c
// gcc -shared -fPIC -o libsysinfo_hook.so sysinfo_hook.c -ldl
#define _GNU_SOURCE
#include <sys/sysinfo.h>
#include <dlfcn.h>

int sysinfo(struct sysinfo *info) {
    int (*real_sysinfo)(struct sysinfo *) = dlsym(RTLD_NEXT, "sysinfo");
    int ret = real_sysinfo(info);
    if (ret == 0) {
        info->totalram += (unsigned long)1024 * 1024 * 1024 * 1024 / info->mem_unit;
    }
    return ret;
}
```

**使い方**: `LD_PRELOAD=./libsysinfo_hook.so ./my_cuda_app`

### パッチ 2: nv-dma.c サニティチェック除去 (カーネル glue)

DMA マッピング作成時の `get_num_physpages()` 比較を無効化。

ファイル: `/usr/src/nvidia-srv-580.126.09/nvidia/nv-dma.c`
箇所: 3 箇所 (行 379, 460, 530)

```diff
-    if (page_count > get_num_physpages())
+    if (0 /* patched: allow DEVDAX beyond physpages */)
```

### パッチ 3: os-mlock.c vmalloc 緩和 (カーネル glue)

`os_lock_user_pages` 内の struct page* 配列確保を大規模対応。

ファイル: `/usr/src/nvidia-srv-580.126.09/nvidia/os-mlock.c`
箇所: `os_lock_user_pages` 内の `os_alloc_mem` 呼び出し (行 196 付近)

```diff
-    rmStatus = os_alloc_mem((void **)&user_pages,
-            (page_count * sizeof(*user_pages)));
-    if (rmStatus != NV_OK)
-    {
-        nv_printf(NV_DBG_ERRORS,
-                "NVRM: failed to allocate page table!\n");
-        return rmStatus;
-    }
+    {
+        NvU64 alloc_size = page_count * sizeof(*user_pages);
+        user_pages = (struct page **)__vmalloc(alloc_size,
+                GFP_KERNEL | __GFP_NOWARN | __GFP_RETRY_MAYFAIL);
+        if (user_pages == NULL) {
+            printk(KERN_ERR "NVRM: vmalloc %llu bytes FAILED\n",
+                   (unsigned long long)alloc_size);
+            return NV_ERR_NO_MEMORY;
+        }
+    }
```

同ファイル内の `os_free_mem(user_pages)` (2 箇所) も `vfree(user_pages)` に変更:

```diff
-        os_free_mem(user_pages);
+        vfree(user_pages);
```

同様に `os_lookup_user_io_memory` 内の `os_alloc_mem` / `os_free_mem` も同じパッチ。

### パッチ 4: nv.c nvidia_pte_t 配列の vmalloc 緩和 (カーネル glue)

`nvos_create_alloc` 内の nvidia_pte_t 配列 (16 バイト/ページ) 確保を大規模対応。

ファイル: `/usr/src/nvidia-srv-580.126.09/nvidia/nv.c`
箇所: `nvos_create_alloc` 内の `kvzalloc` (行 371 付近)

```diff
-    at->page_table = kvzalloc(pt_size, NV_GFP_KERNEL);
+    at->page_table = __vmalloc(pt_size,
+            GFP_KERNEL | __GFP_ZERO | __GFP_NOWARN | __GFP_RETRY_MAYFAIL);
```

---

## 3. 適用手順

```bash
# 1. sysinfo フックのビルド
gcc -shared -fPIC -o /usr/local/lib/libsysinfo_hook.so sysinfo_hook.c -ldl

# 2. NVIDIA ドライバソースにパッチ適用
cd /usr/src/nvidia-srv-580.126.09/nvidia

# パッチ 2: nv-dma.c
sed -i 's/if (page_count > get_num_physpages())/if (0)/' nv-dma.c

# パッチ 3: os-mlock.c (手動編集 — 上記 diff 参照)

# パッチ 4: nv.c
sed -i 's/kvzalloc(pt_size, NV_GFP_KERNEL)/__vmalloc(pt_size, GFP_KERNEL | __GFP_ZERO | __GFP_NOWARN | __GFP_RETRY_MAYFAIL)/' nv.c

# 3. DKMS リビルド
sudo dkms remove nvidia-srv/580.126.09 -k $(uname -r)
sudo dkms build nvidia-srv/580.126.09 -k $(uname -r)
sudo dkms install nvidia-srv/580.126.09 -k $(uname -r)

# 4. ドライバリロード
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia && sudo modprobe nvidia_uvm

# 5. 実行
LD_PRELOAD=/usr/local/lib/libsysinfo_hook.so ./my_cuda_app
```

---

## 4. 検証結果

研究室内クラスタノード｢nova02｣ (V100-PCIe-32GB, PMEM 744 GiB on DEVDAX, kernel 6.8.12(Canonicalがビルドしたものには不具合があるのでセルフビルドしたもの))

### サイズ別 cudaHostRegister 結果

| サイズ | パッチなし | 全パッチ |
|--------|-----------|----------|
| 185 GiB | SUCCESS | SUCCESS |
| 186 GiB | FAIL | **SUCCESS** |
| 190 GiB | FAIL | **SUCCESS** |
| 200 GiB | FAIL | **SUCCESS** |
| 300 GiB | FAIL | **SUCCESS** |
| 500 GiB | FAIL | **SUCCESS** |
| 700 GiB | FAIL | **SUCCESS** |



---

## 5. 関連ソースファイル

### NVIDIA ドライバ

| ファイル | パッチ | 内容 |
|----------|--------|------|
| `nvidia/os-mlock.c` | **パッチ 3** | `os_lock_user_pages`, `os_lookup_user_io_memory` |
| `nvidia/nv-dma.c` | **パッチ 2** | `get_num_physpages()` チェック (3 箇所) |
| `nvidia/nv.c` | **パッチ 4** | `nvos_create_alloc` の `kvzalloc` |

