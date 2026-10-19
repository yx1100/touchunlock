#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 v3（固件 1.2.0）基础上生成 v4 补丁镜像（固件 1.3.0）。

新增能力：识别到指纹但不键入密码时（判定函数返回非 0，即 app 未处于「有密码框」
状态），设备主动给 app 发一条 fp=15 {"matchId":N}，让 app 据此触发该指纹绑定的快捷键。
不发任何密码，不改动键入逻辑。

原理：判定函数返回非 0 时，键入路径会 `jal 0x420050ea`（v2/v3 把这里改成了空 ret）。
把这个空 ret 改成跳到一小段 notify_match，尾调用固件自带的指纹回包函数
fpReply(0x42004e9a)，参数 a1=状态码0、a2=matchId、a3=100 —— 这正是 fpReply
发 fp=15 成功回包的分支（源码判定：状态码==0 且 matchId<100）。fpReply 忽略 a0，
BLE 对象从全局取，所以从这里调用是安全的。

两处改动（都在 v3 封死 0x420050ea 后腾出的死代码区内，不碰其它任何字节）：
  1. 0x420050ea: 8082 (ret) -> c.j 0x4200517a
  2. 0x4200517a: notify_match 12 字节：
        c.mv a2,a1 ; c.li a1,0 ; li a3,0x64 ; j 0x42004e9a(fpReply)
  另外把 DROM 版本字符串 1.2.0 -> 1.3.0。

镜像末尾 1 字节异或校验（种子 0xEF，覆盖各段数据）+ 32 字节 SHA-256 已重算。
"""
import hashlib
import struct
import sys

IN_PATH = "firmware/TouchUnlock-1.2.0.bin"
OUT_PATH = "firmware/TouchUnlock-1.3.0.bin"
BASE_SHA256 = "a785291aa0e7095b2e1c50e63d8126d7e01584318b4cf78edb29006ed85f1cae"
IMG_SIZE = 975472

VERSION_OFFSET = 0x178C          # DROM 文件偏移，\0 结尾
OLD_VERSION = b"1.2.0"
NEW_VERSION = b"1.3.0"

SLOT = 0x420050EA                 # 死 ret（判定返回非 0 时被 jal 到这里）
TRAMP = 0x4200517A               # 死代码区，放 notify_match
FPREPLY = 0x42004E9A             # 指纹回包函数
SLOT_OLD = "8280"                # 小端 0x8082 = ret
TRAMP_OLD = "010041e6efb02fb52a84"  # 待覆盖的死字节（仅自检用）


def v2f(vaddr):
    """IROM 虚拟地址 -> 镜像文件偏移。段 vaddr 0x42000020 <-> file 0x50020。"""
    return vaddr - 0x41FB0000


def enc_cj(pc, target):
    """编码 c.j（CJ 型）。"""
    off = target - pc
    assert -(1 << 11) <= off < (1 << 11) and off % 2 == 0, f"c.j out of range: {off:#x}"
    imm = off & 0xFFF
    def b(i):
        return (imm >> i) & 1
    h = (0b101 << 13) | (b(11) << 12) | (b(4) << 11) | (b(9) << 10) | (b(8) << 9) \
        | (b(10) << 8) | (b(6) << 7) | (b(7) << 6) | (b(3) << 5) | (b(2) << 4) \
        | (b(1) << 3) | (b(5) << 2) | 0b01
    return struct.pack("<H", h)


def enc_jal(rd, pc, target):
    off = target - pc
    assert off % 2 == 0 and -(1 << 20) <= off < (1 << 20), f"jal out of range: {off:#x}"
    imm = off & 0x1FFFFF
    word = (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21
            | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xFF) << 12
            | (rd & 0x1F) << 7 | 0x6F)
    return struct.pack("<I", word)


def notify_match():
    """c.mv a2,a1 ; c.li a1,0 ; li a3,0x64 ; j fpReply。"""
    code = b""
    code += struct.pack("<H", 0x862E)                 # c.mv a2,a1
    code += struct.pack("<H", 0x4581)                 # c.li a1,0
    code += struct.pack("<I", 0x06400693)             # addi a3,x0,0x64
    code += enc_jal(0, TRAMP + len(code), FPREPLY)    # j fpReply
    assert len(code) == 12, len(code)
    return code


def segments(img):
    n = img[1]
    off = 24
    out = []
    for _ in range(n):
        addr, ln = struct.unpack_from("<II", img, off)
        off += 8
        out.append((addr, off, ln))
        off += ln
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
    if hashlib.sha256(img).hexdigest() != BASE_SHA256:
        sys.exit("基准镜像 sha256 不符，中止")

    # 自检：原字节
    for va, exp in ((SLOT, SLOT_OLD), (TRAMP, TRAMP_OLD)):
        got = bytes(img[v2f(va):v2f(va) + len(exp) // 2]).hex()
        if got != exp:
            sys.exit(f"0x{va:08x} 原字节不符: 期望 {exp} 实际 {got}")
    if img[VERSION_OFFSET:VERSION_OFFSET + 6] != OLD_VERSION + b"\x00":
        sys.exit("版本字符串不是 1.2.0，中止")

    changes = [
        (SLOT, enc_cj(SLOT, TRAMP), "判定返回非 0 的死 ret 改为 c.j notify_match"),
        (TRAMP, notify_match(), "notify_match: 尾调用 fpReply 发 fp=15 {matchId}"),
    ]
    print("=== 补丁写入 ===")
    for va, blob, desc in changes:
        off = v2f(va)
        print(f"[{desc}]\n  vaddr 0x{va:08x} file 0x{off:06x} {len(blob)}B")
        print(f"  旧 {bytes(img[off:off+len(blob)]).hex()}  新 {blob.hex()}")
        img[off:off + len(blob)] = blob

    img[VERSION_OFFSET:VERSION_OFFSET + len(NEW_VERSION)] = NEW_VERSION
    print(f"版本 {OLD_VERSION.decode()} -> {NEW_VERSION.decode()} @0x{VERSION_OFFSET:x}")

    # 末尾校验重算
    ck = checksum(img)
    img[len(img) - 33] = ck
    h = hashlib.sha256(bytes(img[:-32])).hexdigest()
    img[len(img) - 32:] = bytes.fromhex(h)
    assert checksum(img) == img[len(img) - 33]
    assert hashlib.sha256(bytes(img[:-32])).hexdigest() == bytes(img[-32:]).hex()
    print(f"checksum=0x{ck:02x}  sha256(trailer ok)")

    open(OUT_PATH, "wb").write(bytes(img))
    ndiff = sum(1 for a, b in zip(open(IN_PATH, "rb").read(), img) if a != b)
    print(f"输出 {OUT_PATH}  {len(img)}B  与 1.2.0 差异 {ndiff} 字节")


if __name__ == "__main__":
    main()
