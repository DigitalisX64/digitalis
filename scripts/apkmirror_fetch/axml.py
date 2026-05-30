"""Minimal Android binary-XML (AXML) reader, writer and split-marker patcher.

Layout reference (AOSP ResourceTypes.h):
  ResChunk_header        = uint16 type, uint16 headerSize, uint32 size   (8 bytes)
  START_ELEMENT (0x0102) = ResChunk_header(8) + lineNumber(4) + comment(4)
                           + ResXMLTree_attrExt { ns(4) name(4)
                             attributeStart(2) attributeSize(2) attributeCount(2)
                             idIndex(2) classIndex(2) styleIndex(2) }
  attributes begin at  node_off + 16 + attributeStart  (attributeStart is measured
                           from the start of the attrExt struct, which is at +16).
  ResXMLTree_attribute   = ns(4) name(4) rawValue(4) Res_value{size(2) res0(1)
                           dataType(1) data(4)}                          (20 bytes)
"""
import struct
from dataclasses import dataclass, field
from typing import List, Optional

RES_XML = 0x0003
STRING_POOL = 0x0001
RES_MAP = 0x0180
START_NS = 0x0100
END_NS = 0x0101
START_ELEM = 0x0102
END_ELEM = 0x0103
CDATA = 0x0104

TYPE_STRING = 0x03


def _read_string_pool(buf, off):
    (typ, hsize, size, count, _styc, flags, strstart,
     _stystart) = struct.unpack_from("<HHIIIIII", buf, off)
    assert typ == STRING_POOL, "expected string pool, got 0x%04x" % typ
    utf8 = bool(flags & (1 << 8))
    offs = [struct.unpack_from("<I", buf, off + 28 + 4 * i)[0]
            for i in range(count)]
    base = off + strstart
    strings = []
    for o in offs:
        p = base + o
        if utf8:
            n = buf[p]; p += 1
            if n & 0x80:
                n = ((n & 0x7f) << 8) | buf[p]; p += 1
            blen = buf[p]; p += 1
            if blen & 0x80:
                blen = ((blen & 0x7f) << 8) | buf[p]; p += 1
            strings.append(buf[p:p + blen].decode("utf-8"))
        else:
            n = struct.unpack_from("<H", buf, p)[0]; p += 2
            strings.append(buf[p:p + 2 * n].decode("utf-16-le"))
    return strings, off + size


@dataclass
class Attr:
    ns: Optional[str]
    name: str
    value: Optional[str]
    data_type: int
    data: int


@dataclass
class Element:
    name: str
    attributes: List["Attr"] = field(default_factory=list)
    children: List["Element"] = field(default_factory=list)

    def attr(self, name):
        for a in self.attributes:
            if a.name == name:
                return a.value
        return None


@dataclass
class Document:
    root: Element


def _s(strings, idx):
    return strings[idx] if 0 <= idx < len(strings) else None


def parse(buf):
    typ, hsize, total = struct.unpack_from("<HHI", buf, 0)
    assert typ == RES_XML, "not an AXML resource (type 0x%04x)" % typ
    off = hsize
    strings = []
    stack, root = [], None
    while off < total:
        ctyp, chsize, csize = struct.unpack_from("<HHI", buf, off)
        if ctyp == STRING_POOL:
            strings, _ = _read_string_pool(buf, off)
        elif ctyp == START_ELEM:
            ns_i, name_i = struct.unpack_from("<ii", buf, off + 16)
            attr_start, attr_size, attr_count = \
                struct.unpack_from("<HHH", buf, off + 24)
            el = Element(name=_s(strings, name_i))
            ap = off + 16 + attr_start
            for _ in range(attr_count):
                a_ns, a_name, a_raw, a_tv = struct.unpack_from("<iiiI", buf, ap)
                a_type = (a_tv >> 24) & 0xff
                a_data = struct.unpack_from("<i", buf, ap + 16)[0]
                val = _s(strings, a_raw) if a_raw != -1 else None
                if val is None and a_type == TYPE_STRING:
                    val = _s(strings, a_data)
                el.attributes.append(Attr(_s(strings, a_ns), _s(strings, a_name),
                                          val, a_type, a_data))
                ap += attr_size
            if root is None:
                root = el
            if stack:
                stack[-1].children.append(el)
            stack.append(el)
        elif ctyp == END_ELEM:
            if stack:
                stack.pop()
        off += csize
    return Document(root=root)


