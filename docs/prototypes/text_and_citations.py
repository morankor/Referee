"""Prototype of plan sections 7.2 (cleaning), 6.2 (rendering), 6.7 (matching, labels) and 8.2-8.5 (citations).
Input: RawDocument JSON as printed by probe5/rawdump (the Appendix A.2 shape). Pure Python, no PDF library."""
import json, re, sys, unicodedata, statistics

# ---------------------------------------------------------------- folding (6.7)
def fold_char(ch):
    out = []
    for c in unicodedata.normalize('NFKD', ch):
        if c == 'µ': c = 'μ'
        cat = unicodedata.category(c)
        if cat[0] in 'LN':
            out.append(c.lower())
    return ''.join(out)

def fold(s): return ''.join(fold_char(c) for c in s)
def u16(s): return len(s.encode('utf-16-le')) // 2

# ---------------------------------------------------------------- 7.2 step 1: margin numbers
def chains_for_page(lines, mode):
    best = {}; back = {}
    nonempty = [i for i, l in enumerate(lines) if l['text'].strip()]
    for i in nonempty:
        t = lines[i]['text'].rstrip() if mode == 'trailing' else lines[i]['text'].lstrip()
        if mode == 'trailing':
            m = re.search(r'(\d+)$', t)
            if not m: continue
            run = m.group(1)
            cands = [(int(run[-k:]), k) for k in range(1, min(4, len(run)) + 1) if run[-k] != '0']
        else:
            m = re.match(r'(\d{1,4})(?=[\sA-Za-z]|$)', t)
            if not m or m.group(1)[0] == '0': continue
            cands = [(int(m.group(1)), len(m.group(1)))]
        upd = {}
        for v, k in cands:
            prev = best.get(v - 1)
            ln = prev[0] + 1 if prev else 1
            if v not in best or best[v][0] < ln:
                upd[v] = (ln, i, k, (v - 1) if prev else None)
        for v, val in upd.items():
            best[v] = val; back[(v, i)] = val
    if not best: return {}, len(nonempty)
    vend = max(best, key=lambda v: best[v][0])
    if best[vend][0] < max(5, 0.4 * len(nonempty)): return {}, len(nonempty)
    chain = {}; v = vend; cur = best[v]
    while True:
        chain[cur[1]] = (v, cur[2])
        if cur[3] is None: break
        v = cur[3]
        cur = max([val for (vv, ii), val in back.items() if vv == v and ii < cur[1]], key=lambda x: x[0])
    return chain, len(nonempty)

def detect_margin(pages):
    res = {}
    for mode in ('trailing', 'leading'):
        per = {}; qual = 0; elig = 0; total = 0
        for pg in pages:
            chain, n = chains_for_page(pg['lines'], mode)
            if n >= 10: elig += 1
            if chain:
                per[pg['index']] = chain; total += len(chain)
                if n >= 10: qual += 1
        res[mode] = (per, qual, elig, total)
    ok = {m: r for m, r in res.items() if r[2] > 0 and r[1] >= 0.5 * r[2]}
    if not ok: return None, {}
    mode = max(ok, key=lambda m: ok[m][3])
    return mode, ok[mode][0]

WATERMARK = re.compile(r'^(for peer review( only)?|confidential|manuscript (id|number)\b.*|click here to (download|view|access).*|powered by editorial manager.*|.*scholarone.*|electronic copy available at.*)$', re.I)
PAGENUM = re.compile(r'^(page\s+)?(\d{1,4})(\s+of\s+\d{1,4})?$|^[-–—]\s*(\d{1,4})\s*[-–—]$', re.I)

