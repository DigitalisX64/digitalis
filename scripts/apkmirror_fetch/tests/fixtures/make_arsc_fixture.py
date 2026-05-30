"""Build minimal valid resources.arsc blobs for test_arsc (classic layout)."""
import struct


def _enc_len(n):
    return bytes([n]) if n < 0x80 else bytes([0x80 | (n >> 8), n & 0xff])


def _u8_pool(strings):
    blob, offsets = b"", b""
    for s in strings:
        offsets += struct.pack("<I", len(blob))
        b = s.encode("utf-8")
        blob += _enc_len(len(s)) + _enc_len(len(b)) + b + b"\x00"
    while len(blob) % 4:
        blob += b"\x00"
    strings_start = 28 + len(offsets)
    size = 28 + len(offsets) + len(blob)
    flags = 1 << 8  # UTF-8
    head = struct.pack("<HHIIIIII", 0x0001, 28, size, len(strings), 0, flags,
                       strings_start, 0)
    return head + offsets + blob


def _typespec(type_id, entry_count):
    head = struct.pack("<HHI", 0x0202, 16, 16 + 4 * entry_count)
    head += struct.pack("<BBH", type_id, 0, 0)
    head += struct.pack("<I", entry_count)
    return head + struct.pack("<I", 0) * entry_count


def _type_chunk(type_id, density, key_index, value_str_index):
    config = struct.pack("<I", 28)
    config += struct.pack("<HH", 0, 0)           # mcc, mnc
    config += b"\x00\x00\x00\x00"                 # language, country
    config += struct.pack("<BBH", 0, 0, density)  # orientation, touchscreen, density
    config += b"\x00\x00\x00\x00"                 # keyboard, nav, inputFlags, pad
    config += struct.pack("<HH", 0, 0)           # screenWidth, screenHeight
    config += struct.pack("<HH", 0, 0)           # sdkVersion, minorVersion
    assert len(config) == 28
    header_size = 8 + 4 + 4 + 4 + len(config)    # = 48
    offset_array = struct.pack("<I", 0)
    entries_start = header_size + len(offset_array)
    entry = struct.pack("<HHI", 8, 0, key_index)
    entry += struct.pack("<HBBI", 8, 0, 3, value_str_index)  # Res_value TYPE_STRING
    body = offset_array + entry
    head = struct.pack("<HHI", 0x0201, header_size, header_size + len(body))
    head += struct.pack("<BBH", type_id, 0, 0)
    head += struct.pack("<I", 1)                  # entryCount
    head += struct.pack("<I", entries_start)
    head += config
    return head + body


def _package(type_pool, key_pool, children):
    name = ("x".encode("utf-16-le") + b"\x00" * 256)[:256]
    header_size = 288
    type_strings = header_size
    key_strings = header_size + len(type_pool)
    head = bytearray(struct.pack("<HHI", 0x0200, header_size, 0))
    head += struct.pack("<I", 0x7f)               # package id
    head += name
    head += struct.pack("<I", type_strings)
    head += struct.pack("<I", 0)                  # lastPublicType
    head += struct.pack("<I", key_strings)
    head += struct.pack("<I", 0)                  # lastPublicKey
    head += struct.pack("<I", 0)                  # typeIdOffset
    assert len(head) == 288
    body = type_pool + key_pool + b"".join(children)
    struct.pack_into("<I", head, 4, header_size + len(body))
    return bytes(head) + body


def _table(global_pool, package):
    head = bytearray(struct.pack("<HHI", 0x0002, 12, 0))
    head += struct.pack("<I", 1)                  # packageCount
    body = global_pool + package
    struct.pack_into("<I", head, 4, 12 + len(body))
    return bytes(head) + body


def build_base():
    global_pool = _u8_pool(["res/drawable/img.png"])
    type_pool = _u8_pool(["drawable"])
    key_pool = _u8_pool(["img"])
    children = [_typespec(1, 1), _type_chunk(1, 0, 0, 0)]
    return _table(global_pool, _package(type_pool, key_pool, children))


def build_density_split():
    global_pool = _u8_pool(["res/drawable-xxhdpi/img.png"])
    type_pool = _u8_pool(["drawable"])
    key_pool = _u8_pool(["img"])
    children = [_typespec(1, 1), _type_chunk(1, 480, 0, 0)]
    return _table(global_pool, _package(type_pool, key_pool, children))
