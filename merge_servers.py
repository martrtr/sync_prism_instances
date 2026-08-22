#!/usr/bin/env python3
import gzip
import io
import os
import struct
import sys

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10
TAG_INT_ARRAY = 11
TAG_LONG_ARRAY = 12

class NBTError(Exception):
    pass

def mutf8_decode(data):
    units = []
    i = 0
    while i < len(data):
        b0 = data[i]
        if b0 & 0x80 == 0:
            # В Java modified UTF-8 U+0000 должен быть C0 80, но принимаем и 00.
            units.append(b0)
            i += 1
        elif b0 & 0xE0 == 0xC0:
            if i + 1 >= len(data):
                raise NBTError("обрезанная modified UTF-8 строка")
            b1 = data[i + 1]
            if b1 & 0xC0 != 0x80:
                raise NBTError("некорректная modified UTF-8 строка")
            units.append(((b0 & 0x1F) << 6) | (b1 & 0x3F))
            i += 2
        elif b0 & 0xF0 == 0xE0:
            if i + 2 >= len(data):
                raise NBTError("обрезанная modified UTF-8 строка")
            b1, b2 = data[i + 1], data[i + 2]
            if b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80:
                raise NBTError("некорректная modified UTF-8 строка")
            units.append(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F))
            i += 3
        else:
            raise NBTError("4-байтная UTF-8 последовательность недопустима в modified UTF-8")

    raw = bytearray()
    for unit in units:
        raw.extend(struct.pack(">H", unit))
    return bytes(raw).decode("utf-16-be", errors="surrogatepass")

def mutf8_encode(value):
    raw = value.encode("utf-16-be", errors="surrogatepass")
    out = bytearray()
    for i in range(0, len(raw), 2):
        unit = (raw[i] << 8) | raw[i + 1]
        if 0x0001 <= unit <= 0x007F:
            out.append(unit)
        elif unit <= 0x07FF:
            out.extend((0xC0 | (unit >> 6), 0x80 | (unit & 0x3F)))
        else:
            out.extend((
                0xE0 | (unit >> 12),
                0x80 | ((unit >> 6) & 0x3F),
                0x80 | (unit & 0x3F),
            ))
    return bytes(out)

class Reader:
    def __init__(self, data):
        self.f = io.BytesIO(data)

    def read(self, n):
        value = self.f.read(n)
        if len(value) != n:
            raise NBTError("неожиданный конец NBT")
        return value

    def unpack(self, fmt):
        size = struct.calcsize(fmt)
        return struct.unpack(fmt, self.read(size))[0]

    def string(self):
        length = self.unpack(">H")
        return mutf8_decode(self.read(length))

    def payload(self, tag):
        if tag == TAG_BYTE:
            return self.unpack(">b")
        if tag == TAG_SHORT:
            return self.unpack(">h")
        if tag == TAG_INT:
            return self.unpack(">i")
        if tag == TAG_LONG:
            return self.unpack(">q")
        if tag == TAG_FLOAT:
            return self.unpack(">f")
        if tag == TAG_DOUBLE:
            return self.unpack(">d")
        if tag == TAG_BYTE_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина byte array")
            return self.read(n)
        if tag == TAG_STRING:
            return self.string()
        if tag == TAG_LIST:
            child = self.unpack(">B")
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина list")
            return (child, [self.payload(child) for _ in range(n)])
        if tag == TAG_COMPOUND:
            out = {}
            while True:
                child = self.unpack(">B")
                if child == TAG_END:
                    break
                name = self.string()
                out[name] = (child, self.payload(child))
            return out
        if tag == TAG_INT_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина int array")
            return [self.unpack(">i") for _ in range(n)]
        if tag == TAG_LONG_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина long array")
            return [self.unpack(">q") for _ in range(n)]
        raise NBTError(f"неизвестный NBT tag: {tag}")

