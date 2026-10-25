// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalBattleSpriteSelfTests() throws {
    var count = 0
    func check(_ value:@autoclosure()throws->Bool,_ message:String)throws {
        guard try value() else {throw BattleError.invalid("Original battle sprite self-test: \(message)")};count += 1
    }
    let frames = (0..<47).flatMap { member in (0..<2).map { frame in
        OriginalBattleSpriteFrame(member:member,frame:frame,image:"images/synthetic-\(member)-\(frame).png",
            flippedImage:"images/synthetic-\(member)-\(frame)-flipped.png")
    }}
    let catalog = OriginalBattleSprites(format:1,width:32,height:32,memberCount:47,paletteSlot:3,frames:frames)
    try catalog.validate()
    try check(try catalog.select(person:30,classID:6,enemy:false,flags:0,frame:0).member == 12,"friendly normal class member uses native class*2")
    try check(try catalog.select(person:30,classID:6,enemy:true,flags:0,frame:1).member == 13,"enemy normal class member adds one")
    try check(try catalog.select(person:0,classID:2,enemy:true,flags:0,frame:0).member == 40,"source person0 selection precedes ordinary faction class lookup")
    try check(try catalog.select(person:4,classID:0,enemy:false,flags:0,frame:0).member == 45,"source person4 has a fixed member")
    try check(try catalog.select(person:8,classID:0,enemy:true,flags:0,frame:0).member == 46,"source person8 has a fixed member")
    try check(try catalog.select(person:0,classID:2,enemy:false,flags:2,frame:0).member == 43,"condition2 overrides person-specific member for friendlies")
    try check(try catalog.select(person:4,classID:0,enemy:true,flags:2,frame:0).member == 44,"condition2 overrides person-specific member for enemies")
    let flipped = try catalog.select(person:30,classID:0,enemy:false,flags:0x10,frame:1)
    try check(flipped.flipped && flipped.image == "images/synthetic-0-1-flipped.png","flag10 selects an already mirrored frame without reinterpreting priority")
    try check(try catalog.standing(person:30,classID:0,enemy:false,flags:0,animationPhase:0).frame == 0,"source initial unacted phase uses first frame")
    try check(try catalog.standing(person:30,classID:0,enemy:false,flags:0x80,animationPhase:0).frame == 1,"acted units use the second source frame")
    try check(try catalog.standing(person:30,classID:0,enemy:false,flags:0,animationPhase:1).frame == 1,"alternate source battle phase uses second frame")
    try check(try catalog.moving(person:30,classID:0,enemy:false,flags:0x10,direction:1,stepPixels:8).flipped == false,"east movement clears sprite flip")
    try check(try catalog.moving(person:30,classID:0,enemy:false,flags:0,direction:3,stepPixels:7).flipped,"west movement sets sprite flip")
    for direction in [0,2] {
        try check(try catalog.moving(person:30,classID:0,enemy:false,flags:0x10,direction:direction,stepPixels:16).flipped,"vertical movement preserves prior facing")
    }
    try check(try [0,7,8,15,16,23,24,31,32].map {try catalog.moving(person:30,classID:0,enemy:false,flags:0,direction:0,stepPixels:$0).frame} == [0,0,1,1,0,0,1,1,0],
        "source movement frame changes every eight pixels and wraps every sixteen")
    var duplicate = catalog;duplicate.frames[1] = duplicate.frames[0]
    do {try duplicate.validate();throw BattleError.invalid("duplicate sprite accepted")} catch EngineError.invalid {_ = 0;count += 1}
    var escaped = catalog;escaped.frames[0].image = "../source.png"
    do {try escaped.validate();throw BattleError.invalid("escaped sprite accepted")} catch EngineError.invalid {_ = 0;count += 1}
    do {_ = try catalog.select(person:0,classID:18,enemy:false,flags:0,frame:0);throw BattleError.invalid("unavailable native member accepted")} catch BattleError.unsupported {_ = 0;count += 1}
    var invalidDirection = false
    do {_ = try catalog.moving(person:30,classID:0,enemy:false,flags:0,direction:4,stepPixels:0)} catch BattleError.invalid {invalidDirection = true}
    try check(invalidDirection,"unsupported source direction is rejected")
    let duel = OriginalDuelSprites(width:96,height:96,memberCount:78,
        frames:(0..<78).map{OriginalDuelSpriteFrame(member:$0,image:"images/duel-synthetic-\($0).png",flippedImage:"images/duel-synthetic-\($0)-flipped.png")},
        specialPersonBanks:[255,1,4,255,3])
    try duel.validate()
    try check(try duel.select(person:30,loadMode:0,frame:9).member == 9,"first generic duel participant uses its ten-frame source bank")
    try check(try duel.select(person:30,loadMode:1,frame:9).member == 24,"second generic participant has a distinct source bank")
    try check(try duel.select(person:1,loadMode:0,frame:4).member == 19,"special duel participant bank comes from caller-owned table, using synthetic values here")
    try check(try duel.select(person:372,loadMode:0,frame:0).member == 30,"source person372 uses its original exceptional bank")
    try check(try duel.select(person:373,loadMode:1,frame:0).member == 45,"source person373 uses its original exceptional bank")
    let dying = try duel.select(person:30,loadMode:2,frame:4)
    try check(dying.member == 29 && dying.flipped,"death loader replaces the second participant with its final five mirrored source frames")
    let fleeing = try duel.select(person:30,loadMode:3,frame:2)
    try check(fleeing.member == 18 && !fleeing.flipped,"flee loader uses three shifted frames without mirroring")
    var presentation = OriginalScriptDuel(people:[0,5])
    try check(try OriginalDuelSprites.sourceRect(duel:presentation,side:0) == CGRect(x:80,y:80,width:96,height:96),
        "duel tile position converts to native top-left anchor at pixel16,32")
    presentation.positions[0] = -2;presentation.camera = 27
    try check(try OriginalDuelSprites.sourceRect(duel:presentation,side:0).minX == -16,
        "duel signed tile positions retain clipping and are not shifted by camera twice")
    try check(OriginalDuelSprites.sourceDrawOrder == [1,0] && OriginalDuelSprites.sourceViewport == CGRect(x:16,y:32,width:416,height:208),
        "duel native viewport and overlapping participant order follow source compositor")
    print("Original battle sprite self-tests passed: \(count)")
}
