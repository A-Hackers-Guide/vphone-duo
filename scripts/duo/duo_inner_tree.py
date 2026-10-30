# duo_inner_tree.py SRC DST: put the inner panel first in an iPhone Duo guest's device tree (IMG4).
# Swaps the contents of /product/display0 and display1; each keeps its name, AAPL,phandle and display-index.
import struct, sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()

def hdr(b, i):
    t = b[i]; i += 1; l = b[i]; i += 1
    if l & 0x80:
        n = l & 0x7f; l = int.from_bytes(b[i:i + n], "big"); i += n
    return t, i, l

def enc(tag, body):
    n = len(body)
    if n < 0x80:
        L = bytes([n])
    else:
        x = n.to_bytes((n.bit_length() + 7) // 8, "big"); L = bytes([0x80 | len(x)]) + x
    return bytes([tag]) + L + body

t, i0, l0 = hdr(raw, 0); body = raw[i0:i0 + l0]
t, j, l = hdr(body, 0); img4tag = body[:j + l]; rest = body[j + l:]
t, k, lp = hdr(rest, 0); im4p = rest[k:k + lp]; after = rest[k + lp:]
fields = []; p = 0
while p < len(im4p):
    t, q, l = hdr(im4p, p); fields.append((t, im4p[q:q + l])); p = q + l
idx = [n for n, (t, _) in enumerate(fields) if t == 4][0]
blob = fields[idx][1]

def key(prop):
    return prop[0].split(b"\0")[0]

def node(o, path):
    np_, nc = struct.unpack_from("<II", blob, o); o += 8; props = []
    for _ in range(np_):
        name = blob[o:o + 32]; ln, fl = struct.unpack_from("<HH", blob, o + 32)
        props.append((name, ln, fl, blob[o + 36:o + 36 + ln])); o += 36 + ((ln + 3) & ~3)
    nm = dict((key(pp), pp[3]) for pp in props).get(b"name", b"").split(b"\0")[0].decode()
    me = path + "/" + nm; kids = []
    for _ in range(nc):
        o, c = node(o, me); kids.append(c)
    return o, [me, props, kids]

end, root = node(0, ""); assert end == len(blob)
found = {}
def find(n):
    if n[0] in ("/device-tree/product/display0", "/device-tree/product/display1"):
        found[n[0][-1]] = n
    for c in n[2]: find(c)
find(root)
assert set(found) == {"0", "1"}, "both panel nodes must be present"
keep = (b"name", b"AAPL,phandle", b"display-index")
a, b = found["0"], found["1"]
def swapped(mine, other):
    own = {key(pp): pp for pp in mine[1] if key(pp) in keep}
    return [own.get(key(pp), pp) for pp in other[1] if key(pp) not in keep or key(pp) in own] + \
        [pp for k2, pp in own.items() if k2 not in {key(x) for x in other[1]}]
a[1], b[1] = swapped(a, b), swapped(b, a)

def ser(n):
    _, props, kids = n
    out = struct.pack("<II", len(props), len(kids))
    for name, ln, fl, val in props:
        out += name + struct.pack("<HH", ln, fl) + val + b"\0" * ((4 - ln % 4) % 4)
    for c in kids: out += ser(c)
    return out

nb = ser(root)
fields[idx] = (4, nb)
im4p2 = b"".join(enc(t, v) for t, v in fields)
open(dst, "wb").write(enc(0x30, img4tag + enc(0x30, im4p2) + after))
print("payload", len(blob), "->", len(nb))
