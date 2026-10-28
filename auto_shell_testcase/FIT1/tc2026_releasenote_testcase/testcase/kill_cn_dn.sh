ssh iotdb@192.168.130.2 "sudo jps | grep -E 'DataNode|ConfigNode' | awk '{print \$1}' | xargs sudo kill -9"
ssh iotdb@192.168.130.3 "sudo jps | grep -E 'DataNode|ConfigNode' | awk '{print \$1}' | xargs sudo kill -9"
ssh iotdb@192.168.130.4 "sudo jps | grep -E 'DataNode|ConfigNode' | awk '{print \$1}' | xargs sudo kill -9"
ssh iotdb@192.168.130.5 "sudo jps | grep -E 'DataNode|ConfigNode' | awk '{print \$1}' | xargs sudo kill -9"
