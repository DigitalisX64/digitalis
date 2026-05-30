"""Generate a debug key and apply APK v1 (JAR) + v2 signatures, pure Python.

v2 reference: https://source.android.com/docs/security/features/apksigning/v2
Length-prefixed sequences are nested: a sequence is u32(total) followed by a
concatenation of u32(len)+element items.
"""
import base64
import datetime
import hashlib
import os
import struct
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.serialization import pkcs7
from cryptography.x509.oid import NameOID

V2_BLOCK_ID = 0x7109871A
APK_SIG_MAGIC = b"APK Sig Block 42"
SIG_ALGO_RSA_PKCS1_SHA256 = 0x0103


# ----- key management -----

def _load_or_make_key(cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    key_path = os.path.join(cache_dir, "debug-key.pem")
    cert_path = os.path.join(cache_dir, "debug-cert.pem")
    if os.path.exists(key_path) and os.path.exists(cert_path):
        key = serialization.load_pem_private_key(
            open(key_path, "rb").read(), password=None)
        cert = x509.load_pem_x509_certificate(open(cert_path, "rb").read())
        return key, cert
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Digitalis Debug")])
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(1)
            .not_valid_before(datetime.datetime(2020, 1, 1))
            .not_valid_after(datetime.datetime(2099, 1, 1))
            .sign(key, hashes.SHA256()))
    open(key_path, "wb").write(key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()))
    open(cert_path, "wb").write(cert.public_bytes(serialization.Encoding.PEM))
    return key, cert


# ----- length-prefix helpers -----

def _lp(b):
    return struct.pack("<I", len(b)) + b


def _seq(elements):
    return _lp(b"".join(_lp(e) for e in elements))


def _take_lp(b, off):
    n = struct.unpack_from("<I", b, off)[0]
    return b[off + 4:off + 4 + n], off + 4 + n


# ----- v1 (JAR) signing -----

def _manifest_line(key, value):
    raw = ("%s: %s" % (key, value)).encode("utf-8")
    chunks = [raw[:70]]
    rest = raw[70:]
    while rest:
        chunks.append(b" " + rest[:69])
        rest = rest[69:]
    return b"\r\n".join(chunks) + b"\r\n"


def _b64(b):
    return base64.b64encode(b).decode("ascii")


def _v1_sign(src, dst, key, cert):
    with zipfile.ZipFile(src) as zin:
        entries = [(zi.filename, zin.read(zi.filename))
                   for zi in zin.infolist()
                   if not zi.filename.startswith("META-INF/")
                   and not zi.is_dir()]

    main = (_manifest_line("Manifest-Version", "1.0")
            + _manifest_line("Created-By", "Digitalis") + b"\r\n")
    sections = []
    for name, data in entries:
        sec = (_manifest_line("Name", name)
               + _manifest_line("SHA-256-Digest",
                                _b64(hashlib.sha256(data).digest())) + b"\r\n")
        sections.append(sec)
    manifest_full = main + b"".join(sections)

    sf_main = (_manifest_line("Signature-Version", "1.0")
               + _manifest_line("SHA-256-Digest-Manifest",
                                _b64(hashlib.sha256(manifest_full).digest()))
               + _manifest_line("SHA-256-Digest-Manifest-Main-Attributes",
                                _b64(hashlib.sha256(main).digest()))
               + _manifest_line("Created-By", "Digitalis") + b"\r\n")
    sf_sections = []
    for (name, _), sec in zip(entries, sections):
        sf_sections.append(
            _manifest_line("Name", name)
            + _manifest_line("SHA-256-Digest",
                             _b64(hashlib.sha256(sec).digest())) + b"\r\n")
    sf_full = sf_main + b"".join(sf_sections)

    signature = pkcs7.PKCS7SignatureBuilder().set_data(sf_full).add_signer(
        cert, key, hashes.SHA256()).sign(
        serialization.Encoding.DER,
        [pkcs7.PKCS7Options.DetachedSignature,
         pkcs7.PKCS7Options.NoAttributes,
         pkcs7.PKCS7Options.Binary])

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for zi in zin.infolist():
            if zi.filename.startswith("META-INF/"):
                continue
            zout.writestr(zi, zin.read(zi.filename))
        zout.writestr("META-INF/MANIFEST.MF", manifest_full)
        zout.writestr("META-INF/CERT.SF", sf_full)
        zout.writestr("META-INF/CERT.RSA", signature)


# ----- v2 signing -----

def _eocd_offset(buf):
    i = buf.rfind(b"PK\x05\x06")
    if i < 0:
        raise ValueError("no EOCD record")
    return i


def _chunk_digests(data):
    digs = []
    for i in range(0, len(data), 1 << 20):
        chunk = data[i:i + (1 << 20)]
        h = hashlib.sha256()
        h.update(b"\xa5")
        h.update(struct.pack("<I", len(chunk)))
        h.update(chunk)
        digs.append(h.digest())
    if not data:                       # a zero-length section still has no chunks
        return []
    return digs


