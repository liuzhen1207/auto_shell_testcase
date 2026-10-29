# 客户端机（172.20.70.122）操作清单

- [ ] 解包到 `/data1/iotdb/5c20dtest/testcase/`：`tar xzf iotdb-proactive-5c20d.tar.gz -C /data1/iotdb/5c20dtest/testcase/`
- [ ] `python3 -V`（需 ≥ 3.8）
- [ ] SSH 密码连通：`sshpass -p 'Iotdb@2026' ssh root@172.20.70.100 'hostname'`（或已配免密）
- [ ] 端口连通：100-119 的 6667(CN)/10710(CN 内部)/10720(DN 内部)/10730(DN 数据)
- [ ] `/data/iotdb` 存在且非满盘：`df -h /data`
- [ ] JDK/jcmd：`jcmd -l` 能看到 IoTDB 进程；`jstack` 可用
- [ ] 并发采样上限：默认 ≤ 8 节点并发（`LEAK_SAMPLE_PARALLEL`），20 DN 全采会瞬时压满客户端机
- [ ] 首次运行：`selftest` → `doctor` → `run --case MULTI-01 --case MULTI-02`
