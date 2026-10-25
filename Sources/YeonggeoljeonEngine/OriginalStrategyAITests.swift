// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalStrategyAISelfTests() throws {
    var checks = 0
    func check(_ test:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try test() else { throw BattleError.invalid("Original strategy AI self-test: \(reason)") };checks += 1
    }
    var tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
        defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:10,count:19),
        troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let caster = OriginalPersonStats(classID:0,level:10,troops:1000,attackScalar:100,defenseScalar:100,
        intellectScalar:100,morale:100,itemIDs:Array(repeating:255,count:8))
    let target = caster
    var input = OriginalStrategyAITargetInput(caster:caster,target:target,targetStatus:2,targetConditionFlags:0,
        abilityID:0,category:0,terrainID:0,terrainEligible:true,weatherCode:1)
    var rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 528,
              "source offensive AI estimate differs from actual strategy damage")
    input.terrainID = 1;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 653,"offensive estimate source terrain quarter bonus")
    tables.strategyEnvironmentLookup[1] = 2;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 0 && rng.state == 1,
              "source family0 environment gate precedes random estimate")
    input.abilityID = 5;input.terrainID = 0;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 783,"source family1 environment quarter bonus")
    input.terrainEligible = false;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 0 && rng.state == 1,
              "profile-owned terrain gate preserves RNG")
    input.terrainEligible = true;input.abilityID = 15;input.targetConditionFlags = 2;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 0 && rng.state == 1,
              "existing condition2 skips source status estimate")
    input.targetConditionFlags = 0;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 358,
              "source status estimate consumes chance then random300")
    input.caster.intellectScalar = 0;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 38,
              "failed status estimate retains random300 score and zero chance bound does not advance RNG")
    input.caster = caster;input.abilityID = 18;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 180,"morale offensive AI estimate uses random multiplier")
    input.caster.level = 0;input.target.level = 255;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 900,
              "source offensive morale estimate wraps its negative word before target cap")
    input.caster = caster;input.target = target;input.abilityID = 21;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 0 && rng.state == 1,
              "full morale skips source support estimator")
    input.target.morale = 30;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 860,
              "source morale utility adds category bonus and multiplies below40 by20")
    input.abilityID = 24;input.target.troops = 500;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 600,
              "source troop utility caps to missing troops then adds utility bonus")
    input.target.troops = 950;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 0 && rng.state != 1,
              "small troop gap consumes support RNG before minimum utility threshold")
    input.abilityID = 27;input.target.troops = 500;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 1440,
              "combined support utility preserves troop-then-morale draw order")
    let support = OriginalStrategyAISupportInput(caster:caster,target:target,targetStatus:1,encodedSubtype:3)
    rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.supportScore(support,tables:tables,rng:&rng) == 0 && rng.state == 1,
              "inactive source support target consumes no RNG")
    input.abilityID = 15;input.caster.intellectScalar = 5;input.caster.level = 0;input.target.level = 255
    input.target.intellectScalar = 100;input.target.classID = 12;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 58,
              "source resistant-class status threshold doubles after raw denominator130")
    input.target.classID = 0;rng = OriginalRNG(state:1)
    try check(try OriginalStrategyAI.targetScore(input,tables:tables,rng:&rng) == 358,
              "source nonresistant status estimate retains successful base300")
    print("Original strategy AI self-tests passed: \(checks)")
}
