import struct, sys
data = open(sys.argv[1], 'rb').read()
sig, ver, n, rva = struct.unpack_from('<4sIII', data, 0)
streams = {}
for i in range(n):
    t, size, r = struct.unpack_from('<III', data, rva + 12*i)
    streams.setdefault(t, []).append((size, r))
print('streams', sorted(streams))
size, r = streams[6][0]
tid, _ = struct.unpack_from('<II', data, r)
code, flags, rec, addr, nparams, _ = struct.unpack_from('<IIQQII', data, r+8)
info = struct.unpack_from('<15Q', data, r+8+32)
print('tid', tid, 'code %08x' % code, 'addr %x' % addr, 'params', [hex(x) for x in info[:nparams]])
ctx_size, ctx_rva = struct.unpack_from('<II', data, r+8+32+120)
# x64 CONTEXT: registers start at offset 0x78 (Rax)
names = ['Rax','Rcx','Rdx','Rbx','Rsp','Rbp','Rsi','Rdi','R8','R9','R10','R11','R12','R13','R14','R15','Rip']
regs = struct.unpack_from('<17Q', data, ctx_rva + 0x78)
for nme, v in zip(names, regs):
    print(nme, hex(v))
