# Bound libvips memory footprint so ProcessImageJob doesn't accumulate
# native heap across jobs and OOM the Heroku Basic 512MB dyno.
#
# By default vips:
#  - keeps the last 100 operations + their pixel buffers in a cache
#    (we never benefit — every job processes a different blob)
#  - uses N threads where N = host cpu count, each with its own working
#    buffer (Heroku Basic reports 8 cores even though you get 1 vCPU)
#
# Together those add ~100MB of resident memory per processed image
# that glibc malloc never gives back to the OS, so after a handful of
# HEIC decodes the dyno is in swap and every subsequent vips call slows
# down ~10x. Disabling cache + capping threads keeps the steady-state
# RSS roughly flat.
require "vips"

Vips.cache_set_max(0)
Vips.cache_set_max_mem(0)
Vips.cache_set_max_files(0)
Vips.concurrency_set(1)
