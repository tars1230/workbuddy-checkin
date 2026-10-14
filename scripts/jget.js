#!/usr/bin/env node
/**
 * jget.js — 极简 JSON 取值器（签到脚本内部使用）
 *
 * 用法：  echo '<json>' | node jget.js 'data.today_checked_in'
 * 输出：  取到的标量值（字符串/数字/布尔），对象与数组输出 JSON 文本，
 *         路径不存在或解析失败输出空字符串（退出码 0，便于 shell 判定）。
 *
 * 只做一件事：点号路径取值。不联网、不读写文件、不打印未知内容。
 */
'use strict';

const path = process.argv[2] || '';
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
  let out = '';
  try {
    let cur = JSON.parse(raw);
    if (path) {
      for (const key of path.split('.')) {
        if (cur === null || cur === undefined || typeof cur !== 'object') { cur = undefined; break; }
        cur = cur[key];
      }
    }
    if (cur === undefined || cur === null) out = '';
    else if (typeof cur === 'object') out = JSON.stringify(cur);
    else out = String(cur);
  } catch {
    // 3 = 输入不是合法 JSON（区别于"路径不存在"的空值），供调用方决定是否换兜底实现
    process.stdout.write('');
    process.exit(3);
  }
  process.stdout.write(out);
});
