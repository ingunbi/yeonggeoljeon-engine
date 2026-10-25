// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalCombatSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else { throw BattleError.invalid("Original combat self-test failed: \(reason)") }; checks += 1
    }
    var tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
        defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:2,count:19),
        troopGrowth:Array(repeating:3,count:19),physicalSubtypeByClass:Array(repeating:1,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),
        strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map { OriginalItemEffect(id:$0,category:15,value:0) })
    var a = OriginalPersonStats(classID:0,level:10,troops:1000,attackScalar:100,defenseScalar:100,
        intellectScalar:100,morale:100,itemIDs:Array(repeating:255,count:8))
    var b = a
    try check(try OriginalCombat.maxTroops(classID:0,level:1,tables:tables) == 200,"source level1 maximum")
    try check(try OriginalCombat.maxTroops(classID:0,level:10,tables:tables) == 470,"source class-growth ordering")
    try check(try OriginalCombat.attackStat(a,tables:tables) == 440,"source scalar denominator and level multiplier")
    try check(try OriginalCombat.defenseStat(a,tables:tables) == 440,"source defense producer")
    tables.items[0] = OriginalItemEffect(id:0,category:0,value:25)
    tables.items[1] = OriginalItemEffect(id:1,category:0,value:10)
    a.itemIDs[0] = 0; a.itemIDs[1] = 1
    try check(try OriginalCombat.attackStat(a,tables:tables) == 550,"maximum equipment bonus, not summed bonuses")
    try check(try OriginalCombat.defenseStat(a,tables:tables) == 440,"attack-category equipment does not improve defense")
    tables.items[2] = OriginalItemEffect(id:2,category:5,value:25)
    a.itemIDs[2] = 2
    try check(try OriginalCombat.defenseStat(a,tables:tables) == 550,"source defense category5")
    a.itemIDs = Array(repeating:255,count:8)
    var rng = OriginalRNG(state:1)
    let before = rng
    try check(try rng.next(bound:0) == 0 && rng == before,"zero bound does not consume randomness")
    try check(try rng.next(bound:32768) == 16838,"source LCG high-word selection")
    try check(try rng.next(bound:32768) == 5758,"source LCG second output")
    let rtc = OriginalRNG.clockSeed(dayByte:0x25,hourByte:0x13,minuteByte:0x47,secondByte:0x59)
    try check(rtc.state == 0x59471325,"source RTC seed retains BCD bytes and little-endian structure fields")
    var preludeRNG = OriginalRNG(state:1)
    let noPrelude = try OriginalCombat.physicalPrelude(classID:0,subtype:0,sourceOptionsWord:0,rng:&preludeRNG)
    try check(noPrelude.isEmpty && preludeRNG.state == 1,"nonprojectile class has no source prelude RNG")
    let prelude = try OriginalCombat.physicalPrelude(classID:3,subtype:0,sourceOptionsWord:0,rng:&preludeRNG)
    var eightDraws = OriginalRNG(state:1)
    for _ in 0..<8 { _ = try eightDraws.next(bound:16) }
    try check(prelude.count == 8 && Array(prelude.prefix(2)) == [6,14] && preludeRNG == eightDraws,
              "source projectile prelude consumes eight draws before combat producer")
    preludeRNG = OriginalRNG(state:1)
    let highOptions = try OriginalCombat.physicalPrelude(classID:5,subtype:2,sourceOptionsWord:0x10,rng:&preludeRNG)
    try check(highOptions.count == 16,"source high-nibble setting doubles projectile draws")
    preludeRNG = OriginalRNG(state:1)
    let counterPrelude = try OriginalCombat.physicalPrelude(classID:3,subtype:7,sourceOptionsWord:0x10,rng:&preludeRNG)
    try check(counterPrelude.isEmpty && preludeRNG.state == 1,"source subtype7 skips projectile prelude")
    var first = OriginalRNG(state:1)
    let ordinary = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(ordinary.damage == 220 && ordinary.moraleLoss == 4,"physical attack and source morale-loss divisions")
    try check(ordinary.remainingTroops == 780 && ordinary.remainingMorale == 96,"source quantity/morale write values")
    try check(first.state == 1 && ordinary.counterRoll == nil,"ineligible class does not consume counter RNG")
    b.classID = 3
    let advantage = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(advantage.adjustedDefense == 330 && advantage.damage == 275,"source class-group advantage reduces defense quarter")
    a.classID = 3; b.classID = 0
    let disadvantage = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(disadvantage.adjustedDefense == 550 && disadvantage.damage == 165,"source class-group disadvantage increases defense quarter")
    a.classID = 0; b.classID = 0; tables.terrainDefensePercent[1] = 25
    let terrain = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:1,subtype:7,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(terrain.damage == 82,"terrain truncates before counter-strike half")
    b.troops = 20
    let lethal = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(lethal.damage == 20 && lethal.moraleLoss == 100 && lethal.remainingMorale == 100 && !lethal.counterEligible,
              "lethal calculation displays full morale loss but source writeback skips morale setter")
    b.troops = 1000; tables.physicalSubtypeByClass[0] = 0
    first = OriginalRNG(state:1)
    let counter = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(counter.counterRoll == 38 && counter.counterEligible,"source retaliation threshold")
    first = OriginalRNG(state:1)
    let suppressed = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:7,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(!suppressed.counterEligible && first.state != 1 && suppressed.counterRoll == 38,"suppressed counter still consumes its preceding original RNG draw")
    first = OriginalRNG(state:1)
    let disabled = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:true),tables:tables,rng:&first)
    try check(!disabled.counterEligible && disabled.counterRoll == 38,"source condition2 suppresses counter after rolling")
    tables.terrainDefensePercent[2] = 255
    let minimum = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:2,subtype:7,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(minimum.damage == 1 && minimum.moraleLoss == 1,"source signed terrain arithmetic then minimum one")
    let snapshot = try JSONDecoder().decode(OriginalPhysicalResult.self,from:JSONEncoder().encode(counter))
    try check(snapshot == counter,"source physical result round trip")
    let equal = try OriginalCombat.experienceGain(attackerLevel:10,defenderLevel:10,attackerRuntimeSlot:0,
        defenderRuntimeSlot:16,damage:10,defenderTroops:100)
    try check(equal.hit == 6 && equal.defeatedTarget == 0,"source hit experience")
    let leader = try OriginalCombat.experienceGain(attackerLevel:10,defenderLevel:10,attackerRuntimeSlot:0,
        defenderRuntimeSlot:15,damage:100,defenderTroops:100)
    try check(leader.hit == 6 && leader.defeatedTarget == 48,"source first enemy runtime-slot bonus")
    let high = try OriginalCombat.experienceGain(attackerLevel:1,defenderLevel:99,attackerRuntimeSlot:0,
        defenderRuntimeSlot:16,damage:100,defenderTroops:100)
    try check(high.hit == 16 && high.defeatedTarget == 32,"source higher-level target and hit cap")
    let low = try OriginalCombat.experienceGain(attackerLevel:12,defenderLevel:10,attackerRuntimeSlot:0,
        defenderRuntimeSlot:16,damage:100,defenderTroops:100)
    try check(low.hit == 4 && low.defeatedTarget == 16,"source lower-level kill divisor")
    let enemy = try OriginalCombat.experienceGain(attackerLevel:10,defenderLevel:10,attackerRuntimeSlot:15,
        defenderRuntimeSlot:0,damage:100,defenderTroops:100)
    try check(enemy.total == 0,"source enemy faction does not receive EXP")
    let levelup = try OriginalCombat.applyExperience(sourcePersonWord:0x200,level:10,experience:90,gain:16)
    try check(levelup.level == 11 && levelup.experience == 6 && levelup.levelsGained == 1,"source experience writeback before counter")
    let beyondCap = try OriginalCombat.applyExperience(sourcePersonWord:0x200,level:98,experience:90,gain:160)
    try check(beyondCap.level == 100 && beyondCap.experience == 50 && beyondCap.levelsGained == 2,"source cap is checked before its level-up loop")
    let capped = try OriginalCombat.applyExperience(sourcePersonWord:0x200,level:99,experience:90,gain:16)
    try check(capped.level == 99 && capped.experience == 90 && capped.ignoredReason != nil,"source capped person retains old EXP")
    let npc = try OriginalCombat.applyExperience(sourcePersonWord:0x300,level:10,experience:90,gain:16)
    try check(npc.level == 10 && npc.experience == 90 && npc.ignoredReason != nil,"source masked NPC identity does not gain EXP")
    tables.terrainDefensePercent[255] = 25
    let rawTerrain = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:255,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    try check(rawTerrain.damage == 165,"source raw byte terrain index is not clamped to nominal table")
    b = a; b.troops = 1000
    var strategyInput = OriginalStrategyInput(attacker:a,defender:b,terrainID:0,subtype:0,kind:2,weatherCode:1)
    first = OriginalRNG(state:2)
    let strategy = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(strategy.chanceBound == 110 && strategy.chanceRollByte == 28 && strategy.defenderThreshold == 27,
              "strategy success uses intellect and level with source byte roll")
    try check(strategy.success && strategy.jitterBound == 6 && strategy.jitterRoll == 5 && strategy.damage == 325,
              "source strategy coefficient and second random draw")
    try check(strategy.moraleLoss == 3 && strategy.remainingTroops == 675,"source strategy morale division")
    first = OriginalRNG(state:1)
    let failed = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    var twoDraws = OriginalRNG(state:1); _ = try twoDraws.next(bound:110); _ = try twoDraws.next(bound:6)
    try check(!failed.success && failed.damage == 0 && failed.moraleLoss == 0 && first == twoDraws,
              "failed strategy still consumes jitter draw before failure gate")
    strategyInput.terrainID = 1; first = OriginalRNG(state:2)
    let terrainStrategy = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(terrainStrategy.damage == 401 && terrainStrategy.jitterBound == 8,"strategy source terrain1 quarter bonus")
    strategyInput.terrainID = 0; strategyInput.subtype = 0x10; tables.strategyEnvironmentLookup[1] = 2
    first = OriginalRNG(state:2)
    let environmentStrategy = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(environmentStrategy.damage == 532 && environmentStrategy.jitterBound == 10,
              "source environment byte lookup and encoded subtype bonus")
    strategyInput.subtype = 0; strategyInput.defender.classID = 12; first = OriginalRNG(state:2)
    let resisted = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(resisted.resisted && resisted.defenderThreshold == 54 && !resisted.success && resisted.jitterBound == 3,
              "source resistant classes double threshold and halve base damage")
    strategyInput.kind = 3; first = OriginalRNG(state:2)
    let kindThree = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    var oneDraw = OriginalRNG(state:2); _ = try oneDraw.next(bound:110)
    try check(kindThree.success && kindThree.damage == 40 && kindThree.jitterBound == 0 && first == oneDraw,
              "source kind3 omits offense and success gate; zero jitter bound preserves RNG")
    strategyInput.attacker.intellectScalar = 0; strategyInput.defender.intellectScalar = 100
    strategyInput.defender.level = 255; strategyInput.defender.classID = 0; strategyInput.subtype = 0; first = OriginalRNG(state:2)
    let wrapped = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(wrapped.chanceBound == 0 && wrapped.damage == 1000 && wrapped.jitterBound == 1302,
              "source strategy DI subtraction wraps as an unsigned word before long damage")
    strategyInput.attacker = a; strategyInput.attacker.level = 255; strategyInput.defender = b; strategyInput.kind = 2
    first = OriginalRNG(state:1)
    let byteRoll = try OriginalCombat.strategyStrike(strategyInput,tables:tables,rng:&first)
    try check(byteRoll.chanceBound == 355 && byteRoll.chanceRollByte == 153,
              "strategy chance roll truncates to low byte after modulo word bound")
    var recovering = a; recovering.troops = 100; recovering.morale = 50
    first = OriginalRNG(state:2)
    let recovery = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:8,unitStatus:2,conditionFlags:0),tables:tables,rng:&first)
    try check(recovery.troopRoll == 6 && recovery.moraleRoll == 2 && recovery.remainingTroops == 310 && recovery.remainingMorale == 63,
              "source terrain recovery uses two RNG draws and defense scalar")
    try check(recovery.recoveryFlags == 3 && recovery.troopsDelta == 210 && recovery.moraleDelta == 13,
              "source combined terrain recovery flags")
    recovering.troops = 255; recovering.morale = 80; first = OriginalRNG(state:2)
    let closeRecovery = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:13,unitStatus:2,conditionFlags:0),tables:tables,rng:&first)
    try check(closeRecovery.remainingTroops == 470 && closeRecovery.remainingMorale == 100,
              "source near-cap gaps smaller than ten are filled before mutation")
    first = OriginalRNG(state:2)
    let plain = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:0,unitStatus:2,conditionFlags:0),tables:tables,rng:&first)
    try check(plain.recoveryFlags == 0 && plain.troopsDelta == 0 && plain.moraleDelta == 0 && first.state != 2,
              "plain terrain still consumes both source recovery draws")
    first = OriginalRNG(state:2)
    let inactive = try OriginalCombat.recover(OriginalRecoveryInput(stats:nil,terrainID:nil,unitStatus:0,conditionFlags:0),tables:tables,rng:&first)
    try check(inactive.remainingTroops == nil && inactive.remainingMorale == nil && inactive.troopRoll == 6 && inactive.moraleRoll == 2,
              "empty source runtime slots consume recovery draws without fabricated person data")
    recovering.itemIDs[0] = 55; first = OriginalRNG(state:2)
    let itemRecovery = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:0,unitStatus:2,conditionFlags:0),tables:tables,rng:&first)
    try check(itemRecovery.recoveryFlags == 2 && itemRecovery.troopsDelta == 0 && itemRecovery.remainingMorale == 100,
              "source item immediate55 adds morale recovery")
    recovering.itemIDs[0] = 8; recovering.classID = 12; first = OriginalRNG(state:2)
    let auraRecovery = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:0,unitStatus:2,conditionFlags:0),tables:tables,rng:&first)
    try check(auraRecovery.recoveryFlags == 3 && auraRecovery.adjacentMPGain == 2,
              "source item8 enables both recovery types and class12 emits adjacent MP aura")
    first = OriginalRNG(state:1)
    let condition = try OriginalCombat.recoverCondition2(stats:recovering,unitStatus:2,conditionFlags:0x82,rng:&first)
    try check(condition.roll == 38 && condition.threshold == 60 && condition.recovered && condition.remainingFlags == 0x80,
              "source condition2 recovery uses scalar plus current morale and preserves other flags")
    first = OriginalRNG(state:1)
    let noCondition = try OriginalCombat.recoverCondition2(stats:nil,unitStatus:0,conditionFlags:0x82,rng:&first)
    try check(noCondition.roll == nil && noCondition.threshold == nil && first.state == 1,
              "inactive condition recovery does not consume RNG or invent a stat threshold")
    try check(try OriginalCombat.maxMP(stats:a) == 50,"source maximum MP level and intellect")
    try check(try OriginalCombat.applyMPGain(current:49,gain:2,stats:a) == 50,"source MP aura caps to derived maximum")
    var highMP = a; highMP.level = 118; highMP.intellectScalar = 80
    try check(try OriginalCombat.maxMP(stats:highMP) == 0,"source maximum-MP quotient256 retains caller byte truncation")
    highMP.level = 255; highMP.intellectScalar = 100
    try check(try OriginalCombat.maxMP(stats:highMP) == 7,"source maximum MP discards multiplication high word")
    first = OriginalRNG(state:2)
    let lowMorale = try OriginalCombat.setMorale(stats:recovering,unitStatus:2,conditionFlags:0,requestedMorale:20,rng:&first)
    try check(lowMorale.remainingMorale == 20 && lowMorale.lossRoll == 3 && lowMorale.remainingFlags == 0,
              "low morale decline consumes source random5 even when no condition is set")
    first = OriginalRNG(state:3)
    let demoralized = try OriginalCombat.setMorale(stats:recovering,unitStatus:2,conditionFlags:0x80,requestedMorale:20,rng:&first)
    try check(demoralized.lossRoll == 2 && demoralized.remainingFlags == 0x82,
              "source morale decline sets condition2 on roll below three and preserves flags")
    var atMaximum = recovering; atMaximum.morale = 100; first = OriginalRNG(state:1)
    let unchangedMaximum = try OriginalCombat.setMorale(stats:atMaximum,unitStatus:2,conditionFlags:2,requestedMorale:100,rng:&first)
    try check(unchangedMaximum.conditionRecovery?.roll == 38 && unchangedMaximum.remainingFlags == 0,
              "setting unchanged maximum morale still attempts source condition recovery")
    first = OriginalRNG(state:1)
    let negative = try OriginalCombat.setMorale(stats:recovering,unitStatus:2,conditionFlags:0,requestedMorale:-1,rng:&first)
    try check(negative.remainingMorale == 0 && negative.lossRoll == nil && first.state == 1,
              "source negative requested word clamps but unsigned below30 test does not roll")
    first = OriginalRNG(state:2)
    let recoveryCondition = try OriginalCombat.recover(OriginalRecoveryInput(stats:recovering,terrainID:8,unitStatus:2,conditionFlags:2),tables:tables,rng:&first)
    try check(recoveryCondition.moraleMutation?.conditionRecovery?.roll != nil &&
              recoveryCondition.moraleMutation?.conditionRecovery?.threshold == 66,
              "recovery owns morale setter condition attempt after its two ordinary draws")
    b = a; b.morale = 3; first = OriginalRNG(state:2)
    let beforeDecline = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:b,terrainID:0,subtype:0,defenderCounterDisabled:false),tables:tables,rng:&first)
    let afterDecline = try OriginalCombat.setMorale(stats:b,unitStatus:2,conditionFlags:0,requestedMorale:beforeDecline.remainingMorale,rng:&first)
    try check(beforeDecline.counterEligible && afterDecline.lossRoll == 2 && afterDecline.remainingFlags&2 != 0,
              "post-strike low morale can disable an earlier eligible counter before recursion")
    try check(try OriginalCombat.shouldRetire(troops:100,morale:0,conditionFlags:2),
              "source condition2 with zero morale retires a unit while troops remain")
    try check(try !OriginalCombat.shouldRetire(troops:100,morale:0,conditionFlags:0),
              "zero morale alone is not the source retirement predicate")
    try check(try OriginalCombat.shouldRetire(troops:0,morale:100,conditionFlags:0),
              "source zero troops retire regardless of retained morale")
    first = OriginalRNG(state:1)
    let realStatus = try OriginalCombat.strategySuccess(caster:a,target:a,denominatorByte:2,rng:&first)
    try check(realStatus.roll == 8 && realStatus.threshold == 55 && !realStatus.success,
              "actual condition strategy uses denominator2 instead of AI raw130")
    first = OriginalRNG(state:1)
    let aiStatus = try OriginalCombat.strategySuccess(caster:a,target:a,denominatorByte:0x82,rng:&first)
    try check(aiStatus.threshold == 0 && aiStatus.success,"AI suppression bit remains in source strategy-success denominator")
    var healingTarget = a;healingTarget.level = 99;healingTarget.troops = 0;healingTarget.morale = 80
    first = OriginalRNG(state:1)
    let healed = try OriginalCombat.heal(OriginalHealingInput(caster:a,target:healingTarget,targetStatus:2,
        targetConditionFlags:0,encodedSubtype:1),tables:tables,rng:&first)
    try check(healed.troopRoll == 3 && healed.troopsDelta == 653 && healed.remainingTroops == 653,
              "actual healing uses caster bonus without AI utility bonus or threshold")
    first = OriginalRNG(state:1)
    let withoutCaster = try OriginalCombat.heal(OriginalHealingInput(caster:nil,target:healingTarget,targetStatus:2,
        targetConditionFlags:0,encodedSubtype:1),tables:tables,rng:&first)
    try check(withoutCaster.troopRoll == 38 && withoutCaster.troopsDelta == 638,"source caster-slot255 omits caster stats")
    healingTarget.level = 10;healingTarget.troops = 470;healingTarget.morale = 100
    try check(try !OriginalCombat.healingUseful(target:healingTarget,conditionFlags:0,recoveryFlags:3,tables:tables),
              "full troops and morale without condition2 reject source combined healing")
    try check(try OriginalCombat.healingUseful(target:healingTarget,conditionFlags:2,recoveryFlags:2,tables:tables),
              "source actual healing permits condition recovery at full morale")
    first = OriginalRNG(state:1)
    let cured = try OriginalCombat.heal(OriginalHealingInput(caster:a,target:healingTarget,targetStatus:2,
        targetConditionFlags:2,encodedSubtype:2),tables:tables,rng:&first)
    try check(cured.moraleDelta == 0 && cured.moraleRoll == 2 && cured.remainingFlags == 0 &&
              cured.moraleMutation?.conditionRecovery?.roll == 58,"actual full-morale healing consumes jitter then cure draw")
    try check(try OriginalCombat.moraleStrategyAmount(casterLevel:10,targetLevel:10,category:0,targetMorale:100) == 20,
              "actual morale strategy omits AI random multiplier")
    let completion = try OriginalCombat.completeStrategy(abilityID:21,casterClassID:12,currentMP:30,mpCost:7)
    try check(completion.remainingMP == 23 && completion.flatExperience == 12,"single-target healer-class completion EXP and MP")
    try check(try OriginalCombat.completeStrategy(abilityID:30,casterClassID:12,currentMP:30,mpCost:7).flatExperience == 8,
              "area healing retains common eight EXP instead of single-target healer bonus")
    var invalid = a; invalid.itemIDs[0] = 64
    do { _ = try OriginalCombat.attackStat(invalid,tables:tables); throw EngineError.invalid("invalid item test did not reject") }
    catch BattleError.invalid { checks += 1 }
    do { _ = try OriginalCombat.maxTroops(classID:19,level:1,tables:tables); throw EngineError.invalid("invalid class test did not reject") }
    catch BattleError.invalid { checks += 1 }
    print("Original combat self-tests passed: \(checks)")
}
