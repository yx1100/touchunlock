#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 v4（固件 1.3.0）基础上生成 v5 补丁镜像（固件 1.4.0）。

目的：键入密码时每个字符之间加一段延时，模拟真人逐键敲击的节奏。设备原本把整串
密码瞬间全发（逐字符无间隔），普通输入框能跟上，但 macOS 的系统授权弹窗
（SecurityAgent、通行密钥要电脑账户密码）跟不上这种突发、整串都丢，表现为放指纹后
一个字符都进不去。放慢到逐字符带间隔后，像真蓝牙键盘一样被接收。

实现：键入循环 FUN_ram_420092d0 里，每个字符的「按下」报文由 0x4200936e
`jal 0x42009100` 发出，参数 a0=s1(HID键盘) a1=sp(报文) a2=s2。把这一条 jal 改成跳到
一小段 type_delay：先 delay_ms(40)，再用保留在 s 寄存器里的值重建 a0/a1/a2，尾调用原
发送函数 0x42009100 返回。只拦「按下」这一次调用，「抬起」(0x42009388)不动，所以延时
落在字符之间，不改变每个键的按下时长。delay_ms 保留 s 寄存器与 sp，键入已在同一任务里
调用过它（回车前 300ms），从这里调用安全。

两处改动（notify_match 之后的死代码区，改动区外逐字节不动）：
  1. 0x4200936e: jal 0x42009100 -> jal 0x42005186(type_delay)
  2. 0x42005186: type_delay 18 字节：
        addi a0,zero,40 ; jal delay_ms ; mv a0,s1 ; mv a1,sp ; mv a2,s2 ; j 0x42009100
  另外把 DROM 版本字符串 1.3.0 -> 1.4.0。

镜像末尾 1 字节异或校验（种子 0xEF）+ 32 字节 SHA-256 已重算。
"""
import hashlib
import struct
import sys

IN_PATH = "firmware/TouchUnlock-1.3.0.bin"
OUT_PATH = "firmware/TouchUnlock-1.4.0.bin"
IMG_SIZE = 975472

VERSION_OFFSET = 0x178C
OLD_VERSION = b"1.3.0"
NEW_VERSION = b"1.4.0"

CALLSITE = 0x4200936E          # jal 0x42009100（逐字符按下报文）
TRAMP = 0x42005186             # type_delay 落点（死代码区）
DELAY_MS_FN = 0x4201553E       # delay_ms(a0=毫秒)
SEND_FN = 0x42009100           # 发送一条 HID 报文
DELAY_MS = 40                  # 每字符间隔；若授权弹窗仍收不到可调大

CALLSITE_OLD = "eff03fd9"      # jal 0x42009100
TRAMP_OLD = "4800efd0cfff"     # 死字节（仅自检）


def v2f(vaddr):
    return vaddr - 0x41FB0000


def enc_jal(rd, pc, target):
    off = target - pc
    assert off % 2 == 0 and -(1 << 20) <= off < (1 << 20), f"jal out of range: {off:#x}"
    imm = off & 0x1FFFFF
    word = (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21
            | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xFF) << 12
            | (rd & 0x1F) << 7 | 0x6F)
    return struct.pack("<I", word)


def type_delay():
    code = b""
    code += struct.pack("<I", 0x00000513 | (DELAY_MS << 20))  # addi a0,zero,DELAY_MS
    code += enc_jal(1, TRAMP + len(code), DELAY_MS_FN)         # jal delay_ms
    code += struct.pack("<H", 0x8526)                          # c.mv a0,s1
    code += struct.pack("<H", 0x858A)                          # c.mv a1,sp
    code += struct.pack("<H", 0x864A)                          # c.mv a2,s2
    code += enc_jal(0, TRAMP + len(code), SEND_FN)             # j 0x42009100
    assert len(code) == 18, len(code)
    return code


def segments(img):
    n = img[1]; off = 24; out = []
    for _ in range(n):
        addr, ln = struct.unpack_from("<II", img, off); off += 8
        out.append((addr, off, ln)); off += ln
    return out


def checksum(img):
    ck = 0xEF
    for _a, o, l in segments(img):
        for b in img[o:o + l]:
            ck ^= b
    return ck


def main():
    img = bytearray(open(IN_PATH, "rb").read())
    if len(img) != IMG_SIZE:
        sys.exit(f"镜像大小异常: {len(img)}")
    for va, exp in ((CALLSITE, CALLSITE_OLD), (TRAMP, TRAMP_OLD)):
        got = bytes(img[v2f(va):v2f(va) + len(exp) // 2]).hex()
        if got != exp:
            sys.exit(f"0x{va:08x} 原字节不符: 期望 {exp} 实际 {got}")
    if img[VERSION_OFFSET:VERSION_OFFSET + 6] != OLD_VERSION + b"\x00":
        sys.exit("版本字符串不是 1.3.0，中止")

    changes = [
        (CALLSITE, enc_jal(1, CALLSITE, TRAMP), "逐字符按下 jal 改指向 type_delay"),
        (TRAMP, type_delay(), f"type_delay: delay_ms({DELAY_MS}) 后尾调用 0x42009100"),
    ]
    print("=== 补丁写入 ===")
    for va, blob, desc in changes:
        off = v2f(va)
        print(f"[{desc}]\n  vaddr 0x{va:08x} file 0x{off:06x} {len(blob)}B")
        print(f"  旧 {bytes(img[off:off+len(blob)]).hex()}  新 {blob.hex()}")
        img[off:off + len(blob)] = blob

    img[VERSION_OFFSET:VERSION_OFFSET + len(NEW_VERSION)] = NEW_VERSION
    print(f"版本 {OLD_VERSION.decode()} -> {NEW_VERSION.decode()}")

    ck = checksum(img)
    img[len(img) - 33] = ck
    h = hashlib.sha256(bytes(img[:-32])).hexdigest()
    img[len(img) - 32:] = bytes.fromhex(h)
    assert checksum(img) == img[len(img) - 33]
    assert hashlib.sha256(bytes(img[:-32])).hexdigest() == bytes(img[-32:]).hex()
    print(f"checksum=0x{ck:02x}  sha256 ok")

    open(OUT_PATH, "wb").write(bytes(img))
    ndiff = sum(1 for a, b in zip(open(IN_PATH, "rb").read(), img) if a != b)
    print(f"输出 {OUT_PATH}  与 1.3.0 差异 {ndiff} 字节")


if __name__ == "__main__":
    main()
