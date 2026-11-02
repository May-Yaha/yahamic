#!/usr/bin/env python3
"""协议 v2 测试向量:Mac 单测(Tests/YahamicProtocolTests)与固件自检(protocol.cpp)共用。

用法:~/.espressif/python_env/idf5.5_py3.12_env/bin/python -I tools/protocol_vectors.py
(需要 cryptography;系统 python3 没装)。改协议后重跑,把输出贴进两边。
"""
import hashlib
import hmac
import struct

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

CODE = b"ABCD2345EF"
DN = bytes(range(16))
MN = bytes(range(16, 32))

k = hashlib.pbkdf2_hmac("sha256", CODE, b"yahamic-v2", 4096, 32)


def mac(label: bytes) -> bytes:
    return hmac.new(k, label + DN + MN, hashlib.sha256).digest()


proof_m, proof_d, k_d2m, k_m2d = mac(b"m"), mac(b"d"), mac(b"d2m"), mac(b"m2d")

# 音频包:type 3,flags 0,seq 5,ts 300;载荷 "opus"。
seq = 5
header = b"Y" + bytes([2, 3, 0]) + struct.pack("<II", seq, 300)
nonce = bytes(8) + struct.pack("<I", seq)
sealed = ChaCha20Poly1305(k_d2m).encrypt(nonce, b"opus", header)

# 反方向(Mac→设备)控制包:type 6,flags 1,seq 1,ts 0;载荷 "muted 1\ncmd 1\n"。
c_header = b"Y" + bytes([2, 6, 1]) + struct.pack("<II", 1, 0)
c_sealed = ChaCha20Poly1305(k_m2d).encrypt(bytes(8) + struct.pack("<I", 1), b"muted 1\ncmd 1\n", c_header)

for name, value in [("k", k), ("proof_m", proof_m), ("proof_d", proof_d),
                    ("k_d2m", k_d2m), ("k_m2d", k_m2d),
                    ("header", header), ("sealed", sealed),
                    ("c_header", c_header), ("c_sealed", c_sealed)]:
    print(f"{name} = {value.hex()}")
