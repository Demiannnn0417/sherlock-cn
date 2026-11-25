#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在单一输出流里运行 Sherlock。

为什么需要这层壳：
  Windows PowerShell 5.1 会把子进程的 stderr 包装成 ErrorRecord 再展示/落盘，
  日志里就会出现 "python.exe : ..." 加一串 "所在位置 行:..." 的定位噪声；
  把 stderr 直接并到 stdout 后，控制台、日志、重定向三处都干净，
  也不会出现 stderr 管道写满导致子进程卡死。

用法（参数原样透传给 Sherlock）：
  python lib/run_sherlock.py test --site GitLab --print-all
"""

from __future__ import annotations

import sys


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    # 关键一步：stderr 并到 stdout
    sys.stderr = sys.stdout

    # 让 argparse 的帮助里显示 "sherlock" 而不是 "run_sherlock.py"
    sys.argv[0] = "sherlock"

    try:
        from sherlock_project import sherlock

        sherlock.main()
    except SystemExit as exc:  # sherlock 内部大量使用 sys.exit
        code = exc.code
        if code is None:
            return 0
        if isinstance(code, int):
            return code
        print(code)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
