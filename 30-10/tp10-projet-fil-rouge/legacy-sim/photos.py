import random, struct, sys, zlib, os

def png(path, rgb, size=48):
    raw = b''.join(b'\x00' + bytes(rgb) * size for _ in range(size))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(data)

out, names = sys.argv[1], sys.argv[2:]
os.makedirs(out, exist_ok=True)
random.seed(2017)
for n in names:
    png(os.path.join(out, n), [random.randrange(256) for _ in range(3)])
