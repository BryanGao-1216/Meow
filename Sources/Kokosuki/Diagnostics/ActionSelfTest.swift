import AppKit

/// 真实指令入口 + 模拟显示器；不读取 Keychain、不启动模型、不写主人数据。
@MainActor
enum ActionSelfTest {
    static func run() -> Int {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("action FAIL: \(label)") }
        }
        check(Set(ActionLibrary.entries.map(\.action)) == Set(PetAction.allCases), "动作库覆盖全部可执行动作")
        check(ActionLibrary.entries.count == Set(ActionLibrary.entries.map(\.action)).count, "动作标签唯一")
        for entry in ActionLibrary.entries {
            check(PetAction.fromTag(entry.action.rawValue) == entry.action && PetAction.fromTag(entry.name) == entry.action,
                  "协议和中文别名：\(entry.name)")
        }
        let cases: [(String, PetAction?)] = [
            ("小喵，打个滚", .roll), ("给我翻一下肚皮看看", .roll), ("你能不能打个滚呀", .roll),
            ("可不可以打个滚", .roll), ("我想看你打滚", .roll), ("挥挥爪子打个招呼", .wave),
            ("点点头", .nod), ("摇摇头看看", .shakeHead), ("去散个步吧", .walk),
            ("先打个滚，再转圈", .roll), ("别睡了，起床", .wake),
            ("别打滚", .stop), ("不要打滚", .stop), ("你能不能别打滚", .stop),
            ("不要打滚，给我招手", .wave), ("别跳舞，打个滚吧", .roll),
            ("你为什么会打滚", nil), ("打滚是什么意思", nil), ("我今天看到小猫打滚", nil),
            ("我想打滚", nil), ("我不想打滚", nil), ("我去睡觉了", nil), ("你爱吃鱼吗", nil),
            ("你刚才在跳舞吗", nil), ("股票价格上去了", nil),
            ("跳个槽怎么样", nil),
            ("明天打个滚", nil), ("如果你打滚会怎么样", nil),
            ("如果我心情不好，你就打个滚", nil), ("等到我说可以，你再打滚", nil),
            ("不要打滚，明天再说", .stop), ("明天再打滚，现在先挥挥爪子", .wave),
            ("她说‘打个滚’", nil), ("他说“打个滚”", nil),
        ]
        for (text, expected) in cases {
            check(ActionLibrary.interpret(text).requested == expected, "判断：\(text)")
        }
        for text in ["不要打滚", "讲个打滚的故事", "为什么猫会打滚", "如果你打滚", "他说“打个滚”", "我喜欢打滚"] {
            let interpretation = ActionLibrary.interpret(text)
            let selection = ActionLibrary.select(intent: interpretation, proposed: .roll)
            check(selection == nil || selection == .stop, "不被模型标签绕过：\(text)")
        }
        let roll = Persona.parse("[playful] 看我的小肚皮！ [roll]")
        check(roll.action == .roll && !roll.text.contains("["), "模型动作标签可执行且不显示在聊天正文")
        check(Persona.parse("[happy] 给你挥爪喵 [wave]").action == .wave, "挥爪标签解析")
        check(ActionLibrary.select(intent: .init(), proposed: .wave) == .wave, "日常聊天可自然选择小动作")
        check(ActionLibrary.select(intent: .init(), proposed: .eat) == nil, "模型不能自行喂食")
        check(ActionLibrary.select(intent: .init(), proposed: .climb) == nil, "模型不能擅自跳窗")
        check(ActionLibrary.select(intent: .init(requested: .roll), proposed: .dance) == .roll, "明确指令优先于模型标签")
        check(ActionLibrary.select(intent: .init(requested: .roll), proposed: .roll, suppressAll: true) == nil, "创作任务不执行故事中的动作")
        check(ActionLibrary.canHandleOffline("打个滚") && !ActionLibrary.canHandleOffline("讲个打滚的故事"), "模型未就绪时输入框仍允许明确动作指令")
        check(Persona.detectGoodnight("我要睡了，别吵我，晚安"), "主人真实道晚安仍会入睡")
        for text in ["讲个说晚安的故事", "他说“晚安”", "如果我说晚安你会睡觉吗", "不要说晚安"] {
            check(!Persona.detectGoodnight(text), "故事、引用、假设和否定中的晚安不触发睡觉：\(text)")
        }
        var idle = ActionLibrary.IdleState(stats: PetStats(), ownerNearby: true, prefersQuiet: false)
        idle.stats.happiness = 85
        let happy = ActionLibrary.autonomousCandidates(idle)
        check(happy.contains { $0.action == .roll }, "开心且有精力时会自行打滚")
        check(happy.contains { $0.action == .wave }, "主人靠近时会挥爪")
        idle.ownerNearby = false
        check(!ActionLibrary.autonomousCandidates(idle).contains { $0.action == .wave }, "不对远处随机招手")
        idle.ownerNearby = true; idle.prefersQuiet = true
        let quiet = ActionLibrary.autonomousCandidates(idle)
        check(quiet.first { $0.action == .roll }!.weight < happy.first { $0.action == .roll }!.weight, "安静偏好降低活跃动作的权重")
        idle.stats.energy = 25
        let tired = ActionLibrary.autonomousCandidates(idle)
        check(!tired.contains { $0.action == .roll } && tired.contains { $0.action == .stretch }, "疲惫时选轻动作")
        idle.stats.energy = 90; idle.stats.happiness = 20
        check(ActionLibrary.autonomousCandidates(idle).contains { $0.action == .shakeHead }, "不高兴时可轻轻摇头")
        idle.stats.happiness = 85; idle.stats.fullness = 10
        check(!ActionLibrary.autonomousCandidates(idle).contains { $0.action == .roll }, "很饿时不自己做耗体力的动作")
        idle.stats.fullness = 80; idle.onPlatform = true
        check(!ActionLibrary.autonomousCandidates(idle).contains { $0.action == .roll }, "窗口顶上不自主翻滚")
        idle.onPlatform = false; idle.wallAttached = true
        check(ActionLibrary.chooseAutonomous(idle, unitRoll: 0.5) == nil, "贴墙不会产生自主肢体动作")
        idle.wallAttached = false; idle.sleeping = true
        check(ActionLibrary.chooseAutonomous(idle, unitRoll: 0.5) == nil, "睡觉不产生自主动作")
        idle.sleeping = false; idle.busy = true
        check(ActionLibrary.chooseAutonomous(idle, unitRoll: 0.5) == nil, "忙碌时不产生自主动作")

        let screen = WallScreen(id: "test", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 30, width: 1440, height: 846))
        func makeEngine() -> PetEngine {
            let engine = PetEngine(core: PetCore(), brain: Brain(loadPersistedHistory: false), screens: { [screen] })
            engine.dragTo(CGPoint(x: 700, y: 30 + PetLayout.feetDrop(scale: engine.scale)))
            return engine
        }
        let engine = makeEngine()
        var lines: [String] = []
        engine.chatMirror = { line, done in if done { lines.append(line) } }
        engine.userSays("打个滚给我看看")
        check(!engine.brain.isReady && engine.core.activity == .rollPose, "模型未就绪时，聊天指令仍立即打滚")
        check(lines.last?.contains("打滚") == true, "动作同时有中文回应")
        engine.userSays("不要打滚")
        check(engine.core.activity == .idle, "否定指令能中断正在做的动作")
        engine.userSays("讲一个打滚的故事")
        check(engine.core.activity != .rollPose, "故事要求不会直接触发打滚")
        for action: PetAction in [.wave, .nod, .shakeHead, .roll] {
            check(engine.requestAction(action) && engine.core.activity == ActionLibrary.entry(action).pose,
                  "明确新动作执行：\(ActionLibrary.entry(action).name)")
        }
        let now = Date()
        engine.tick(at: now.addingTimeInterval(3))
        check(engine.core.activity != .rollPose && engine.core.actionPhase == 0, "打滚结束后恢复陪伴状态")
        let automatic = makeEngine()
        check(automatic.requestAction(.nod, ownerRequested: false, at: now), "空闲时可执行自动点头")
        check(!automatic.requestAction(.wave, ownerRequested: false, at: now.addingTimeInterval(1)), "自动动作不打断进行中的动作")
        automatic.core.activity = .idle
        check(!automatic.requestAction(.nod, ownerRequested: false, at: now.addingTimeInterval(9)), "同一自动动作有冷却")
        check(automatic.requestAction(.nod, ownerRequested: false, at: now.addingTimeInterval(13)), "冷却后恢复自动动作")
        check(automatic.requestAction(.roll, at: now.addingTimeInterval(13.1)), "明确指令可覆盖自动动作与冷却")
        let unhappy = makeEngine()
        unhappy.core.stats.happiness = 20
        check(unhappy.requestAction(.shakeHead, ownerRequested: false) && unhappy.core.emotion == .sad,
              "心情低落时的自主摇头保留低落表情")
        unhappy.tick(at: Date().addingTimeInterval(2))
        check(unhappy.core.emotion != .proud, "摇头结束不切换为得意表情")
        automatic.beginDrag()
        check(!automatic.requestAction(.roll), "被拖着时不翻滚")
        automatic.dragTo(CGPoint(x: 20, y: 500))
        automatic.endDrag(velocity: .zero)
        check(!automatic.requestAction(.roll, ownerRequested: false) && automatic.core.wallSide == .left,
              "自动动作不能解除贴墙")
        automatic.userSays("打个滚")
        check(automatic.core.wallSide == nil && automatic.core.activity == .fall, "明确打滚指令先轻柔离墙")
        let start = Date()
        for step in 1...150 where automatic.core.activity != .rollPose {
            automatic.tick(at: start.addingTimeInterval(Double(step) / 60))
        }
        check(automatic.core.activity == .rollPose && automatic.core.dizzy == 0, "离墙落地后再执行打滚")
        let airborne = makeEngine()
        airborne.requestAction(.jump)
        check(airborne.requestAction(.roll) && airborne.core.activity != .rollPose, "空中收到动作指令先等落地")
        airborne.beginDrag()
        airborne.dragTo(CGPoint(x: 700, y: 30 + PetLayout.feetDrop(scale: airborne.scale)))
        airborne.endDrag(velocity: .zero)
        airborne.tick(at: start.addingTimeInterval(1))
        check(airborne.core.activity != .rollPose, "拖拽清除旧的待执行动作")
        let sleeping = makeEngine()
        sleeping.fallAsleep(commanded: true)
        sleeping.userSays("别打滚")
        check(sleeping.core.isSleeping && sleeping.core.activity == .sleep, "禁止动作不会把熟睡的小喵唤醒")
        print("action library: \(checks - failures)/\(checks) OK（无模型与网络）")
        return failures
    }
}
