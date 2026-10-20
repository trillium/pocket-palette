# Golden-query matcher test

`make test` runs `GoldenQueryTests`: 30 spoken-style queries against a fixed 106-rule fixture; the expected command must appear in the top 3 for >=90% of them. Failing queries are printed (`GOLDEN failing queries:`) and in the assertion message.

- Data: `App/Tests/Golden/commands.json` (rules in feed shape, mixed global/app scope) and `queries.json` (`expect` = acceptable ids). Test: `App/Tests/GoldenQueryTests.swift`.
- Ranking under test: `CommandIndex.search` on plain text (no context or history boost; the fixture holds rules for several apps at once, which a live feed never would).
- Queries include filler ("please", "the", "my"), partial words ("dev tools"), plurals ("sidebars"), reorderings, spoken numbers ("line 40") and near-synonyms ("everything", "minimise").
- Editing the fixture or queries changes the baseline: add queries, do not retune the matcher around one.

## Method and result
1. Baseline, matcher untouched: **15/30 = 50%**. Every miss was a query word the rule lacks (filler, plural, synonym, number), because all tokens had to match.
2. General changes in `FuzzyMatcher`, none keyed to a query: drop filler words and bare numbers from the query (unless nothing else is left); match plurals via a singular stem (-5); a small synonym/spelling table (-10); with 3+ significant words one may go unmatched (-45) so full matches still rank first.
3. After: **30/30 = 100%**; existing tests unchanged and green.

## Matcher layers
Beyond the fuzzy core, `CommandIndex.search` adds open slots (`<text>`, `<app>`, trailing "that"/"this"), a semantic fallback (`SemanticFallback`) gated so it only fires when the fuzzy pass finds nothing strong, and concept links (`ConceptLinks`: inverse pairs and concept words). Each layer has its own unit tests; the golden test guards the combined ranking.
