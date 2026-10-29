/*
 * 元数据 DDL skill 的测试用 Trigger：
 *   把 生命周期回调（onCreate / restore / onDrop）与 fire() 触发次数
 *   追加写到一个 marker 文件里 —— 用例通过 ssh 读该文件来判定
 *   "触发器元数据注册成功后是否真的被加载、被触发、重启后是否恢复"。
 *
 * 可用属性（CREATE TRIGGER … WITH (k=v)）：
 *   marker=<文件路径>   默认 /tmp/mdskill_trigger.log
 *   tag=<标签>          默认 default，用于区分多个触发器
 *   reject=true         让 validate() 抛异常（验证失败路径）
 */
package mdskill;

import org.apache.iotdb.trigger.api.Trigger;
import org.apache.iotdb.trigger.api.TriggerAttributes;

import org.apache.tsfile.write.record.Tablet;

import java.io.FileWriter;

public class MdTrigger implements Trigger {

  private String marker = "/tmp/mdskill_trigger.log";
  private String tag = "default";

  @Override
  public void validate(TriggerAttributes attributes) throws Exception {
    if ("true".equals(attributes.getString("reject"))) {
      throw new Exception("MDSKILL_TRIGGER_REJECT: validate() 按属性要求拒绝注册");
    }
  }

  @Override
  public void onCreate(TriggerAttributes attributes) throws Exception {
    if (attributes.hasAttribute("marker")) {
      marker = attributes.getString("marker");
    }
    if (attributes.hasAttribute("tag")) {
      tag = attributes.getString("tag");
    }
    append("onCreate");
  }

  @Override
  public void onDrop() throws Exception {
    append("onDrop");
  }

  @Override
  public void restore() throws Exception {
    append("restore");
  }

  @Override
  public boolean fire(Tablet tablet) throws Exception {
    append("fire");
    return true;
  }

  private void append(String event) {
    try (FileWriter writer = new FileWriter(marker, true)) {
      writer.write(System.currentTimeMillis() + " " + tag + " " + event + "\n");
    } catch (Exception ignored) {
      // 用例只看 marker 文件；写不进去不影响被测行为
    }
  }
}
