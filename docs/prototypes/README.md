# Prototypes

Python prototypes written while the plan was being revised. They are reference material for the Swift implementation, not part of the app, and nothing in the build depends on them.

| File | What it prototypes | Plan sections |
|---|---|---|
| `text_and_citations.py` | text cleaning (margin line numbers, page furniture), the rendering sent to a model, quote matching and location labels, reference-list parsing, text and link citation mentions | §6.2, §6.7, §7.2, §8.2–§8.5 |
| `check_citations.py` | compares text mentions with link mentions for each raw dump | §8.5 |

Input is a `RawDocument` JSON dump (`Fixtures/raw/<name>.raw.json`, printed by `referee-cli dump-raw <pdf>`).

```
python3 -I docs/prototypes/text_and_citations.py Fixtures/raw/ay_nolinks.raw.json all      # or: kinds | lines | cite | render
python3 -I docs/prototypes/text_and_citations.py Fixtures/raw/ay_nolinks.raw.json quote "The coefficient in Table 2 is 0.91"
python3 -I docs/prototypes/check_citations.py docs/prototypes Fixtures/raw/*.raw.json
```

The values marked ● in the acceptance tables of `plan.md` §11.4 were measured with these scripts on the real PDFKit output of the fixtures. The acceptance tables are the requirement; where a table and a prototype disagree, the table wins and the difference belongs in your contract notes.