class Writer:
    def __init__(self):
        self.f = io.BytesIO()

    def write(self, data):
        self.f.write(data)

    def pack(self, fmt, value):
        self.write(struct.pack(fmt, value))

    def string(self, value):
        data = mutf8_encode(value)
        if len(data) > 65535:
            raise NBTError("слишком длинная NBT строка")
        self.pack(">H", len(data))
        self.write(data)

    def payload(self, tag, value):
        if tag == TAG_BYTE:
            self.pack(">b", value)
        elif tag == TAG_SHORT:
            self.pack(">h", value)
        elif tag == TAG_INT:
            self.pack(">i", value)
        elif tag == TAG_LONG:
            self.pack(">q", value)
        elif tag == TAG_FLOAT:
            self.pack(">f", value)
        elif tag == TAG_DOUBLE:
            self.pack(">d", value)
        elif tag == TAG_BYTE_ARRAY:
            self.pack(">i", len(value))
            self.write(value)
        elif tag == TAG_STRING:
            self.string(value)
        elif tag == TAG_LIST:
            child, values = value
            self.pack(">B", child)
            self.pack(">i", len(values))
            for entry in values:
                self.payload(child, entry)
        elif tag == TAG_COMPOUND:
            for name, (child, entry) in value.items():
                self.pack(">B", child)
                self.string(name)
                self.payload(child, entry)
            self.pack(">B", TAG_END)
        elif tag == TAG_INT_ARRAY:
            self.pack(">i", len(value))
            for entry in value:
                self.pack(">i", entry)
        elif tag == TAG_LONG_ARRAY:
            self.pack(">i", len(value))
            for entry in value:
                self.pack(">q", entry)
        else:
            raise NBTError(f"неизвестный NBT tag: {tag}")

    def value(self):
        return self.f.getvalue()

def load(path):
    if not path or not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None
    raw = open(path, "rb").read()
    compressed = raw.startswith(b"\x1f\x8b")
    if compressed:
        raw = gzip.decompress(raw)
    reader = Reader(raw)
    root_type = reader.unpack(">B")
    if root_type != TAG_COMPOUND:
        raise NBTError(f"корневой tag servers.dat должен быть compound, получен {root_type}")
    root_name = reader.string()
    root = reader.payload(TAG_COMPOUND)
    if reader.f.read(1):
        raise NBTError("лишние данные после корневого NBT")
    return root_name, root, compressed

def dump(document):
    root_name, root, compressed = document
    writer = Writer()
    writer.pack(">B", TAG_COMPOUND)
    writer.string(root_name)
    writer.payload(TAG_COMPOUND, root)
    raw = writer.value()
    return gzip.compress(raw) if compressed else raw

def string_tag(compound, key):
    value = compound.get(key)
    if not value or value[0] != TAG_STRING:
        return ""
    return value[1]

def server_key(compound):
    ip = string_tag(compound, "ip").strip().casefold()
    if ip:
        return ("ip", ip)
    name = string_tag(compound, "name").strip().casefold()
    if name:
        return ("name", name)
    # Не выкидываем даже необычные записи без ip/name.
    return ("raw", repr(compound))

def server_list(root):
    entry = root.get("servers")
    if entry is None:
        return []
    if entry[0] != TAG_LIST or entry[1][0] != TAG_COMPOUND:
        raise NBTError("tag 'servers' имеет неожиданный тип")
    return entry[1][1]

def merge(shared_doc, local_doc):
    if shared_doc is None and local_doc is None:
        # Валидный пустой servers.dat.
        return "", {"servers": (TAG_LIST, (TAG_COMPOUND, []))}, False
    if shared_doc is None:
        return local_doc
    if local_doc is None:
        return shared_doc

    shared_name, shared_root, shared_gzip = shared_doc
    _, local_root, _ = local_doc

    merged = list(server_list(shared_root))
    seen = {server_key(server) for server in merged}
    for server in server_list(local_root):
        key = server_key(server)
        if key not in seen:
            merged.append(server)
            seen.add(key)

    # Сохраняем остальные root-теги общего файла и только обновляем servers.
    shared_root = dict(shared_root)
    shared_root["servers"] = (TAG_LIST, (TAG_COMPOUND, merged))
    return shared_name, shared_root, shared_gzip

shared_path, local_path, output_path = sys.argv[1:4]
try:
    document = merge(load(shared_path), load(local_path))
    data = dump(document)
    with open(output_path, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
except Exception as exc:
    print(f"Не удалось объединить servers.dat: {exc}", file=sys.stderr)
    sys.exit(1)
