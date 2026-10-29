/*
 * 未排序 TsFile 生成器（CO-33 的构造器）
 *
 * 依据：IoTDB 官方集成测试 `IoTDBRepairDataIT.generateUnsortedFile()`（rc/2.0.12.1）
 *   —— 用底层 `TsFileIOWriter` 直接写 chunk，**按 2,3,5,4 的顺序**写时间点，
 *      文件内部的页内时间是乱序的（这正是"未排序 TsFile"的定义）。
 *   官方测试随后 `load` 该文件 → 断言 SELECT 结果不是升序 → `START REPAIR DATA`
 *   → 轮询直到 SELECT 恢复升序。
 *
 * 本生成器用「时间乱序 + 值与时间一一对应」的方式写点，便于用例同时校验
 * 「修复后顺序正确」**且**「(time,value) 配对没有被修复过程改错」
 * （官方测试所有点值都是 1，校验不出后者）。
 *
 * 编译/运行（在 99.80 / 目标 DataNode 上，用服务端自带 jar）：
 *   javac -cp <ver>/lib/timechodb-server-2.0.12.1.jar -d <outdir> UnsortedTsFileGen.java
 *   java  -cp <ver>/lib/timechodb-server-2.0.12.1.jar:<outdir> UnsortedTsFileGen <device> <outDir> <baseMs>
 *
 * 用法示例：
 *   java ... UnsortedTsFileGen root.c33.d1 /tmp/c33_stage $(date +%s%3N)
 */
import org.apache.tsfile.enums.TSDataType;
import org.apache.tsfile.file.metadata.IDeviceID;
import org.apache.tsfile.write.chunk.ChunkWriterImpl;
import org.apache.tsfile.write.schema.MeasurementSchema;
import org.apache.tsfile.write.writer.TsFileIOWriter;

import java.io.File;

public class UnsortedTsFileGen {

  public static void main(String[] args) throws Exception {
    if (args.length < 3) {
      System.err.println(
          "usage: UnsortedTsFileGen <devicePath> <outDir> <baseTimeMs> [offsetMs] [valueBase] [unsorted|dup|pages]");
      System.exit(2);
    }
    String device = args[0];
    File outDir = new File(args[1]);
    long base = Long.parseLong(args[2]);
    long offset = args.length > 3 ? Long.parseLong(args[3]) : 0L;
    int valueBase = args.length > 4 ? Integer.parseInt(args[4]) : 11;
    String mode = args.length > 5 ? args[5] : "unsorted";
    if (!outDir.exists() && !outDir.mkdirs()) {
      System.err.println("cannot create outDir: " + outDir);
      System.exit(3);
    }
    // 文件名必须符合 IoTDB 的 TsFile 命名：<epochMs>-<version>-<level>-0.tsfile
    // 同一目录里可能连续生成多个文件（CO-33 C 相造重叠文件），文件名 epoch 冲突就 +1ms
    long nameMs = System.currentTimeMillis();
    File tsfile = new File(outDir, nameMs + "-1-0-0.tsfile");
    while (tsfile.exists()) {
      nameMs++;
      tsfile = new File(outDir, nameMs + "-1-0-0.tsfile");
    }

    // 乱序写点：t=+2,+3,+5,+4（最后一个点在 5 之后），值 valueBase+0/1/2/3 与时间一一对应
    // mode=dup：t=+2,+3,+3,+5（**重复时间戳**）—— 对应《数据修复功能》设计文档里
    //          "单个 Page 内的点乱序**或重复**" 这一类错误；修复语义是"排序 + 去重"
    try (TsFileIOWriter writer = new TsFileIOWriter(tsfile)) {
      writer.startChunkGroup(IDeviceID.Factory.DEFAULT_FACTORY.create(device));
      ChunkWriterImpl chunkWriter =
          new ChunkWriterImpl(new MeasurementSchema("s1", TSDataType.INT32));
      if ("dup".equals(mode)) {
        chunkWriter.write(base + offset + 2, valueBase);
        chunkWriter.write(base + offset + 3, valueBase + 1);
        chunkWriter.write(base + offset + 3, valueBase + 2);
        chunkWriter.write(base + offset + 5, valueBase + 3);
      } else if ("pages".equals(mode)) {
        // 两个 Page：p1=[+2,+4]，p2=[+3,+5] ⇒ **Page 间重叠且乱序**
        // （p2 的起点 3 < p1 的终点 4）——对应《数据修复功能》错误类型②「Page 间乱序或重叠」
        chunkWriter.write(base + offset + 2, valueBase);
        chunkWriter.write(base + offset + 4, valueBase + 1);
        chunkWriter.sealCurrentPage();
        chunkWriter.write(base + offset + 3, valueBase + 2);
        chunkWriter.write(base + offset + 5, valueBase + 3);
      } else {
        chunkWriter.write(base + offset + 2, valueBase);
        chunkWriter.write(base + offset + 3, valueBase + 1);
        chunkWriter.write(base + offset + 5, valueBase + 2);
        chunkWriter.write(base + offset + 4, valueBase + 3);
      }
      chunkWriter.sealCurrentPage();
      chunkWriter.writeToFileWriter(writer);
      writer.endChunkGroup();
      writer.endFile();
    }
    System.out.println(tsfile.getAbsolutePath());
  }
}