def build(raw, strip=True):
    """returns pages: list of dict(index, string, size, lines=[dict(range, content(start,len), text, kind, margin, bounds)])"""
    pages = raw['pages']
    mode, per = detect_margin(pages) if strip else (None, {})
    out = []
    for pg in pages:
        chain = per.get(pg['index'], {})
        lines = []
        for i, l in enumerate(pg['lines']):
            text = l['text']; loc = l['range']['location']; ln = l['range']['length']
            cstart, cend = 0, len(text); num = None
            if i in chain:
                num, k = chain[i]
                if mode == 'trailing':
                    cend = len(text.rstrip()) - k
                    cend = len(text[:cend].rstrip())
                else:
                    lead = len(text) - len(text.lstrip())
                    cstart = lead + k
                    cstart += len(text[cstart:]) - len(text[cstart:].lstrip())
            content = text[cstart:cend]
            kind = 'body'
            if not content.strip():
                kind = 'marginNumberOnly' if num is not None else 'empty'
            bnd = l.get('bounds')
            if num is not None and kind == 'body' and mode == 'trailing' and l.get('protoBoundsNoTrailingDigits'): bnd = l['protoBoundsNoTrailingDigits']   # emulates PDFPaperService
            lines.append(dict(idx=i, loc=loc, len=ln, cloc=loc + u16(text[:cstart]), clen=u16(content), text=content, raw=text, kind=kind,
                              margin=num, glued=(num is not None and kind == 'body'), b=bnd))
        out.append(dict(index=pg['index'], string=pg['string'], size=pg['size'], lines=lines))
    # nearest standalone number for body lines without one
    for pg in out:
        nums = [l for l in pg['lines'] if l['kind'] == 'marginNumberOnly' and l['b']]
        if not nums: continue
        cs = sorted(l['b']['y'] + l['b']['height'] / 2 for l in nums)
        steps = [b - a for a, b in zip(cs, cs[1:])]
        step = statistics.median(steps) if len(steps) >= 2 else None
        for l in pg['lines']:
            if l['kind'] != 'body' or l['margin'] is not None or not l['b']: continue
            c = l['b']['y'] + l['b']['height'] / 2
            n = min(nums, key=lambda x: abs(x['b']['y'] + x['b']['height'] / 2 - c))
            d = abs(n['b']['y'] + n['b']['height'] / 2 - c)
            tol = max(0.75 * l['b']['height'], 0.55 * step if step else 0)
            if d <= tol: l['margin'] = n['margin']; l['nearest'] = True
    # watermark patterns, page numbers, repeated lines
    npages = len(out)
    norm_count = {}
    def norm(t): return re.sub(r'\s+', ' ', re.sub(r'\d', '#', t.lower())).strip()
    for pg in out:
        seen = set()
        for l in pg['lines']:
            if l['kind'] == 'body':
                n = norm(l['text'])
                if n not in seen: seen.add(n); norm_count[n] = norm_count.get(n, 0) + 1
    prev_num = None
    for pg in out:
        H = pg['size']['height']
        body = [l for l in pg['lines'] if l['kind'] == 'body']
        for l in body:
            if WATERMARK.match(l['text'].strip()): l['kind'] = 'watermark'
        body = [l for l in pg['lines'] if l['kind'] == 'body']
        # page number: first or last body line, or any "Page N of M" line
        found = None
        for l in ([body[0], body[-1]] if body else []):
            m = PAGENUM.match(l['text'].strip())
            if m:
                n = int(m.group(2) or m.group(4))
                if prev_num is None or n == prev_num + 1: l['kind'] = 'pageNumber'; found = n
        for l in body:
            if l['kind'] == 'body' and re.match(r'^page\s+\d{1,4}\s+of\s+\d{1,4}$', l['text'].strip(), re.I): l['kind'] = 'pageNumber'
        if found is not None: prev_num = found
        if npages >= 3:
            for l in pg['lines']:
                if l['kind'] != 'body': continue
                if norm_count.get(norm(l['text']), 0) >= max(3, 0.6 * npages):
                    if l['b']:
                        cy = l['b']['y'] + l['b']['height'] / 2
                        l['kind'] = 'runningHeader' if cy >= 0.85 * H else ('runningFooter' if cy <= 0.15 * H else 'watermark')
                    else:
                        l['kind'] = 'watermark'
    return out, mode

# ---------------------------------------------------------------- 6.7 matcher (exact only) + label
def stream(pages):
    S = []; M = []
    for pg in pages:
        for li, l in enumerate(pg['lines']):
            if l['kind'] != 'body': continue
            off = l['cloc']
            for ch in l['text']:
                f = fold_char(ch)
                for c in f: S.append(c); M.append((pg['index'], off, li))
                off += u16(ch)
    return ''.join(S), M

def locate(quote, S, M):
    q = fold(quote)
    i = S.find(q)
    if i < 0 or len(q) < 12: return None
    lines = []
    for k in range(i, i + len(q)):
        key = (M[k][0], M[k][2])
        if not lines or lines[-1] != key: lines.append(key)
    return lines

