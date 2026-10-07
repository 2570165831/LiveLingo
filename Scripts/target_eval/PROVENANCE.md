# A5/A6 local provenance audit

Only existing local files were read. No network, model, corpus download, raw
corpus write or Swift policy change was used. Paths below are relative to the lab
root. These observations concern the reviewed snapshots, not a later Swift build.

The English reference in `data/un/S_PV.10142/turns.json`, turn 9, contains Greek
capital Tau U+03A4 at Unicode scalar offset 3408 (zero based). The complete
reference SHA-256 is
`c8df1a159803b112f28fcc26904b5af7ecf1463faca2a0b0474e45f26cb0f611`.
`data/un/S_PV.10142/record-en.txt` has the same character at offset 47825,
physical line 564 and PDF page 11. Its SHA-256 is
`4a415b385068538b7a66319c80644dfb663a839187595b0667e26eb5373d8932`.
Independently running `pdftotext -layout -f 11 -l 11` to stdout on the local
`record-en.pdf` confirmed one Tau on that page; the PDF SHA-256 is
`92dffaa06c144bc7cc5de324ac9a2c88fa437182707fd75d28e9e4fb9ef313c1`.
The stored provenance points to the [official English record](https://documents.un.org/doc/undoc/pro/n26/093/60/pdf/n2609360.pdf);
the URL was not fetched again. This confirms a local official-record text-layer
defect, rather than an alignment-introduced character. The load-time annotation
and report keep that distinction; all raw files stay intact.

`work/target-eval/latin-calibration-final.json`, SHA-256
`25d624b16df4e3b9b0fddb332e6695080b729073579a22bb353b47d00e02bbd0`,
has 85 included turns and two excluded partial turns. Recomputing NFC Unicode
letter ratios `French letters / Russian letters` from all 85 complete turns
gives p99.5 **1.1890933136389399**. With linear interpolation, the index is
`(85 - 1) * 0.995 = 83.58`. The two upper observations are:

| Turn | French letters | Russian letters | Ratio |
| --- | ---: | ---: | ---: |
| S/PV.10168:turn:9 | 156 | 134 | 1.164179104477612 |
| S/PV.10192:turn:2 | 2098 | 1738 | 1.2071346375143843 |

`ceil(p99.5 * 100) / 100` is **1.19**, not 1.20. Including both partial turns
instead gives 87 observations, p99.5 **1.7345752222033324**, ceiling **1.74**;
it does not explain 1.20. The previous
`work/target-eval/superseded-latin-before-review/latin-calibration.json`, SHA-256
`a9d6683b17fefaca547d8db3258434d5a467b5ea8301bc6f976443605aa4e03b`,
already reports the same complete-turn p99.5. The final report records configured
fr/ru 1.20 with no override, and the initial implementation commit `34c4405`
contains the hardcoded 1.20. Neither report supplies a separate derivation for
the extra 0.01. Its original rationale remains **unconfirmed**.

Advice to the parent/Swift owner: if the table is meant to follow its stated
method, correct fr/ru to **1.19**. If 1.20 is deliberately retained as a separate
heuristic, correct the comment to disclose that exception and its actual reason;
do not label it the rounded empirical p99.5. No ratio is increased here, and the
largest in-sample reference is not used to tune the gate. The final snapshot
rejects 2098 letters against `1738 * 1.20 + 12 = 2097.6`, a 0.4-letter excess.

The reviewed English 6/425 comparison false rejections represent **two** affected
turn/reference clusters: five share the Tau reference, and one is the length
case. The five occurrences are not five independent reference failures. Fixing
the annotation does not certify a new acceptance result; a fresh Swift CLI run
is needed. Even hypothetical zero failures among 85 IID references yield a
one-sided 95% upper rate `1 - 0.05 ** (1 / 85) = 0.03463007497068704` (3.463%).
Within-meeting dependence may further weaken that assumption. No independent
sentence/caption holdout exists, so neither this number nor an all-zero
bootstrap interval establishes the 1% gate. No real calibration was rerun for
this sidecar; all software tests use synthetic inputs.
