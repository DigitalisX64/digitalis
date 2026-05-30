"""Build tiny binary AXML blobs used by test_axml / test_gms."""
import struct
from apkmirror_fetch.axml import _string_pool


def _resmap(ids):
    return struct.pack("<HHI", 0x0180, 8, 8 + 4 * len(ids)) + b"".join(
        struct.pack("<I", i) for i in ids)


def _start_elem(name_i, attrs):
    # node: lineNumber(-1) comment(-1) ns(-1) name(name_i)
    node = struct.pack("<iiii", -1, -1, -1, name_i)
    # attrExt tail: attributeStart=20 attributeSize=20 count idIndex classIndex styleIndex
    node += struct.pack("<HHHHHH", 20, 20, len(attrs), 0, 0, 0)
    body = b""
    for ns_i, nm_i, raw_i, dt, data in attrs:
        body += struct.pack("<iiiIi", ns_i, nm_i, raw_i, (dt << 24), data)
    chunk = node + body
    return struct.pack("<HHI", 0x0102, 16, 8 + len(chunk)) + chunk


def _end_elem(name_i):
    inner = struct.pack("<iiii", -1, -1, -1, name_i)
    return struct.pack("<HHI", 0x0103, 16, 8 + len(inner)) + inner


def _wrap(inner):
    return struct.pack("<HHI", 0x0003, 8, 8 + len(inner)) + inner


def build_bytes():
    # 0 android 1 manifest 2 requiredSplitTypes 3 meta-data 4 name
    # 5 com.android.vending.splits.required 6 ""
    strings = ["android", "manifest", "requiredSplitTypes", "meta-data",
               "name", "com.android.vending.splits.required", ""]
    sp = _string_pool(strings)
    resmap = _resmap([0, 0, 0x0101064e, 0, 0x01010003, 0, 0])
    NS, MANIFEST, REQ, META, NAME, REQVAL, EMPTY = range(7)
    manifest = _start_elem(MANIFEST, [(NS, REQ, EMPTY, 3, REQVAL)])
    meta = _start_elem(META, [(NS, NAME, REQVAL, 3, REQVAL)])
    body = manifest + meta + _end_elem(META) + _end_elem(MANIFEST)
    return _wrap(sp + resmap + body)


def build_bytes_with_meta_name(meta_value):
    strings = ["android", "manifest", "requiredSplitTypes", "meta-data",
               "name", meta_value, ""]
    sp = _string_pool(strings)
    resmap = _resmap([0, 0, 0x0101064e, 0, 0x01010003, 0, 0])
    NS, MANIFEST, REQ, META, NAME, METAVAL, EMPTY = range(7)
    manifest = _start_elem(MANIFEST, [])
    meta = _start_elem(META, [(NS, NAME, METAVAL, 3, METAVAL)])
    body = manifest + meta + _end_elem(META) + _end_elem(MANIFEST)
    return _wrap(sp + resmap + body)
