# Battle and campaign runtime contracts

The Python exporters own original binary formats. Swift consumes their typed
facts without reinterpreting original byte offsets. All original-derived data
and pictures are local build outputs, excluded from the public source tree.

## Battles

`prepare_battles.py` writes `battles.json`. `BattleCatalog` and `BattleDefinition`
preserve unknown fields rather than supplying guessed original values. Source
picture-cell grids, logical battle-cell grids, native placement identities,
literal person IDs and unknown DOS runtime slots are different representations.
Conditional roster eligibility stays unresolved in a separate collection.

`BattleSession` requires an explicit policy. The current `experimentalV1`
policy uses separate uniform effective stats, unit-cost orthogonal movement,
prototype damage, deterministic decisions and elimination objectives. None is
advertised as original combat behavior. The original policy is unsupported.

The UI renders locally exported source backgrounds with generated unit marks.
It validates the source32px logical-cell geometry and keeps original image
paths contained in the chosen data directory. Conditional units are not
silently treated as absent from the original battle.

## Campaigns

`scenario_format.py` owns instruction framing and source record directories.
`prepare_campaign.py` owns the catalog of records and source transitions.
`prepare_scene.py` owns translation of the currently supported native scene
effects. A record is an entry point into a block stream; the next record entry
is not automatically its execution boundary.

`CampaignSession` owns explicit research preview selection. Unknown conditions
block automatic selection; an explicit conditional preview retains a different
origin. Completing a record does not choose a successor or invent flags.
Battle requests keep their source identity. Experimental outcomes are retained
separately and do not become original campaign progress.

## Verification

Native reports use the same state machines and renderers as interactive views.
They distinguish a supported source boundary, a declared unsupported boundary,
a runtime failure and an unexpected end of stream. Diagnostics use separate
output directories and do not modify source data or user progress.

Coverage counts for framed records, translated previews and native execution
are separate. A complete directory catalog does not establish full campaign
playback, original battle parity, or every source branch's reachability.