_DROP_META_NAMES = {"com.android.vending.splits.required",
                    "com.android.vending.splits"}
_DROP_MANIFEST_ATTRS = {"requiredSplitTypes", "splitTypes", "isSplitRequired"}


def patch_drop_split_markers(buf):
    typ, hsize, total = struct.unpack_from("<HHI", buf, 0)
    assert typ == RES_XML
    # locate string pool for name lookups
    strings = []
    p = hsize
    while p < total:
        ctyp, chsize, csize = struct.unpack_from("<HHI", buf, p)
        if ctyp == STRING_POOL:
            strings, _ = _read_string_pool(buf, p)
            break
        p += csize

    out = bytearray(buf[:hsize])
    off = hsize
    skip_depth = 0
    while off < total:
        ctyp, chsize, csize = struct.unpack_from("<HHI", buf, off)
        chunk = bytearray(buf[off:off + csize])
        if skip_depth:
            if ctyp == START_ELEM:
                skip_depth += 1
            elif ctyp == END_ELEM:
                skip_depth -= 1
            off += csize
            continue
        if ctyp == START_ELEM:
            name_i = struct.unpack_from("<i", chunk, 20)[0]
            attr_start, attr_size, attr_count = \
                struct.unpack_from("<HHH", chunk, 24)
            elem_name = _s(strings, name_i)
            attrs_at = 16 + attr_start
            drop_elem = False
            kept_attrs = bytearray()
            kept_count = 0
            ap = attrs_at
            for _ in range(attr_count):
                a_name_i = struct.unpack_from("<i", chunk, ap + 4)[0]
                a_raw = struct.unpack_from("<i", chunk, ap + 8)[0]
                a_tv = struct.unpack_from("<I", chunk, ap + 12)[0]
                a_type = (a_tv >> 24) & 0xff
                a_data = struct.unpack_from("<i", chunk, ap + 16)[0]
                a_name = _s(strings, a_name_i)
                a_val = (_s(strings, a_raw) if a_raw != -1
                         else (_s(strings, a_data) if a_type == TYPE_STRING
                               else None))
                if elem_name == "meta-data" and a_name == "name" \
                        and a_val in _DROP_META_NAMES:
                    drop_elem = True
                if elem_name == "manifest" and a_name in _DROP_MANIFEST_ATTRS:
                    ap += attr_size
                    continue
                kept_attrs += chunk[ap:ap + attr_size]
                kept_count += 1
                ap += attr_size
            if drop_elem:
                skip_depth = 1
                off += csize
                continue
            new_chunk = bytearray(chunk[:attrs_at]) + kept_attrs
            struct.pack_into("<H", new_chunk, 28, kept_count)   # attributeCount
            struct.pack_into("<I", new_chunk, 4, len(new_chunk))  # chunk size
            out += new_chunk
            off += csize
            continue
        out += chunk
        off += csize
    struct.pack_into("<I", out, 4, len(out))
    return bytes(out)


def _string_pool(strings):
    data, offsets = b"", []
    for s in strings:
        offsets.append(len(data))
        u = s.encode("utf-16-le")
        data += struct.pack("<H", len(s)) + u + b"\x00\x00"
    while len(data) % 4:
        data += b"\x00"
    offs = b"".join(struct.pack("<I", o) for o in offsets)
    header_size = 28
    strings_start = header_size + len(offs)
    body = offs + data
    return struct.pack("<HHIIIIII", STRING_POOL, header_size,
                       header_size + len(body), len(strings), 0, 0,
                       strings_start, 0) + body
