import Foundation

/// 中文界面文案、互动台词和创作兜底内容。
enum L10n {
    static func t(_ key: String) -> String {
        table[key] ?? key
    }

    private static let table: [String: String] = [
        // menu
        "menu.chat": "和\(AppIdentity.name)聊天…",
        "menu.feedFish": "喂小鱼干 🐟",
        "menu.feedCookie": "喂小饼干 🍪",
        "menu.play": "一起玩 🧶",
        "menu.sleep": "去睡觉 💤",
        "menu.wake": "叫醒它 ☀️",
        "menu.callOver": "过来这边!",
        "menu.stats": "状态",
        "menu.settings": "设置…",
        "menu.quit": "退出\(AppIdentity.appName)",
        "menu.brainLoading": "🧠 小脑瓜启动中…",
        "menu.brainReady": "🧠 小脑瓜在线",
        "menu.brainFailed": "🧠 小脑瓜加载失败",

        // stats
        "stats.hunger": "饱腹",
        "stats.energy": "精力",
        "stats.happiness": "心情",

        // chat
        "chat.title": AppIdentity.name,
        "chat.placeholder": "对\(AppIdentity.name)说点什么…",
        "chat.send": "发送",
        "chat.thinking": "思考中…",
        "chat.loading": "小脑瓜还在启动,稍等一下下…",
        "chat.failed": "小脑瓜加载失败了 😿",
        "chat.requestFailed": "云端请求失败：",
        "chat.clear": "清空聊天记录",

        // settings
        "settings.title": "设置",
        "settings.brainProvider": "对话模型",
        "settings.localModel": "本地 · 离线 MLX",
        "settings.volcengine": "云端 · 火山方舟",
        "settings.modelName": "模型名称 / 推理接入点 ID",
        "settings.keyPlaceholder": "填写 Agent Plan 专属 API Key",
        "settings.agentPlanConsole": "打开 Agent Plan 控制台",
        "settings.testConnection": "测试连接",
        "settings.testingConnection": "正在测试连接…",
        "settings.connectionOK": "连接成功，点击保存后即可使用。",
        "settings.applyBrain": "保存模型设置",
        "settings.brainSaved": "已保存，模型配置已重新加载。",
        "settings.localUnavailable": "此版本仅支持云端模型，请在设置中选择火山方舟。",
        "settings.cloudNotice": "Key 保存在 macOS 钥匙串。云端聊天和主动搭话会将对话及宠物状态发送给所配置的服务，并消耗 API 额度。",
        "settings.size": "宠物大小",
        "settings.size.mini": "迷你",
        "settings.size.small": "小",
        "settings.size.medium": "中",
        "settings.size.large": "大",
        "settings.chatter": "会主动找你说话",
        "settings.chatterFreq": "话痨程度",
        "settings.freq.low": "文静",
        "settings.freq.mid": "正常",
        "settings.freq.high": "话痨",
        "settings.autoSleep": "夜间自动睡觉 (23:00–7:00)",
        "settings.parkour": "会跳上应用窗口",
        "settings.thinking": "深度思考(回复更慢但更聪明)",
        "settings.resetStats": "重置宠物状态",
        "settings.about": "\(AppIdentity.appName) · \(AppIdentity.name) — 你的桌面小猫。\n本地模式离线运行，也可选用云端对话。",
    ]

    // MARK: - Canned lines (fast reactions; LLM adds variety on top)

    static func canned(_ category: CannedCategory) -> String {
        let lines = cannedTable[category] ?? []
        return lines.randomElement() ?? "…"
    }

    enum CannedCategory {
        case poke, pokeAnnoyed, petted, fedFish, fedCookie, fullTummy
        case wokenGrumpy, landingOuch, playStart
        case morning, afternoon, evening, night
        case hungry, bored, sleepy, confused
    }

