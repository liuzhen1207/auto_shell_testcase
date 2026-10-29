/*
 * 元数据 DDL skill 的测试用 UDF（UDTF）：故意在 transform 里抛异常，
 * 用于验证"注册成功但执行失败"时错误能否如实上报（元数据已注册 ≠ 能用）。
 */
package mdskill;

import org.apache.iotdb.udf.api.UDTF;
import org.apache.iotdb.udf.api.access.Row;
import org.apache.iotdb.udf.api.collector.PointCollector;
import org.apache.iotdb.udf.api.customizer.config.UDTFConfigurations;
import org.apache.iotdb.udf.api.customizer.parameter.UDFParameters;
import org.apache.iotdb.udf.api.customizer.strategy.RowByRowAccessStrategy;
import org.apache.iotdb.udf.api.type.Type;

public class MdUdtfErr implements UDTF {

  @Override
  public void beforeStart(UDFParameters parameters, UDTFConfigurations configurations) {
    configurations.setOutputDataType(Type.DOUBLE).setAccessStrategy(new RowByRowAccessStrategy());
  }

  @Override
  public void transform(Row row, PointCollector collector) throws Exception {
    throw new RuntimeException("MDSKILL_UDF_BOOM: 这条异常是 mdskill 用例故意抛的");
  }
}
