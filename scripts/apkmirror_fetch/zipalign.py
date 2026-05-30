"""Pure-Python zipalign: pad local-header extra fields so stored data aligns.

A v2-signed APK must have stored (uncompressed) entries aligned: 4 bytes generally,
4096 bytes for native libraries so they can be mmapped directly.
"""
import struct
import zipfile


def align(src, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for zi in zin.infolist():
            data = zin.read(zi.filename)
            new = zipfile.ZipInfo(zi.filename, date_time=zi.date_time)
            new.compress_type = zi.compress_type
            new.external_attr = zi.external_attr
            new.internal_attr = zi.internal_attr
            new.create_system = zi.create_system
            if zi.compress_type == zipfile.ZIP_STORED:
                align_to = 4096 if zi.filename.endswith(".so") else 4
                base = zout.fp.tell() + 30 + len(new.filename.encode("utf-8"))
                pad = (-base) % align_to
                new.extra = b"\x00" * pad
            zout.writestr(new, data)


def data_offsets(path):
    """Map entry name -> absolute file offset where its data begins."""
    offs = {}
    with open(path, "rb") as f:
        buf = f.read()
    p = 0
    while buf[p:p + 4] == b"PK\x03\x04":
        comp_size = struct.unpack_from("<I", buf, p + 18)[0]
        n, m = struct.unpack_from("<HH", buf, p + 26)
        name = buf[p + 30:p + 30 + n].decode("utf-8")
        data_start = p + 30 + n + m
        offs[name] = data_start
        p = data_start + comp_size
    return offs
