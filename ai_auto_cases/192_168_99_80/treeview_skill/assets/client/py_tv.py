#!/usr/bin/env python3
"""TV-CLI-PY：通过 apache-iotdb（Python Thrift 客户端）在树模型建序列并写入。

用法：python3 py_tv.py <host> <port> <user> <password> <device> <measurement> <intValue>
"""
import sys

from iotdb.Session import Session
from iotdb.utils.IoTDBConstants import TSDataType, TSEncoding, Compressor


def main():
    host, port, user, pw, device, measure, val = sys.argv[1:8]
    session = Session(host, port, user, pw)
    session.open(False)
    try:
        ts_path = device + "." + measure
        session.create_time_series(
            ts_path, TSDataType.INT64, TSEncoding.PLAIN, Compressor.SNAPPY
        )
        print("OK create timeseries:", ts_path)
        session.insert_record(device, 1000, [measure], [TSDataType.INT64], [int(val)])
        print("OK insert record:", device, measure, val)
    finally:
        session.close()


if __name__ == "__main__":
    main()
