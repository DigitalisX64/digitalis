"""Parse and merge Android resources.arsc tables (config-split merge only).

Parsing keeps each top-level chunk's raw bytes, so parse->serialize is byte-identical
for any input. Merge only ever *appends* a split's per-config ResTable_type chunks to the
base package and remaps TYPE_STRING values into a unified global string pool — relying on
the invariant that base and all splits come from one aapt2 build (same package id, type
ids and key string pool). Entry encodings we cannot safely remap (sparse / offset16 /
compact) raise, letting the caller fall back to a native-only merge.
"""
import struct
from dataclasses import dataclass, field
from typing import List, Optional

RES_TABLE = 0x0002
STRING_POOL = 0x0001
TABLE_PACKAGE = 0x0200
TABLE_TYPE = 0x0201
TABLE_TYPE_SPEC = 0x0202

TYPE_STRING = 0x03

FLAG_SPARSE = 0x01
FLAG_OFFSET16 = 0x02
ENTRY_FLAG_COMPLEX = 0x0001
ENTRY_FLAG_COMPACT = 0x0008

# Fixed offsets for the classic ResTable_type layout we emit/remap.
_CONFIG_START = 20            # 8 (ResChunk) + 4 (id/flags/res) + 4 + 4
_CONFIG_DENSITY = 14         # byte offset of density within ResTable_config
_DENSITY_LABELS = {0: "DEFAULT", 480: "xxhdpi", 640: "xxxhdpi", 320: "xhdpi"}


@dataclass
class Chunk:
    type: int
    header_size: int
    raw: bytes
    children: List["Chunk"] = field(default_factory=list)


def _iter_chunks(buf, start, end):
    off = start
    out = []
    while off < end:
        ctyp, hsize, csize = struct.unpack_from("<HHI", buf, off)
        out.append((ctyp, hsize, csize, off))
        off += csize
    return out


def parse(buf):
    ctyp, hsize, csize = struct.unpack_from("<HHI", buf, 0)
    assert ctyp == RES_TABLE, "not a resources.arsc (type 0x%04x)" % ctyp
    root = Chunk(ctyp, hsize, buf[:csize])
    for ctyp2, hsize2, csize2, off2 in _iter_chunks(buf, hsize, csize):
        root.children.append(Chunk(ctyp2, hsize2, buf[off2:off2 + csize2]))
    return root


def serialize(table):
    body = b"".join(c.raw for c in table.children)
    head = bytearray(table.raw[:table.header_size])
    struct.pack_into("<I", head, 4, table.header_size + len(body))
    return bytes(head) + body


class StringPool:
    def __init__(self, chunk_bytes):
        self.raw = chunk_bytes
        (typ, hsize, size, count, styc, flags, strstart,
         stystart) = struct.unpack_from("<HHIIIIII", chunk_bytes, 0)
        self.flags = flags
        self.utf8 = bool(flags & (1 << 8))
        self.strings = []
        offs = [struct.unpack_from("<I", chunk_bytes, 28 + 4 * i)[0]
                for i in range(count)]
        for o in offs:
            self.strings.append(self._decode(chunk_bytes, strstart + o))

    def _decode(self, buf, p):
        if self.utf8:
            n = buf[p]; p += 1
            if n & 0x80:
                n = ((n & 0x7f) << 8) | buf[p]; p += 1
            blen = buf[p]; p += 1
            if blen & 0x80:
                blen = ((blen & 0x7f) << 8) | buf[p]; p += 1
            return buf[p:p + blen].decode("utf-8")
        n = struct.unpack_from("<H", buf, p)[0]; p += 2
        return buf[p:p + 2 * n].decode("utf-16-le")

    def index_of(self, s):
        return self.strings.index(s) if s in self.strings else -1

    def append(self, s):
        if s in self.strings:
            return self.strings.index(s)
        self.strings.append(s)
        return len(self.strings) - 1

    @staticmethod
    def _enc_len(n):
        return bytes([n]) if n < 0x80 else bytes([0x80 | (n >> 8), n & 0xff])

    def encode(self):
        data, offsets = b"", b""
        blob = b""
        for s in self.strings:
            offsets += struct.pack("<I", len(blob))
            if self.utf8:
                b = s.encode("utf-8")
                blob += self._enc_len(len(s)) + self._enc_len(len(b)) + b + b"\x00"
            else:
                u = s.encode("utf-16-le")
                blob += struct.pack("<H", len(s)) + u + b"\x00\x00"
        while len(blob) % 4:
            blob += b"\x00"
        strings_start = 28 + len(offsets)
        size = 28 + len(offsets) + len(blob)
        head = struct.pack("<HHIIIIII", STRING_POOL, 28, size, len(self.strings),
                           0, self.flags, strings_start, 0)
        return head + offsets + blob