def label(pages, linekeys):
    p = linekeys[0][0]
    nums = [pages[pi]['lines'][li]['margin'] for pi, li in linekeys]
    nums = [n for n in nums if n is not None]
    s = 'p. %d' % (p + 1)
    if nums:
        a, b = nums[0], nums[-1]
        s += ', line %d' % a if a == b else ', lines %d–%d' % (a, b)
    return s

# ---------------------------------------------------------------- 6.2 rendering (reflow)
def render(pages):
    """6.2: one output line per paragraph-like run. A body line is joined to the next one when it is 'full'
    (at least 0.75 x the median length of the page's body lines of 25+ characters). Short lines (headings, table rows,
    equation fragments, last lines of paragraphs and of reference entries) end a run. The page marker goes on its own line
    before the first run that starts on the page; a run crossing the page break is cut at the first sentence end after the break."""
    out = []                      # output lines
    run = None                    # current run text
    pending_marker = None         # marker waiting for the crossing run to reach a sentence end
    crossed_at = None             # length of run when the page break happened
    def flush():
        nonlocal run, pending_marker, crossed_at
        if run is not None:
            if pending_marker is not None:
                tail = run[crossed_at:]
                m = re.search(r'[.?!]["\')\]”’]*\s+(?=[A-Z\[(])', tail[:400])
                if m:
                    out.append(run[:crossed_at + m.end()].rstrip()); out.append(pending_marker)
                    rest = run[crossed_at + m.end():].strip()
                    if rest: out.append(rest)
                else:
                    out.append(run); out.append(pending_marker)
                pending_marker = None; crossed_at = None
            else:
                out.append(run)
            run = None
    def add(text):
        nonlocal run
        if run is None: run = text
        elif len(run) > 1 and run.endswith('-') and run[-2].isalpha() and text[:1].islower(): run = run[:-1] + text
        else: run = run + ' ' + text
    prev_full = False
    for pg in pages:
        marker = '[[page %d]]' % (pg['index'] + 1)
        body = [l for l in pg['lines'] if l['kind'] == 'body' and l['text'].strip()]
        longs = sorted(len(l['text'].strip()) for l in body if len(l['text'].strip()) >= 25)
        med = statistics.median(longs) if len(longs) >= 5 else None
        pitches = [a['b']['y'] - b['b']['y'] for a, b in zip(body, body[1:]) if a['b'] and b['b'] and a['b']['y'] - b['b']['y'] > 0]
        pitch = statistics.median(pitches) if pitches else None
        if run is not None and prev_full and body:
            pending_marker = marker; crossed_at = len(run)       # the run continues across the page break
        else:
            flush(); out.append(marker)
        prev = None
        for l in body:
            t = l['text'].strip()
            far = prev is not None and pitch is not None and prev['b'] and l['b'] and not (0 < prev['b']['y'] - l['b']['y'] <= 1.3 * pitch)
            if run is not None and (not prev_full or far): flush()
            add(t)
            prev_full = med is not None and len(t) >= 0.75 * med
            prev = l
    flush()
    return '\n'.join(out) + '\n'

# ---------------------------------------------------------------- 8: citations
YEAR = re.compile(r'(?<!\d)((?:1[89]|20)\d{2})([a-z]?)(?![\d])')
HEADING = re.compile(r'^\s*(\d+\.?\s+)?(references|bibliography|works cited|literature cited|reference list)\s*\d{0,4}\s*$', re.I)
END_KEY = re.compile(r'^(online |web |internet )?(appendix|appendices|supplementa(ry|l)\b.*|tables?|figures?|footnotes|endnotes)\b', re.I)
END_LETTER = re.compile(r'^[A-Z](\.\d+)?\.?\s+[A-Z]')
PARTICLES = {'van', 'von', 'de', 'del', 'della', 'di', 'da', 'la', 'le', 'ten', 'ter', 'der', 'den'}

def body_lines(pages):
    return [(pg['index'], li, l) for pg in pages for li, l in enumerate(pg['lines']) if l['kind'] == 'body']

NUM_START = re.compile(r'^\s*(?:\[(\d{1,3})\]|(\d{1,3})\.)(\s|$)')
STATUS = re.compile(r'\b(forthcoming|in press|n\.d\.|working paper|mimeo|unpublished|manuscript)\b', re.I)

