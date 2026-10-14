import sys, struct, collections
f=open(sys.argv[1],'rb'); r=lambda fmt: struct.unpack('<'+fmt, f.read(struct.calcsize('<'+fmt)))
def s(): n,=r('Q'); return f.read(n).decode('utf-8','replace')
T={0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',6:'Q5_0',7:'Q5_1',8:'Q8_0',10:'Q2_K',11:'Q3_K',12:'Q4_K',13:'Q5_K',14:'Q6_K',16:'IQ2_XXS',17:'IQ2_XS',18:'IQ3_XXS',19:'IQ1_S',20:'IQ4_NL',21:'IQ3_S',22:'IQ2_S',23:'IQ4_XS',29:'IQ1_M',30:'BF16',39:'MXFP4'}
assert f.read(4)==b'GGUF'; v,=r('I'); nt,nkv=r('QQ')
def val(t):
    sz={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
    if t in sz: return r(sz[t])[0]
    if t==8: return s()
    if t==9:
        at,n=r('IQ'); return [val(at) for _ in range(n)] if n<64 else [val(at) for _ in range(n)] and f'[{n} items]'
for _ in range(nkv):
    k=s(); t,=r('I'); x=val(t)
c=collections.Counter(); NPU={'Q4_0','Q4_1','Q8_0','IQ4_NL','MXFP4','Q4_K','Q5_K','Q6_K','Q3_K','Q2_K','F16','F32'}
bad=collections.Counter()
for _ in range(nt):
    n=s(); nd,=r('I'); dims=r('Q'*nd); t,=r('I'); off,=r('Q')
    tn=T.get(t,str(t)); kind=n.split('.')[-2] if n.startswith('blk.') else n
    c[(kind,tn)]+=1
    if tn not in NPU: bad[(kind,tn)]+=1
print(nt,'tensors'); 
for (k,t),n in sorted(c.items()): print(f'  {k:22s} {t:8s} x{n}')
print('not NPU-matmul types:', dict(bad) or 'none')
