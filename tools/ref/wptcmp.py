#!/usr/bin/env python3
"""wptcmp.py - what changed between two wptrun results.txt files.

    tools/ref/wptcmp.py before/results.txt after/results.txt

Prints the counts, then every test that stopped passing (regressions
first: those need looking at before anything is committed), then how
many started passing.
"""
import sys

def load(p):
    r = {}
    for l in open(p):
        st, path = l.split(' ', 2)[:2]
        r[path] = st
    return r

a, b = load(sys.argv[1]), load(sys.argv[2])
pa = sum(1 for s in a.values() if s == 'PASS')
pb = sum(1 for s in b.values() if s == 'PASS')
lost = sorted(t for t in a if a[t] == 'PASS' and b.get(t, 'MISSING') != 'PASS')
won = sorted(t for t in b if b[t] == 'PASS' and a.get(t) != 'PASS')
print('pass %d -> %d (%+d): %d newly passing, %d regressions' % (pa, pb, pb - pa, len(won), len(lost)))
for t in lost:
    print('REGRESSION', b.get(t, 'MISSING'), t)
