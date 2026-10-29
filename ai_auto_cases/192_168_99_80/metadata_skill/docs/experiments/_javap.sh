#!/bin/bash
ssh -n -o BatchMode=yes root@192.168.99.77 "javap -cp /data/iotdb/v20121rc5_1003_aaf460d/lib/timechodb-server-2.0.12.1.jar org.apache.tsfile.write.record.Tablet" 2>&1 | grep -E 'public' | head -30