def find_list(pages):
    """8.2: heading, style, entries and end of the list in one pass. Returns (heading, style, entries, list_lines) or None."""
    bl = body_lines(pages)
    heads = [k for k, (_, _, l) in enumerate(bl) if HEADING.match(l['text'])]
    if not heads: return None
    h = heads[-1]
    rest = bl[h + 1:]
    if not rest: return None
    first10 = [NUM_START.match(l['text']) for (_, _, l) in rest[:10]]
    numeric = bool(first10[0]) or sum(1 for m in first10 if m) >= 3
    style = 'numeric' if numeric else 'authorYear'
    # hanging indent: x0 per page = 10th percentile of line x; a start is a line with x <= x0 + 2
    xs = {}
    for (pi, _, l) in rest:
        if l['b']: xs.setdefault(pi, []).append(l['b']['x'])
    x0 = {pi: sorted(v)[int(0.1 * (len(v) - 1))] for pi, v in xs.items()}
    def is_left(pi, l): return l['b'] is not None and l['b']['x'] <= x0[pi] + 2
    probe = rest[:40]
    indented = sum(1 for (pi, _, l) in probe if l['b'] and not is_left(pi, l))
    hanging = indented >= 0.2 * len(probe)
    starts = []; end = len(rest); nxt = 1; heights = []
    def entry_like(k):
        """does the candidate starting at line k look like a reference entry? (uses its own line and up to two following lines)"""
        look = ' '.join(x[2]['text'] for x in rest[k:k + 3])[:240]
        return bool(YEAR.search(look) or STATUS.search(look))
    k = 0
    while k < len(rest):
        pi, li, l = rest[k]
        t = l['text'].strip()
        hgt = l['b']['height'] if l['b'] else None
        med = statistics.median(heights) if heights else None
        # (b) column jump back
        left_of_list = [x[2]['b']['x'] for x in rest[:k] if x[0] == pi and x[2]['b']]
        if len(starts) >= 3 and l['b'] and left_of_list and l['b']['x'] < min(left_of_list) - 40: end = k; break
        m = NUM_START.match(l['text']) if numeric else None
        is_start = False
        if numeric:
            if m and int(m.group(1) or m.group(2)) == nxt: is_start = True
        elif hanging:
            is_start = is_left(pi, l)
        else:
            prev = rest[k - 1][2]['text'].rstrip() if k else '.'
            is_start = bool((k == 0 or re.search(r'[.)\d]$|https?://\S+$', prev)) and re.match(r'^[A-Z]', t) and entry_like(k))
        # (a) heading: keyword, or a short line set taller than the list
        if len(starts) >= 3 and len(t) <= 60 and not (numeric and is_start):
            taller = hgt is not None and med is not None and hgt >= 1.15 * med
            keyword = bool(END_KEY.match(t)) and not YEAR.search(t) and ',' not in t
            if (taller and (keyword or END_LETTER.match(t) or not entry_like(k))) or (keyword and (hgt is None or med is None or is_left(pi, l) or not hanging)):
                end = k; break
        # (c) hanging-indent lists: two consecutive lines at the left edge that are not entries end the list
        if len(starts) >= 3 and hanging and is_left(pi, l) and not (is_start and (numeric or entry_like(k))):
            nxt_line = rest[k + 1] if k + 1 < len(rest) else None
            if nxt_line is None or (is_left(nxt_line[0], nxt_line[2]) and not (NUM_START.match(nxt_line[2]['text']) if numeric else entry_like(k + 1))):
                end = k; break
            is_start = False if numeric else is_start
        if is_start:
            starts.append(k)
            if numeric: nxt += 1
        if hgt: heights.append(hgt)
        k += 1
    lst = rest[:end]
    starts = [x for x in starts if x < end]
    if len(starts) < 3: return None
    entries = []
    for a_, b_ in zip(starts, starts[1:] + [len(lst)]):
        chunk = lst[a_:b_]
        flow = ''
        for (_, _, l) in chunk:
            t = l['text'].strip()
            last = flow.split()[-1] if flow.split() else ''
            if flow.endswith('-') and t[:1].islower(): flow = flow[:-1] + t
            elif ('://' in last or re.match(r'^(doi:)?10\.\d{4,9}/', last, re.I)) and last[-1] in '/-_.=&': flow = flow + t
            else: flow = (flow + ' ' + t).strip()
        m = NUM_START.match(flow) if numeric else None
        entries.append(dict(id=len(entries), raw=flow, lines=chunk, label=(m.group(1) or m.group(2)) if m else None))
    return bl[h], style, entries, lst

