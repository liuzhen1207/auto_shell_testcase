/*
 * 元数据 DDL skill 的测试用 UDF（UDTF）：
 *   把输入值乘 2 输出 —— 结果可预期，便于断言"注册的 UDF 真的被执行了"。
 * 编译依赖：<安装目录>/lib/timechodb-server-2.0.12.1.jar（内含 udf-api）
 */
package mdskill;

import org.apache.iotdb.udf.api.UDTF;
import org.apache.iotdb.udf.api.access.Row;
import org.apache.iotdb.udf.api.collector.PointCollector;
import org.apache.iotdb.udf.api.customizer.config.UDTFConfigurations;
import org.apache.iotdb.udf.api.customizer.parameter.UDFParameters;
import org.apache.iotdb.udf.api.customizer.strategy.RowByRowAccessStrategy;
import org.apache.iotdb.udf.api.type.Type;

public class MdUdtf implements UDTF {

  private double factor = 2.0;

  @Override
  public void beforeStart(UDFParameters parameters, UDTFConfigurations configurations) {
    // 支持通过属性调倍数：SELECT md_double(s1, 'factor'='3') …
    if (parameters.hasAttribute("factor")) {
      factor = Double.parseDouble(parameters.getAttributes().get("factor"));
    }
    configurations.setOutputDataType(Type.DOUBLE).setAccessStrategy(new RowByRowAccessStrategy());
  }

  @Override
  public void transform(Row row, PointCollector collector) throws Exception {
    collector.putDouble(row.getTime(), row.getDouble(0) * factor);
  }
}
