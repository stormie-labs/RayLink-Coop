import struct, sys
data = open(sys.argv[1], 'rb').read()
rva = int(sys.argv[2], 16)
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe+6)[0]
optsz = struct.unpack_from('<H', data, pe+20)[0]
sec = pe + 24 + optsz
for i in range(nsec):
    name, vsize, va, rawsize, rawptr = struct.unpack_from('<8sIIII', data, sec + 40*i)
    if va <= rva < va + vsize:
        off = rawptr + (rva - va)
        print(name, 'bytes before/at:', data[off-24:off].hex(' '), '|', data[off:off+16].hex(' '))