def surname_of(piece):
    p = piece.strip().strip('.').strip()
    if not p: return None
    if re.fullmatch(r'(?:[A-Z]\.?[\s\-]*){1,4}', p): return None                      # initials only
    m = re.fullmatch(r'((?:[a-z]+\s+)*[A-Z][^\sA-Z]+(?:[A-Z][^\sA-Z]+)*)\s*((?:[A-Z]\.?\s?){1,3})', p)   # "Dekel E", "DekelE", "Lee J."
    if m and len(m.group(2).replace('.', '').replace(' ', '')) <= 3 and not re.search(r'\s[A-Z][a-z]', m.group(1)): return m.group(1).strip()
    words = p.split()
    last = words[-1]
    k = len(words) - 1
    while k > 0 and words[k - 1].lower() in PARTICLES: k -= 1; last = words[k] + ' ' + last
    return last

def parse_entry(e, style):
    raw = e['raw']
    body = re.sub(r'^\s*(\[\d{1,3}\]|\d{1,3}\.)\s*', '', raw)
    masked = re.sub(r'https?://\S+|10\.\d{4,9}/\S+|arXiv:\s*\S+', lambda m: ' ' * len(m.group(0)), body, flags=re.I)
    years = [y for y in YEAR.finditer(masked)
             if not re.search(r'\d\s*[-\u2013]\s*$', masked[:y.start()]) and not re.match(r'\s*[-\u2013]\s*\d|\(', masked[y.end():])]
    e['year'] = None; e['suffix'] = ''
    if years:
        y = years[0] if style == 'authorYear' else years[-1]
        e['year'] = int(y.group(1)); e['suffix'] = y.group(2)
    if style == 'authorYear' and years:
        auth = body[:years[0].start()].rstrip(' (,.[')
    else:
        m = re.search(r'(?<=[a-z”"])\.\s', body)
        auth = body[:m.start()] if m else body
    auth = re.sub(r'\bet al\.?.*$', '', auth)
    pieces = re.split(r',|;|\s+and\s+|\s*&\s*', auth)
    e['surnames'] = [s for s in (surname_of(p) for p in pieces) if s]
    m = re.search(r'10\.\d{4,9}/[^\s"<>]+', raw)
    e['doi'] = m.group(0).rstrip('.,;)').lower() if m else None
    m = re.search(r'arXiv:\s*(\d{4}\.\d{4,5})', raw, re.I)
    e['arxiv'] = m.group(1) if m else None
    return e

def author_keys(e):
    s = [fold(x) for x in e['surnames']]
    if not s: return []
    keys = set()
    firsts = {s[0]}
    words = e['surnames'][0].split()
    if len(words) > 1: firsts.add(fold(words[-1]))        # without the particle
    for f in firsts:
        if len(s) == 1: keys.add(f)
        elif len(s) == 2: keys.update({f + 'and' + s[1], f + s[1]})
        else: keys.update({f + 'etal', f + ''.join(s[1:-1]) + 'and' + s[-1], f + ''.join(s[1:])})
    return sorted(keys, key=len, reverse=True)

