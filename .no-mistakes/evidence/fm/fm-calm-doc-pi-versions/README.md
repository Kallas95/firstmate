# Evidence: docs/calm-mode-feasibility.md now describes the installed Pi 0.84.2

Reader-facing surface: the rendered document. `doc-before-base.html` (base `ef35d79`) and
`doc-after-change.html` (`0692b6b`) render the real file with marked; evidence-scoping language is
highlighted (red = asserted version range, green = dated "verified" claim, orange = explicit "unverified").

| Artifact | Shows |
| --- | --- |
| `01-before-compatibility-evidence.png` | Base doc: compatibility section with no installed-version statement |
| `02-before-taxonomy-range-header.png` | Base doc: taxonomy table header asserting "baseline verified on Pi 0.81.1 through 0.82.0" |
| `03-before-crossharness-pi-row.png` | Base doc: cross-harness row "Pi (verified 0.81.1 through 0.82.0)" |
| `04-after-compatibility-evidence.png` | Changed doc: "The Pi installed on 2026-08-16 is 0.84.2" plus "No survey in this document has been redone on 0.84.2" |
| `05-after-crossharness-pi-row.png` | Changed doc: row is "Pi 0.81.1", dated, with the 0.84.2 re-exercise and the un-redone survey called out |
| `06-after-taxonomy-scoped-header.png` | Changed doc: taxonomy scoped to "surveyed on Pi 0.81.1", header range removed, later releases marked unverified |
| `07-after-anchor-jump-2026-08-16-record.png` | Clicking the new "2026-08-16 verification record" cross-reference lands on the new record |
| `installed-pi-0.84.2-claim-reproduction.txt` | Every command the new record prints, re-run on this machine, plus a runtime probe of both patched Pi seams and the 0.84.2 CHANGELOG lines behind the claims |
| `calm-pi-extension-run1.txt` | `tests/fm-calm-pi-extension.test.sh` against the installed Pi 0.84.2: 12/12 ok, transcript identical to the doc's record |
| `doc-link-anchor-resolution.txt` | All 11 intra-repo links/anchors of the doc resolve (GitHub slug rules) |
| `calm-suite-flake-observations.txt`, `calm-pi-extension-run2-known-race-failure.txt`, `calm-pi-extension-repeat-runs.txt` | 4 suite runs: 3 pass, 1 hits the documented pane-capture race (on the `loaded_off` case, not the `adjacent` case the doc names) |

Rendered HTML uses the vendored `marked.min.js` in this directory; open the HTML files directly.