def _v2_digest(contents, central_dir, eocd):
    digs = (_chunk_digests(contents) + _chunk_digests(central_dir)
            + _chunk_digests(eocd))
    top = hashlib.sha256()
    top.update(b"\x5a")
    top.update(struct.pack("<I", len(digs)))
    for d in digs:
        top.update(d)
    return top.digest()


def _build_v2_value(digest, signature, pubkey_der):
    digest_element = struct.pack("<I", SIG_ALGO_RSA_PKCS1_SHA256) + _lp(digest)
    digests = _seq([digest_element])
    certs = _seq([_CERT_DER_HOLDER[0]])
    attrs = _seq([])
    signed_data = digests + certs + attrs
    sig_element = struct.pack("<I", SIG_ALGO_RSA_PKCS1_SHA256) + _lp(signature)
    signatures = _seq([sig_element])
    signer = _lp(signed_data) + signatures + _lp(pubkey_der)
    return _seq([signer]), signed_data


# A tiny module-level holder so _build_v2_value can see the cert DER without
# threading it through every call; set within _add_v2.
_CERT_DER_HOLDER = [b""]


def _add_v2(path_in, path_out, key, cert):
    buf = bytearray(open(path_in, "rb").read())
    eo = _eocd_offset(buf)
    cd_off = struct.unpack_from("<I", buf, eo + 16)[0]
    contents = bytes(buf[:cd_off])
    central_dir = bytes(buf[cd_off:eo])
    eocd = bytearray(buf[eo:])

    eocd_for_digest = bytearray(eocd)
    struct.pack_into("<I", eocd_for_digest, 16, len(contents))
    digest = _v2_digest(contents, central_dir, bytes(eocd_for_digest))

    # build signed data (need cert DER available to _build_v2_value)
    cert_der = cert.public_bytes(serialization.Encoding.DER)
    _CERT_DER_HOLDER[0] = cert_der
    pubkey_der = cert.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo)

    # first pass to get signed_data, then sign it, then rebuild value
    _, signed_data = _build_v2_value(digest, b"", pubkey_der)
    signature = key.sign(signed_data, padding.PKCS1v15(), hashes.SHA256())
    v2_value, _ = _build_v2_value(digest, signature, pubkey_der)

    pair = struct.pack("<Q", 4 + len(v2_value)) \
        + struct.pack("<I", V2_BLOCK_ID) + v2_value
    block_size = len(pair) + 8 + 16
    signing_block = (struct.pack("<Q", block_size) + pair
                     + struct.pack("<Q", block_size) + APK_SIG_MAGIC)

    new_cd_off = len(contents) + len(signing_block)
    struct.pack_into("<I", eocd, 16, new_cd_off)
    with open(path_out, "wb") as f:
        f.write(contents)
        f.write(signing_block)
        f.write(central_dir)
        f.write(eocd)


def has_v2_block(path):
    return APK_SIG_MAGIC in open(path, "rb").read()


def verify(path):
    """Self-verify the v2 signature: recompute the digest and check the RSA sig."""
    buf = bytearray(open(path, "rb").read())
    eo = _eocd_offset(buf)
    cd_off = struct.unpack_from("<I", buf, eo + 16)[0]
    if buf[cd_off - 16:cd_off] != APK_SIG_MAGIC:
        return False
    block_size = struct.unpack_from("<Q", buf, cd_off - 24)[0]
    sb_start = cd_off - 8 - block_size
    contents = bytes(buf[:sb_start])
    central_dir = bytes(buf[cd_off:eo])
    eocd = bytearray(buf[eo:])
    struct.pack_into("<I", eocd, 16, len(contents))
    recomputed = _v2_digest(contents, central_dir, bytes(eocd))

    # walk: first pair after the leading u64 size
    p = sb_start + 8
    pair_len = struct.unpack_from("<Q", buf, p)[0]
    pid = struct.unpack_from("<I", buf, p + 8)[0]
    if pid != V2_BLOCK_ID:
        return False
    v2_value = bytes(buf[p + 12:p + 8 + pair_len])
    signers, _ = _take_lp(v2_value, 0)
    signer, _ = _take_lp(signers, 0)
    signed_data, q = _take_lp(signer, 0)
    signatures, q = _take_lp(signer, q)
    public_key, q = _take_lp(signer, q)
    digests_seq, _ = _take_lp(signed_data, 0)
    digest_element, _ = _take_lp(digests_seq, 0)
    embedded_digest, _ = _take_lp(digest_element, 4)
    sig_element, _ = _take_lp(signatures, 0)
    signature, _ = _take_lp(sig_element, 4)

    if embedded_digest != recomputed:
        return False
    pub = serialization.load_der_public_key(public_key)
    try:
        pub.verify(signature, signed_data, padding.PKCS1v15(), hashes.SHA256())
    except Exception:
        return False
    return True


def sign(src, dst, cache_dir):
    from apkmirror_fetch import zipalign
    key, cert = _load_or_make_key(cache_dir)
    tmp = dst + ".v1"
    aligned = dst + ".aligned"
    try:
        _v1_sign(src, tmp, key, cert)
        zipalign.align(tmp, aligned)
        _add_v2(aligned, dst, key, cert)
    finally:
        for f in (tmp, aligned):
            if os.path.exists(f):
                os.remove(f)
