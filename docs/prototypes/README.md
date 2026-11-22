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

**One difference on `ay_nolinks`.** The citation part needs the cleaned geometry of each line. In the app, `PDFPaperService` recomputes the bounds of every line whose margin number was removed (plan §7.2); a `RawDocument` dump has the raw bounds only, and their `x` is wrong on exactly those lines. The prototype takes the corrected bounds from an optional field on each line, `protoBoundsNoTrailingDigits`, which the dump tool used while the plan was written added. `referee-cli dump-raw` does not write it: it is not part of `RawDocument`. On the committed dump of `ay_nolinks` the two citation commands therefore report 8 entries and 9 text mentions; with the field present they report the 9 and 15 of the plan. Nothing else differs: on all six text fixtures `kinds`, `lines` and `render` print the same with and without the field, and so does `cite` on the other five.

The values marked ● in the acceptance tables of `plan.md` §11.4 were measured with these scripts on the real PDFKit output of the fixtures. The acceptance tables are the requirement; where a table and a prototype disagree, the table wins and the difference belongs in your contract notes.
