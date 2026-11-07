#!/usr/bin/env python3
"""生成一台开发板的出厂身份分区 fac.bin(网盘绑定用)。

用 ESP-IDF 的 Python 环境跑(自带 cryptography 与 esp_idf_nvs_partition_gen):
  ~/.espressif/python_env/idf6.1_py3.14_env/bin/python tools/factory_identity.py

实验室出厂 CA 私钥只在本机签名,不打印、不复制;输出目录默认在仓库外,0700,文件 0600。
只输出设备号、证书指纹与路径。烧录另行授权:
  esptool.py write_flash 0x410000 <out>/fac.bin
"""
import argparse
import datetime
import os
import secrets
import string
import subprocess
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

LAB = Path.home() / "Data/code/baidu/netdisk/hardware-agent/projects/agent-hardware/.local/lab/ahd"
ALPHABET = string.digits + string.ascii_lowercase
PARTITION_SIZE = "0x6000"  # 与 partitions.csv 的 fac 一致


def new_id() -> str:
    return "yd_" + "".join(secrets.choice(ALPHABET) for _ in range(26))


def issue(device_id: str, ca_cert: x509.Certificate, ca_key) -> tuple[bytes, bytes]:
    key = ec.generate_private_key(ec.SECP256R1())
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, device_id)]))
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        # 与 agent-hardware 签发的出厂证书同形:urn:ah:factory:<id>
        .add_extension(x509.SubjectAlternativeName([x509.UniformResourceIdentifier(f"urn:ah:factory:{device_id}")]), False)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), False)
        # 抄 CA 自己的 SKI:Go 新版按截断 SHA-256 算,与按公钥重算的 SHA-1 不同,链会断
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(
            ca_cert.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value), False)
        .sign(ca_key, hashes.SHA256())
    )
    der = cert.public_bytes(serialization.Encoding.DER)
    assert len(der) <= 512, "固件只收 512 字节以内的证书"
    return der, key.private_numbers().private_value.to_bytes(32, "big")


def write_private(path: Path, data: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(data)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--ca-dir", type=Path, default=LAB, help="含 factory.crt / factory.key 的目录")
    p.add_argument("--out", type=Path, default=Path.home() / ".local/share/yahadesk/factory")
    a = p.parse_args()

    ca_cert = x509.load_pem_x509_certificate((a.ca_dir / "factory.crt").read_bytes())
    ca_key = serialization.load_pem_private_key((a.ca_dir / "factory.key").read_bytes(), None)
    device_id = new_id()
    der, scalar = issue(device_id, ca_cert, ca_key)

    out = a.out / device_id
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    csv = out / "fac.csv"
    write_private(csv, f"key,type,encoding,value\nfac,namespace,,\nid,data,string,{device_id}\n"
                       f"cert,data,hex2bin,{der.hex()}\nkey,data,hex2bin,{scalar.hex()}\n")
    (out / "cert.der").write_bytes(der)
    binary = out / "fac.bin"
    rc = subprocess.run([sys.executable, "-m", "esp_idf_nvs_partition_gen", "generate", str(csv), str(binary),
                         PARTITION_SIZE], stdout=subprocess.DEVNULL).returncode
    if rc:
        return rc
    os.chmod(binary, 0o600)
    fp = x509.load_der_x509_certificate(der).fingerprint(hashes.SHA256()).hex()
    print(f"device_id {device_id}\ncert_sha256 {fp}\nout {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