def _global_pool_chunk(table):
    for c in table.children:
        if c.type == STRING_POOL:
            return c
    raise ValueError("no global string pool")


def _package_chunk(table):
    for c in table.children:
        if c.type == TABLE_PACKAGE:
            return c
    raise ValueError("no package chunk")


def _split_package_children(pkg_raw):
    typ, hsize, size = struct.unpack_from("<HHI", pkg_raw, 0)
    out = []
    off = hsize
    while off < size:
        ctyp, chsize, csize = struct.unpack_from("<HHI", pkg_raw, off)
        out.append((ctyp, pkg_raw[off:off + csize]))
        off += csize
    return out


def _rebuild_package(pkg_raw, children):
    typ, hsize, size = struct.unpack_from("<HHI", pkg_raw, 0)
    head = bytearray(pkg_raw[:hsize])
    body = b"".join(c for _, c in children)
    struct.pack_into("<I", head, 4, hsize + len(body))
    return bytes(head) + body


def _remap_value(b, vp, remap):
    v_size, v_res0, v_type = struct.unpack_from("<HBB", b, vp)
    if v_type == TYPE_STRING:
        old = struct.unpack_from("<I", b, vp + 4)[0]
        if old in remap:
            struct.pack_into("<I", b, vp + 4, remap[old])


def _remap_type_chunk(type_raw, remap):
    b = bytearray(type_raw)
    typ, hsize, size = struct.unpack_from("<HHI", b, 0)
    flags = b[9]
    if flags & (FLAG_SPARSE | FLAG_OFFSET16):
        raise NotImplementedError("sparse/offset16 type chunk")
    entry_count = struct.unpack_from("<I", b, 12)[0]
    entries_start = struct.unpack_from("<I", b, 16)[0]
    idx_array = hsize
    for i in range(entry_count):
        off_i = struct.unpack_from("<I", b, idx_array + 4 * i)[0]
        if off_i == 0xFFFFFFFF:
            continue
        ep = entries_start + off_i
        e_size, e_flags = struct.unpack_from("<HH", b, ep)
        if e_flags & ENTRY_FLAG_COMPACT:
            raise NotImplementedError("compact entry")
        if e_flags & ENTRY_FLAG_COMPLEX:
            parent, count = struct.unpack_from("<II", b, ep + e_size)
            mp = ep + e_size + 8
            for _ in range(count):
                _remap_value(b, mp + 4, remap)   # ResTable_map: name(4) + Res_value
                mp += 4 + 8
        else:
            _remap_value(b, ep + e_size, remap)
    return bytes(b)


def merge(base, splits):
    base_pool = StringPool(_global_pool_chunk(base).raw)
    base_pkg = _package_chunk(base)
    base_children = _split_package_children(base_pkg.raw)
    for split in splits:
        sp = StringPool(_global_pool_chunk(split).raw)
        remap = {i: base_pool.append(s) for i, s in enumerate(sp.strings)}
        for ctyp, craw in _split_package_children(_package_chunk(split).raw):
            if ctyp == TABLE_TYPE:
                base_children.append((ctyp, _remap_type_chunk(craw, remap)))
    base_pkg.raw = _rebuild_package(base_pkg.raw, base_children)
    _global_pool_chunk(base).raw = base_pool.encode()
    return base


# --- introspection helpers used by tests ---

def global_strings(table):
    return StringPool(_global_pool_chunk(table).raw).strings


def _config_label(type_raw):
    density = struct.unpack_from("<H", type_raw,
                                 _CONFIG_START + _CONFIG_DENSITY)[0]
    return _DENSITY_LABELS.get(density, "density%d" % density)


def list_type_configs(table, type_name=None):
    out = []
    for ctyp, craw in _split_package_children(_package_chunk(table).raw):
        if ctyp == TABLE_TYPE:
            out.append(_config_label(craw))
    return out
