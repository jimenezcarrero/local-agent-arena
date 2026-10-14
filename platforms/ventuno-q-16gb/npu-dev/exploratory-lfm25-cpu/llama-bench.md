| model                          |       size |     params | backend    | threads | cpu_mask   | cpu_strict |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | ------: | ---------- | ---------: | --------------: | -------------------: |
| lfm2moe 24B.A2B IQ3_XXS - 3.0625 bpw |  10.35 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |           pp512 |         15.81 ± 0.06 |
| lfm2moe 24B.A2B IQ3_XXS - 3.0625 bpw |  10.35 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |           tg128 |          9.13 ± 0.15 |
| lfm2moe 24B.A2B IQ3_XXS - 3.0625 bpw |  10.35 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   pp512 @ d8192 |         13.31 ± 0.01 |
| lfm2moe 24B.A2B IQ3_XXS - 3.0625 bpw |  10.35 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   tg128 @ d8192 |          5.90 ± 0.00 |

build: 836d57176 (11381)