def text_mentions(pages, entries, style, list_keys):
    """bibliography-driven: for each year in the body text, does the folded text to its left end with an author key of an entry of that year?"""
    mentions = []
    # flow per document: body lines outside the list, raw chars with (page, offset, line)
    chars = []
    for pg in pages:
        for li, l in enumerate(pg['lines']):
            if l['kind'] != 'body' or (pg['index'], li) in list_keys: continue
            off = l['cloc']; t = l['text']
            for ch in t:
                chars.append((ch, pg['index'], off, li)); off += u16(ch)
            chars.append(('\n', pg['index'], off, li))
    text = ''.join(c[0] for c in chars)
    if style == 'numeric':
        n = len(entries)
        for m in re.finditer(r'\[(\d{1,3}(?:\s*[-–]\s*\d{1,3})?(?:\s*[,;]\s*\d{1,3}(?:\s*[-–]\s*\d{1,3})?)*)\]', text):
            items = list(re.finditer(r'(\d{1,3})(?:\s*[-–]\s*(\d{1,3}))?', m.group(1)))
            vals = [(int(i.group(1)), int(i.group(2)) if i.group(2) else int(i.group(1))) for i in items]
            if any(a < 1 or b > n or b < a for a, b in vals): continue
            for it, (a, b) in zip(items, vals):
                s = m.start(1) + it.start(); en = m.start(1) + it.end()
                mentions.append(dict(page=chars[s][1], start=s, end=en, text=text[s:en], entries=list(range(a - 1, b)), lines=sorted({(chars[k][1], chars[k][3]) for k in range(s, en)})))
        return mentions, text, chars
    by_year = {}
    for e in entries:
        if e['year']: by_year.setdefault(e['year'], []).append(e)
    for m in YEAR.finditer(text):
        y = int(m.group(1)); suf = m.group(2)
        cands = by_year.get(y)
        if not cands: continue
        # left context: letters/digits folded with positions, skipping the line breaks
        j = m.start(); L = []; Lpos = []
        k = j - 1
        while k >= 0 and len(L) < 120:
            ch = chars[k][0]
            f = fold_char(ch)
            if f:
                for c in reversed(f): L.append(c); Lpos.append(k)
            elif ch in '.?!' and k + 1 < j and text[k + 1:k + 3].strip()[:1].isupper() and not re.search(r'(al|[A-Z])$', text[max(0, k - 2):k]):
                pass
            k -= 1
        left = ''.join(reversed(L)); pos = list(reversed(Lpos))
        # strip earlier years of the same author list: "Smith (2019, 2021)"
        stripped = left
        while True:
            mm = re.search(r'(?:1[89]|20)\d{2}[a-z]?$', stripped)
            if not mm: break
            stripped = stripped[:mm.start()]
        # possessive: Banerjee's (1992)
        variants = [stripped]
        rawleft = text[max(0, j - 6):j]
        if re.search(r"['’]s\s*[\(\[]?\s*$", rawleft) and stripped.endswith('s'): variants.append(stripped[:-1])
        hit = []
        for e in cands:
            if suf and any(c['suffix'] for c in cands) and e['suffix'] != suf: continue
            for key in author_keys(e):
                for v in variants:
                    if v.endswith(key):
                        start_k = pos[len(v) - len(key)]
                        if chars[start_k][0].isupper() or (start_k > 0 and not chars[start_k - 1][0].isalpha()):
                            hit.append((len(key), start_k, e['id']))
                        break
        if not hit: continue
        best = max(h[0] for h in hit)
        ids = sorted({h[2] for h in hit if h[0] == best})
        s = min(h[1] for h in hit if h[0] == best); en = m.end()
        mentions.append(dict(page=chars[s][1], start=s, end=en, text=text[s:en].replace('\n', ' '), entries=ids, lines=sorted({(chars[k][1], chars[k][3]) for k in range(s, en) if chars[k][0] != '\n'})))
    return mentions, text, chars

def link_mentions(raw, pages, entries, style):
    """8.5: internal links whose destination is on a page of the list -> entry whose first line top is the highest at or below y+4"""
    if not entries: return [], 0
    firsts = []
    for e in entries:
        pi, li, l = e['lines'][0]
        if l['b']: firsts.append((pi, l['b']['x'], l['b']['y'] + l['b']['height'], e['id'], l['b']['y']))
    list_pages = {f[0] for f in firsts}
    lo = {pi: min(x[2]['b']['y'] for e in entries for x in e['lines'] if x[0] == pi and x[2]['b']) for pi in list_pages}
    hi = {pi: max(x[2]['b']['y'] + x[2]['b']['height'] for e in entries for x in e['lines'] if x[0] == pi and x[2]['b']) for pi in list_pages}
    out = []; ignored = 0
    for ln in raw['links']:
        t = ln['target'].get('internalDestination')
        if not t: continue
        pi, x, y = t['pageIndex'], t['x'], t['y']
        if pi not in list_pages or y < lo[pi] - 4 or y > hi[pi] + 30: ignored += 1; continue
        c = [f for f in firsts if f[0] == pi]
        near = [f for f in c if abs(f[1] - x) <= 60] or c
        below = [f for f in near if f[2] <= y + 4]
        pick = max(below, key=lambda f: f[2]) if below else min(near, key=lambda f: abs(f[2] - y))
        out.append(dict(page=ln['pageIndex'], text=ln['text'], entry=pick[3], b=ln['bounds']))
    # merge adjacent pieces with the same target
    merged = []
    for m in out:
        if merged and style == 'authorYear':
            p = merged[-1]
            same_line = abs(p['rects'][-1]['y'] - m['b']['y']) < 3 and 0 <= m['b']['x'] - (p['rects'][-1]['x'] + p['rects'][-1]['width']) < 12
            next_line = 0 < p['rects'][-1]['y'] - m['b']['y'] < 40 and m['b']['x'] < p['rects'][-1]['x']
            if not p['closed'] and p['entry'] == m['entry'] and p['page'] == m['page'] and (same_line or next_line):
                p['rects'].append(m['b']); p['text'] += ' ' + m['text']
                p['closed'] = bool(re.fullmatch(r'\s*(1[89]|20)\d{2}[a-z]?\s*', m['text']))
                continue
        merged.append(dict(page=m['page'], entry=m['entry'], rects=[m['b']], text=m['text'], closed=bool(re.fullmatch(r'\s*(1[89]|20)\d{2}[a-z]?\s*', m['text']))))
    return merged, ignored