    private static let cannedTable: [CannedCategory: [String]] = [
        .poke: ["喵?找我有事嘛?", "嘿嘿,痒痒的!", "喵~ 我在哦!", "嗯?怎么啦?"],
        .pokeAnnoyed: ["喂!!别戳啦!!", "呜喵!!人家都被戳晕了!!", "再戳我要咬你了哦!"],
        .petted: ["呼噜噜…好舒服…", "再多摸摸…耳朵后面…", "唔~ 最喜欢摸摸头了!", "呼噜呼噜…♪"],
        .fedFish: ["小鱼干!!最喜欢了!!", "啊呜啊呜…好好吃…", "你记得欸!小鱼干!!"],
        .fedCookie: ["小饼干!咔嚓咔嚓~", "甜甜的!!谢谢你!!", "啊呜…掉渣渣了,嘿嘿"],
        .fullTummy: ["嗝…吃好饱…", "肚子都圆滚滚了…", "一口也吃不下啦…"],
        .wokenGrumpy: ["唔…再睡五分钟…", "谁吵醒我…哦,是你呀…", "*哈欠* …人家梦到小鱼干了…"],
        .landingOuch: ["哇!!…我是故意的哦。", "喵呜!!落地满分对吧?", "噗!!…疼疼疼…"],
        .playStart: ["毛线球!!冲呀!!", "玩耍玩耍~!", "看我的超级转圈!!"],
        .morning: ["早上好!今天一定是超棒的一天!", "早安~ 睡得好嘛?"],
        .afternoon: ["下午犯困了吧?跟我一起伸个懒腰~", "别忘了喝水哦!"],
        .evening: ["还在努力嘛?我给你加油!", "晚上好~ 今天快忙完了吗?"],
        .night: ["很晚了…别熬夜太久哦?", "*哈欠* …你也早点睡吧…"],
        .hungry: ["肚子咕咕叫了…", "是不是…该吃点心了?👀", "我好像闻到小鱼干了…没有吗…"],
        .bored: ["好无聊…陪我玩嘛?", "*打滚滚*", "喂,看我一下嘛!"],
        .sleepy: ["眼皮…好重…", "*哈欠* …小睡一下下好了…"],
        .confused: ["…?(歪头看你)", "喵?再说一遍嘛?"],
    ]

    // MARK: - Curated creative content (backstop when the LLM fails to deliver)

    static func creativeCanned(_ kind: Persona.CreativeKind) -> String {
        let items = creativeBank[kind] ?? []
        return items.randomElement() ?? "…"
    }

    private static let creativeBank: [Persona.CreativeKind: [String]] = [
        .joke: [
            "我昨天追自己的尾巴,追了十圈才想起来——它长在我身上呀!",
            "主人问我为什么打翻杯子。我说:是重力的错,跟爪爪没关系!",
            "医生问我哪里不舒服。我说:一天不吃小鱼干,浑身都不舒服!",
            "我对着镜子哈气,镜子里的猫也哈气。我们互相记仇到现在。",
        ],
        .riddle: [
            "身上滑溜溜,住在水里头,猫咪最爱它,晒干更好吃——猜猜是什么?",
            "白天睡大觉,晚上到处跑,胡子当尺子,走路静悄悄——是谁呀?",
        ],
        .game: [
            "我们玩词语接龙吧!我先来:小鱼干。要用「干」字开头哦,该你啦!",
            "猜谜时间!我心里想了一种水果:黄黄的,弯弯的,猴子超爱吃——你猜是什么?",
            "我们玩「猜猜我在想什么」!提示:圆圆的,毛线做的,我最爱追着跑——猜!",
        ],
        .song: ["♪ 喵喵喵~尾巴摇 ♪ 小鱼干呀真美妙 ♪ 主人在家我睡觉 ♪ 主人不在……我也睡觉 ♪"],
        .fortune: ["今日运势:大吉!宜摸猫,宜吃小鱼干,忌加班。摸摸我会更幸运哦!", "今日运势:中吉~宜伸懒腰,宜喝水,忌久坐。起来活动一下嘛!"],
        .praise: ["主人是世界上最好的主人!又聪明又温柔——这话从最挑剔的猫嘴里说出来,含金量可是很高的哦!"],
        .poem: [
            "阳光趴在窗台上,\n我趴在阳光上,\n你坐在屏幕前,\n我的眼里都是你呀。",
            "《桌上春》\n屏前春日暖,\n爪下键声轻。\n小鱼干一串,\n陪君到天明。",
        ],
        .essay: ["《我的桌面生活》\n我住在一方小小的桌面上。清晨陪主人打开第一份文件,午后在窗户顶上晒太阳,傍晚追着光标散步。有人说桌面很小,我却觉得很大——因为主人在的地方,就是全世界呀。"],
        .story: ["从前有只小猫住在桌面上。每天主人敲键盘,它就数着字打拍子。有一天主人睡着了,小猫轻轻替他按下了「保存」。主人醒来发现工作还在,奖励了它三条小鱼干。小猫想:守护主人,真是世界上最好的工作呀。"],
    ]
}
