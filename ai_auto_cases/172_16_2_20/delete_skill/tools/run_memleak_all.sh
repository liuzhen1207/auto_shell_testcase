#!/bin/bash
BASE=/data2/iotdb/rc10_matrix
LOG=$BASE/logs/memleak-all.log
echo "===== MEMLEAK STUDY START $(date -Is) =====" >> $LOG
for c in DEL-MEMLEAK-TABLE-001 DEL-MEMLEAK-TABLE-002 DEL-MEMLEAK-TABLE-003 \
         DEL-MEMLEAK-TREE-001 DEL-MEMLEAK-TREE-002 DEL-MEMLEAK-TREE-003; do
  echo "[$(date +%H:%M:%S)] START $c" >> $LOG
  CYCLES=200 DEVICES=100 EVERY=20 bash $BASE/scripts/memleak_study.sh $c >> $LOG 2>&1
  echo "[$(date +%H:%M:%S)] END $c" >> $LOG
done
echo "===== MEMLEAK STUDY DONE $(date -Is) =====" >> $LOG
