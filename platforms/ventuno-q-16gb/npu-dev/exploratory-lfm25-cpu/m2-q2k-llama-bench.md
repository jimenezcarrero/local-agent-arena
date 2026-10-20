| model                          |       size |     params | backend    | threads | cpu_mask   | cpu_strict |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | ------: | ---------- | ---------: | --: | --------------: | -------------------: |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |           pp512 |         13.42 ± 0.00 |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |           tg128 |         10.00 ± 0.22 |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |   pp512 @ d8192 |         11.68 ± 0.01 |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |   tg128 @ d8192 |          6.16 ± 0.01 |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |  pp512 @ d16384 |         10.22 ± 0.01 |
| lfm2moe 24B.A2B Q2_K - Medium  |   8.20 GiB |    23.97 B | CPU        |       4 | 0xF        |          1 |   1 |  tg128 @ d16384 |          4.50 ± 0.01 |

build: 836d57176 (11381)