def citations(raw, pages):
    fl = find_list(pages)
    if not fl: return None
    head, style, entries, lst = fl
    for e in entries: parse_entry(e, style)
    list_keys = {(pi, li) for (pi, li, _) in lst} | {(head[0], head[1])}
    tm, text, chars = text_mentions(pages, entries, style, list_keys)
    lm, ignored = link_mentions(raw, pages, entries, style)
    return dict(style=style, entries=entries, text_mentions=tm, link_mentions=lm, ignored_links=ignored, head=head, nlist=len(lst))

if __name__ == '__main__':
    raw = json.load(open(sys.argv[1]))
    what = sys.argv[2] if len(sys.argv) > 2 else 'all'
    pages, mode = build(raw)
    if what in ('all', 'kinds'):
        print('margin mode:', mode)
        for pg in pages:
            ks = {}
            for l in pg['lines']: ks[l['kind']] = ks.get(l['kind'], 0) + 1
            nums = [l['margin'] for l in pg['lines'] if l['margin'] is not None and (l['glued'] or l['kind'] == 'marginNumberOnly')]
            print(' page', pg['index'] + 1, ks, 'numbers', (min(nums), max(nums), len(nums)) if nums else None, 'standalone', sum(1 for l in pg['lines'] if l['kind'] == 'marginNumberOnly'), 'nearest-assigned', sum(1 for l in pg['lines'] if l.get('nearest')))
            for l in pg['lines']:
                if l['kind'] not in ('body', 'marginNumberOnly', 'empty'): print('    %-14s %r' % (l['kind'], l['text'][:60]))
    if what in ('all', 'lines'):
        for pg in pages:
            for l in pg['lines']:
                if l['kind'] == 'body': print('  p%d [%s]%s %r' % (pg['index'] + 1, l['margin'], '~' if l.get('nearest') else ' ', l['text'][:90]))
    if what in ('all', 'cite'):
        c = citations(raw, pages)
        if not c: print('no reference list')
        else:
            print('style', c['style'], 'entries', len(c['entries']), 'list lines', c['nlist'], 'heading', repr(c['head'][2]['text']))
            for e in c['entries']: print('  E%d %s %s%s doi=%s arxiv=%s | %s' % (e['id'], e['surnames'], e['year'], e['suffix'], e['doi'], e['arxiv'], e['raw'][:70]))
            print('text mentions', len(c['text_mentions']))
            for m in c['text_mentions']: print('  p%d %r -> %s lines=%d' % (m['page'] + 1, m['text'], [c['entries'][i]['surnames'][0] if c['entries'][i]['surnames'] else i for i in m['entries']], len(m['lines'])))
            print('link mentions', len(c['link_mentions']), 'ignored internal links', c['ignored_links'])
            for m in c['link_mentions']: print('  p%d %r -> E%d %s rects=%d' % (m['page'] + 1, m['text'], m['entry'], c['entries'][m['entry']]['surnames'][:1], len(m['rects'])))
    if what == 'render':
        print(render(pages))
    if what == 'quote':
        S, M = stream(pages)
        for q in sys.argv[3:]:
            r = locate(q, S, M)
            print(repr(q[:60]), '->', (label(pages, r), len(r), 'lines') if r else None)
