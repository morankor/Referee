import json, sys
sys.path.insert(0, sys.argv[1])
import text_and_citations as proto2
for path in sys.argv[2:]:
    raw = json.load(open(path))
    pages, mode = proto2.build(raw)
    c = proto2.citations(raw, pages)
    name = path.split('/')[-1]
    if not c: print(name, 'no list'); continue
    t = [(m['page'], tuple(m['entries'])) for m in c['text_mentions']]
    l = [(m['page'], (m['entry'],)) for m in c['link_mentions']]
    # per page multiset comparison and in-order comparison
    same_order = t == l
    from collections import Counter
    print(name, 'entries', len(c['entries']), 'text', len(t), 'link', len(l), 'identical sequences:', same_order, 'same multiset:', Counter(t) == Counter(l))
    if not same_order and l:
        for i, (a, b) in enumerate(zip(t, l)):
            if a != b: print('   first difference at', i, a, b, repr(c['text_mentions'][i]['text']), repr(c['link_mentions'][i]['text'])); break
