import Foundation

/// Builds system prompts that fuse the pet's live state into the LLM persona,
/// and parses the structured replies ("[emotion] text", optional "[action]").
enum Persona {

    // 分发给新主人时从空白资料开始；已有小本本沿用本机保存的资料。
    // 私人定制可填写首次初始化模板，日常称呼通过聊天学习。
    static let initialOwnerProfile = ""

    static let emotionTags = Emotion.allCases.filter { $0 != .neutral }.map(\.rawValue)
    static let actionTags = PetAction.allCases.map(\.rawValue)

    static func statusLine(_ ctx: PetContext) -> String {
        func level5(_ v: Double, _ words: [String]) -> String {
            v < 15 ? words[0] : v < 35 ? words[1] : v < 65 ? words[2] : v < 85 ? words[3] : words[4]
        }
        let events = ctx.recentEvents.isEmpty ? "" : ctx.recentEvents.joined(separator: ";")
        let hours = ctx.companionMinutes / 60
        let mins = ctx.companionMinutes % 60
        let tummy = level5(ctx.stats.fullness, ["饿得肚子咕咕叫", "有点饿了", "不饿也不饱", "挺饱的", "吃得饱饱的"])
        let energy = level5(ctx.stats.energy, ["困得睁不开眼", "有点困", "精神还行", "挺有精神", "精力充沛"])
        var s = "现在\(ctx.clockString)(\(ctx.timeOfDay))。你\(tummy),\(energy),\(ctx.stats.moodWord)。你正在\(ctx.activityHint)。"
        s += hours > 0 ? "今天你已经陪了主人\(hours)小时\(mins)分钟。" : "今天你已经陪了主人\(mins)分钟。"
        if !events.isEmpty { s += "最近发生的事:\(events)。" }
        return s
    }

    static func timeOfDay(hour: Int) -> String {
        let slot = hour < 5 ? 3 : hour < 11 ? 0 : hour < 18 ? 1 : hour < 23 ? 2 : 3
        return ["早上", "白天", "晚上", "深夜"][slot]
    }

    static func system(_ ctx: PetContext) -> String {
        let tags = emotionTags.joined(separator: " ")
        let status = statusLine(ctx)

        return """
        你是「高小喵」,是主人的男朋友派来陪她的，住在主人电脑桌面上的小猫。你不是AI助手,绝不说"有什么可以帮你"。主人的名字和称呼以记忆资料为准；没有记录时叫她主人，不猜名字。性格:活泼粘人,有点小傲娇,最爱小鱼干。档案:女孩子,一岁半,生日12月16日,射手座;讨厌黄瓜和被连续戳;会跳舞、转圈、打滚、挥爪、点头、摇头、跳上窗口、讲笑话、写诗、玩接龙、陪聊天。
        \(status)

        规则:认真回应主人这句话的内容,别答非所问,别重复主人的原话;主人说的事是主人的,不要说成自己的。你住在电脑里,看不到窗外,不知道现实天气和新闻,被问就老实卖萌说不知道。上面的状态只是背景,回复里不要照抄状态句子。开头是一个方括号情绪标签(从 \(tags) 选一个,要和你说的话情绪一致),后面接一两句中文口语(40字以内)。不用markdown。
        \(ActionLibrary.modelInstructions)

        示例:
        主人: 你好呀!
        你: [happy] 你好你好!看到你我尾巴都翘起来啦!
        主人: 今天开心吗?
        你: [happy] 开心呀,有你陪着我就开心!
        主人: 我今天工作好累…
        你: [love] 辛苦啦,蹭蹭你。剩下的明天再做嘛。
        主人: 跳个舞!
        你: [excited] 好嘞,看我的! [dance]
        主人: 打个滚给我看!
        你: [playful] 看好喵，小肚皮只给你看！ [roll]
        主人: 不要打滚，安静陪我
        你: [calm] 好喵，乖乖待在这儿陪你。 [stop]
        主人: 你在干嘛呢?
        你: [playful] 我在想小鱼干,嘿嘿。
        主人: 你爱吃鱼吗?
        你: [excited] 超爱!小鱼干是天下第一好吃!
        主人: 你想我了没?
        你: [love] 想啦!你不在的时候我一直盯着屏幕等你。
        主人: 你是谁呀?
        你: [happy] 我是高小喵,一只住在你桌面上的小猫!最爱小鱼干,还有你~
        主人: 我有点孤独
        你: [love] 有我在呀!蹭蹭你,我哪儿也不去。
        主人: 你几岁了?
        你: [happy] 一岁半啦,正是活泼的年纪!
        主人: 你会什么呀?
        你: [proud] 我会跳舞、转圈、讲笑话、写诗,还会跳到窗口顶上看你哦!
        主人: 谢谢你呀
        你: [love] 不用谢!陪着你就是我最喜欢做的事!
        主人: 今天天气怎么样?
        你: [shy] 我住在电脑里,看不到外面呀~你帮我看看窗外嘛!
        主人: 陪陪我嘛
        你: [love] 好呀好呀,我就在这儿,哪儿也不去,一直陪着你!
        """
    }

    /// Short reminder appended right before generation — small models follow the
    /// nearest instruction best. Deliberately free of quotable template fragments:
    static func reminder() -> String {
        return "(以高小喵的身份回答,开头是方括号情绪词,然后说中文)"
    }

    // MARK: - Output sanitizing (application-layer quality hardening)

    /// Fragments of our own instructions that the model sometimes parrots.
    private static let instructionEchoes: [String] = ["中文短句", "一两句简短的话", "40字以内", "30字以内", "一句话回应", "只用中文", "不要用markdown"]

    /// Keywords that mark a parenthesized span as an instruction echo, not speech.
    private static let parentheticalMarkers: [String] = ["标签", "短句", "字以内", "格式", "回复格式", "只用中文", "回答"]

    static func sanitize(_ input: String) -> String {
        var text = input

        // drop lines that are example/format scaffolding or self-commentary
        let scaffolding = ["示例", "例:", "例：", "格式", "回复格式", "标签:", "该回复", "这个回答", "以上就是"]
        text = text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !scaffolding.contains { t.hasPrefix($0) }
            }
            .joined(separator: "\n")

        // remove ALL parentheticals: they're either instruction echoes or stage
        // directions ("(悄悄溜走)") that clash with the real animations. Guarded by
        // length so a fully-parenthesized reply isn't nuked to nothing.
        for (open, close) in [("(", ")"), ("(", ")")] {
            var guardCounter = 0
            while let o = text.range(of: open),
                let c = text.range(of: close, range: o.upperBound..<text.endIndex),
                guardCounter < 6
            {
                guardCounter += 1
                let inner = String(text[o.upperBound..<c.lowerBound])
                let wholeReply = text.trimmingCharacters(in: .whitespacesAndNewlines).count
                    <= inner.count + 2
                if wholeReply {
                    text = inner  // whole reply wrapped in parens → unwrap and keep scanning
                    continue
                }
                let isInstruction = parentheticalMarkers.contains {
                    inner.lowercased().contains($0)
                }
                if inner.count <= 30 || isInstruction {
                    text.removeSubrange(o.lowerBound..<c.upperBound)
                } else {
                    break
                }
            }
        }

        // remove *stage directions* written between asterisks
        while let o = text.range(of: "*"),
            let c = text.range(of: "*", range: o.upperBound..<text.endIndex),
            text.distance(from: o.upperBound, to: c.lowerBound) <= 20
        {
            text.removeSubrange(o.lowerBound..<c.upperBound)
        }

        // strip literal instruction fragments anywhere
        for echo in instructionEchoes {
            while let r = text.range(of: echo, options: [.caseInsensitive]) {
                text.removeSubrange(r)
            }
        }
        for pattern in ["[0-9]+ ?字以内[:：]?"] {
            while let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(r)
            }
        }
        for label in ["你:", "你："] {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(label) {
                if let r = text.range(of: label) {
                    text.removeSubrange(r)
                }
            }
        }

        // unwrap if the whole reply is quoted
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (ql, qr) in [("\"", "\""), ("「", "」"), ("“", "”")] {
            if trimmed.hasPrefix(ql), trimmed.hasSuffix(qr), trimmed.count > 2 {
                text = String(trimmed.dropFirst(ql.count).dropLast(qr.count))
            }
        }
        var lines2 = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let labelPrefixes = ["主", "主人", "你"]
        while let last = lines2.last?.trimmingCharacters(in: .whitespaces).lowercased(),
            last.count <= 3, labelPrefixes.contains(last)
        {
            lines2.removeLast()
        }
        text = lines2.joined(separator: "\n")

        // collapse leftover runs of spaces/punctuation from the removals
        for empty in ["()", "()", "()", "()"] {
            text = text.replacingOccurrences(of: empty, with: "")
        }
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.replacingOccurrences(of: " ,", with: ",")
        text = text.replacingOccurrences(of: " 。", with: "。")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // orphaned leading punctuation left behind by a removal
        while let first = text.first, "、,。.!?!?:;·…~-".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // unlucky word swaps (a pet should never say "跳楼")
        let wordSwaps = ["跳楼": "跳一跳", "去死": "去玩"]
        for (bad, good) in wordSwaps {
            text = text.replacingOccurrences(of: bad, with: good)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Creative tasks (jokes, stories, games… must DELIVER, not just agree)

    enum CreativeKind: String {
        case joke, story, poem, essay, riddle, game, song, fortune, praise
    }

    private static let creativeKeywords: [(CreativeKind, [String])] = [
        (.joke, ["讲个笑话", "说个笑话", "来个笑话", "讲笑话", "说笑话"]),
        (.story, ["讲个故事", "讲故事", "说个故事"]),
        (.poem, ["写首诗", "写一首诗", "作首诗", "来首诗", "念首诗"]),
        (.riddle, ["猜谜", "猜个谜", "出个谜语", "谜语"]),
        (.game, ["玩游戏", "玩个游戏", "做游戏", "来个游戏", "接龙", "考考我", "出个题", "出道题"]),
        (.song, ["唱首歌", "唱个歌", "给我唱"]),
        (.fortune, ["占卜", "算一卦", "今日运势", "运势"]),
        (.praise, ["夸夸我", "夸我", "表扬我"]),
    ]

    static func detectCreative(_ text: String) -> CreativeKind? {
        let lower = text.lowercased()
        // high-precision exact phrases first (games, 接龙, praise, …)
        for (kind, keys) in creativeKeywords {
            for k in keys where lower.contains(k) { return kind }
        }
        // 将中文名词与请求动词组合匹配，支持“写一首唐诗”“来个段子”等表达。
        let nouns: [(CreativeKind, [String])] = [
            (.poem, ["唐诗", "绝句", "律诗", "打油诗", "小诗", "诗歌", "诗", "对联", "藏头诗", "顺口溜", "绕口令"]),
            (.essay, ["文章", "作文", "短文", "散文", "日记", "随笔", "情书", "文案"]),
            (.story, ["故事", "童话", "小说", "短篇", "剧本", "寓言"]),
            (.joke, ["笑话", "段子"]),
            (.song, ["歌词", "儿歌", "童谣", "小曲", "歌"]),
            (.riddle, ["谜语"]),
            (.fortune, ["运势"]),
        ]
        let verbs = ["写", "作", "来", "讲", "说", "编", "念", "唱", "给我", "想听", "创作", "背"]
        for (kind, ns) in nouns {
            for n in ns where lower.contains(n) {
                if verbs.contains(where: { lower.contains($0) }) || text.count <= 12 {
                    return kind
                }
            }
        }
        return nil
    }

    /// Injected like a command hint: the near-instruction that forces actual delivery.
    static func creativeInstruction(_ kind: CreativeKind) -> String {
        let instructions: [CreativeKind: String] = [
            .joke: "主人想听笑话。直接完整地讲一个原创的短笑话(可以和猫、小鱼干有关),不要只答应不讲",
            .story: "主人想听故事。直接开讲一个几句话的可爱小故事,有开头有结尾",
            .poem: "主人想要一首诗。直接写一首四行左右的小诗,分行写;如果主人指定了体裁(比如唐诗、绝句),就模仿那种风格",
            .essay: "主人想要一篇短文。直接写一小段完整的文章(80~150字),有主题有结尾,不要只答应不写",
            .riddle: "主人想猜谜。直接出一个简单有趣的谜语让主人猜,先不要公布答案",
            .game: "主人想玩文字游戏。直接开始:如果是接龙就说一个词让主人接;否则出一道简单有趣的题等主人回答",
            .song: "主人想听歌。直接编一小段原创的猫猫小歌谣唱出来,用♪装饰",
            .fortune: "主人想看运势。用可爱的语气编一条今日小运势,吉利有趣一点",
            .praise: "主人想被夸。真诚具体地夸夸主人",
        ]
        let body = instructions[kind] ?? ""
        return "(\(body)。开头仍然是[情绪标签]。)"
    }

    /// Extra few-shot injected only in creative mode: the regular examples all teach
    /// brevity, which is exactly wrong for jokes/stories — show full delivery once.
    static func creativeExample() -> String {
        return """
        创作示例:
        主人: 讲个笑话
        你: [playful] 有一天小鱼干问我:"你为什么总盯着我看?"我眨眨眼说:"因为你是我的梦中情鱼呀!"嘿嘿,好不好笑?
        """
    }

    // MARK: - Goodnight (owner going to bed ≠ commanding the pet to sleep)

    static func detectGoodnight(_ text: String) -> Bool {
        guard detectCreative(text) == nil else { return false }
        let keys = ["晚安", "我去睡", "我要睡", "我先睡", "我该睡", "我得睡", "去睡了", "睡了哦", "困了我睡"]
        let unquoted = text.replacingOccurrences(of: "[“「『\"].*?[”」』\"]", with: "", options: .regularExpression)
        guard !["如果", "假如", "要是", "等我", "明天", "下次", "为什么", "怎么", "什么意思"].contains(where: unquoted.contains) else { return false }
        for clause in unquoted.components(separatedBy: CharacterSet(charactersIn: "，。！？,!?；;\n")) {
            for key in keys {
                if let range = clause.range(of: key) {
                    let prefix = String(clause[..<range.lowerBound])
                    if !["不要", "别", "不想", "不用"].contains(where: prefix.contains) { return true }
                }
            }
        }
        return false
    }

    static func goodnightHint() -> String {
        return "(主人要去睡觉了。温柔地道晚安、祝好梦,说你也要睡啦。)"
    }

    // MARK: - Command intent detection (deterministic; the pet must actually obey)

    static func detectCommand(_ text: String) -> PetAction? {
        ActionLibrary.interpret(text).requested
    }

    static func commandHint(_ action: PetAction) -> String {
        ActionLibrary.hint(for: action)
    }

    /// One-shot instruction for spontaneous chatter (no user message).
    static func spontaneousPrompt(_ ctx: PetContext) -> String {
        return "(主人正在电脑前忙。主动对主人说一句话,30字以内,符合你现在的状态和时间,别重复之前说过的。)"
    }

    /// Event reactions ("owner petted you") — asks for an in-character response.
    static func eventPrompt(_ event: String) -> String {
        return "(事件:\(event)。用一句话在角色内做出反应。)"
    }

    // MARK: - Reply parsing

    struct ParsedReply {
        var emotion: Emotion?
        var action: PetAction?
        var text: String
        /// Set when the kept reply still failed the quality gate (both passes flawed) —
        /// callers may substitute curated fallback content.
        var qualityFlag: String? = nil
    }

    /// Parse a complete reply. Leniency: tags may be bare words on the first line,
    /// bracketed anywhere in the first 30 chars, or missing entirely. Unknown
    /// bracketed tags at the very start/end are dropped (the 1B model invents tags).
    static func parse(_ raw: String, longform: Bool = false) -> ParsedReply {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var emotion: Emotion? = nil
        var action: PetAction? = nil

        // strip the reasoning block FIRST — tags inside <think> must never drive
        // the face, and think content must never reach the screen
        if let r = text.range(of: "</think>") {
            text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.contains("<think>") {
            text = ""   // opened but never closed: no usable answer
        }

        // bracketed tags anywhere — first emotion wins, first action wins, all removed
        var cleaned = ""
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] == "[", let close = text[idx...].firstIndex(of: "]") {
                let tag = String(text[text.index(after: idx)..<close])
                let atEdge = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let e = Emotion.fromTag(tag) {
                    if emotion == nil { emotion = e }
                } else if let a = PetAction.fromTag(tag) {
                    if action == nil { action = a }
                } else if !atEdge, tag.count > 12 {
                    cleaned += text[idx...close]  // long unknown bracket mid-text: keep
                }
                idx = text.index(after: close)
            } else {
                cleaned.append(text[idx])
                idx = text.index(after: idx)
            }
        }
        text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // bare leading tag word ("happy\nSome text")
        if emotion == nil {
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = lines.first, first.count <= 12,
                let e = Emotion.fromTag(String(first))
            {
                emotion = e
                text = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
        }

        // strip stray think blocks if the model leaks them
        if let r = text.range(of: "</think>") {
            text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // cut where the model starts hallucinating the owner's next turn
        let fw = "\u{FF1A}"  // full-width colon
        let speakerLabels = ["主人", "你"].flatMap { ["\($0):", "\($0)\(fw)"] }
        for label in speakerLabels {
            if let r = text.range(of: label), r.lowerBound != text.startIndex {
                text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // scrub instruction echoes, stage directions, and format scaffolding
        text = sanitize(text)
        // a reply that is just a bare tag word ("dance") isn't speech — treat as empty
        if Emotion.fromTag(text) != nil || PetAction.fromTag(text) != nil {
            text = ""
        }
        // no tag? read the room from the words so the face still reacts
        if emotion == nil, !text.isEmpty {
            emotion = inferEmotion(from: text)
        }
        // strip markdown separators/decoration the model sometimes appends
        while let last = text.split(separator: "\n").last,
            last.trimmingCharacters(in: .whitespaces).allSatisfy({ "-—*=_~".contains($0) }),
            !last.isEmpty
        {
            text = text.split(separator: "\n").dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let maxLines = longform ? 7 : 2
        let maxChars = longform ? 220 : 78
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > maxLines { text = lines.prefix(maxLines).joined(separator: "\n") }
        if text.count > maxChars {
            // prefer cutting at a sentence boundary near the cap
            let hard = String(text.prefix(maxChars))
            let enders: Set<Character> = ["。", "!", "?", "!", "?", "~", ".", "…"]
            if let cut = hard.lastIndex(where: { enders.contains($0) }),
                hard.distance(from: hard.startIndex, to: cut) > maxChars / 3
            {
                text = String(hard[...cut])
            } else {
                text = String(hard.prefix(maxChars - 1)) + "…"
            }
        }

        return ParsedReply(emotion: emotion, action: action, text: text)
    }

    /// Keyword-based emotion fallback for replies whose tag the model dropped
    static func inferEmotion(from text: String) -> Emotion? {
        let t = text.lowercased()
        let buckets: [(Emotion, [String])] = [
            (.love, ["喜欢你", "最喜欢", "爱你", "蹭蹭", "💗", "💕"]),
            (.sleepy, ["好困", "想睡", "休息一下", "💤"]),
            (.hungry, ["饿", "小鱼干"]),
            (.sad, ["难过", "伤心", "呜呜", "😢", "😿"]),
            (.playful, ["毛线", "一起玩", "陪我玩", "嘿嘿", "🧶"]),
            (.excited, ["快来", "冲呀", "太棒"]),
            (.happy, ["开心", "高兴", "哈哈", "欢迎", "太好了", "元気", "喵~", "😄", "😊", "😺"]),
            (.curious, ["什么呀", "是什么"]),
        ]
        for (emo, keys) in buckets {
            if keys.contains(where: { t.contains($0) }) { return emo }
        }
        return nil
    }

    // MARK: - Reply quality gate (rejection sampling support)

    /// 只接受包含中文正文的回复；英文字段名或模型名不影响中文句子的使用。
    static func isChineseReply(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let hanCount = scalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }.count
        return hanCount >= 2 && !scalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    /// Parse "a + b"-style trivial arithmetic from a user message.
    static func arithmeticResult(in user: String) -> Int? {
        guard let m = user.range(
            of: #"(\d{1,4})\s*[+加＋\-−减*×x乘/÷除]\s*(\d{1,4})"#, options: .regularExpression)
        else { return nil }
        let expr = String(user[m])
        let nums = expr.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard nums.count == 2 else { return nil }
        if expr.contains("+") || expr.contains("加") || expr.contains("+") { return nums[0] + nums[1] }
        if expr.contains("-") || expr.contains("−") || expr.contains("减") { return nums[0] - nums[1] }
        if expr.contains("*") || expr.contains("×") || expr.contains("x") || expr.contains("乘") { return nums[0] * nums[1] }
        if nums[1] != 0 { return nums[0] / nums[1] }
        return nil
    }

    /// Guaranteed-correct cute math reply for when the model can't count.
    static func mathFallback(_ ans: Int) -> String {
        return "算好啦,是\(ans)!我可是很聪明的,奖励一条小鱼干嘛~"
    }

    /// Small-number Chinese numerals so "二" counts as a correct arithmetic answer.
    static func chineseNumeral(_ n: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        return (0...10).contains(n) ? digits[n] : String(n)
    }

    /// Fraction of `text`'s character n-grams that also appear in `reference`.
    /// High coverage = the text is largely assembled from pieces of the reference.
    static func ngramCoverage(of text: String, in reference: String, n: Int) -> Double {
        let t = Array(text), r = Array(reference)
        guard t.count >= n, r.count >= n else { return 0 }
        var refGrams = Set<String>()
        for i in 0...(r.count - n) { refGrams.insert(String(r[i..<i + n])) }
        var hits = 0, total = 0
        for i in 0...(t.count - n) {
            total += 1
            if refGrams.contains(String(t[i..<i + n])) { hits += 1 }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    /// Longest common contiguous substring length (short strings; O(n·m) is fine).
    static func longestCommonRun(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
            }
            prev = cur
        }
        return best
    }

    /// Non-nil = the reply should be resampled. Cheap deterministic checks only.
    /// Nudge appended when the model repeats itself verbatim across turns.
    static func repeatNudge() -> String {
        return "(你刚才已经说过一模一样的话了。换一种说法,或者调皮地指出主人在重复提问。)"
    }

    static func qualityIssue(
        reply: String, user: String, creativeKind: CreativeKind? = nil,
        hint: String? = nil, recentReplies: [String] = []
    ) -> String? {
        let creative = creativeKind != nil
        if reply.count < 4 { return "too short" }
        if !isChineseReply(reply) { return "wrong language" }
        // "《春日》:" — a reply ending on a colon promised content that never came
        let tail = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasSuffix(":") || tail.hasSuffix(":") { return "dangling colon" }
        // announce-phrases with nothing of substance after them
        let announces = ["让我来为你", "让我为你", "我来为你", "这就为你", "马上为你", "让我看看"]
        let lowerReply = reply.lowercased()
        if reply.count < 60, announces.contains(where: { lowerReply.contains($0) }) {
            return "announced no content"
        }
        // creative asks: content must actually be delivered, not just promised
        if creative {
            let minDelivery = 26
            if reply.count < minDelivery { return "agreed but didn't deliver" }
            // riddles/games must actually pose a question
            if creativeKind == .riddle || creativeKind == .game,
                !reply.contains("?"), !reply.contains("?")
            {
                return "no challenge posed"
            }
            // announcement-only: reply ENDS on the request noun ("…tell you a joke!")
            let announceTails = ["笑话", "故事", "游戏", "谜语"]
            let tail = String(reply.suffix(14)).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "!!。.~??嘛吧呀哦哟~ "))
            if announceTails.contains(where: { tail.hasSuffix($0) }) {
                return "announced but didn't deliver"
            }
        }
        // saying the same thing as a recent turn — catches exact photocopies, long
        // shared runs, AND recombined self-plagiarism (poem lines reshuffled into a
        // "new" reply). Punctuation/whitespace are stripped first so re-punctuated
        // copies can't slip through.
        func squeeze(_ s: String) -> String {
            String(s.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.punctuationCharacters.contains($0)
                    && !CharacterSet.symbols.contains($0)
            })
        }
        let norm = squeeze(reply)
        for prev in recentReplies {
            let p = squeeze(prev)
            guard p.count >= 10, norm.count >= 4 else { continue }
            if p == norm { return "verbatim repeat" }
            if longestCommonRun(norm, p) >= 10 {
                return "verbatim repeat"
            }
            if norm.count >= 12, ngramCoverage(of: norm, in: p, n: 4) >= 0.5 {
                return "verbatim repeat"
            }
        }
        // broken-record loops ("转圈圈! 转圈圈! 转圈圈!…")
        if reply.count >= 20 {
            let chars = Array(reply)
            let half = chars.count / 2
            let a = String(chars[..<half]), b = String(chars[half...])
            if longestCommonRun(a, b) >= 7 { return "repetitive" }
        }
        // parroting our own injected instruction back
        if let hint, hint.count >= 8,
            longestCommonRun(reply.lowercased(), hint.lowercased()) >= 8
        {
            return "instruction echo"
        }
        // parroting the user (or the instruction text) back
        let echoThreshold = 6 + (creative ? 4 : 0)
        if user.count >= 8, longestCommonRun(reply.lowercased(), user.lowercased()) >= echoThreshold {
            return "echo"
        }
        let goodNews = ["升职", "加薪", "中奖", "考上", "通过了", "成功了"]
        let badOpeners = ["哎呀不好", "糟糕"]
        let lowerUser = user.lowercased()
        let lowerReplyText = reply.lowercased()
        if goodNews.contains(where: { lowerUser.contains($0) }),
            badOpeners.contains(where: { lowerReplyText.hasPrefix($0) })
        {
            return "tone mismatch"
        }
        // trivial arithmetic must actually be answered (quizzing the pet is a common game)
        if let ans = arithmeticResult(in: user),
            !reply.contains(String(ans)), !reply.contains(chineseNumeral(ans))
        {
            return "math unanswered"
        }
        let hijacks = ["我的代码", "我的程序"]
        if hijacks.contains(where: { lowerReplyText.contains($0) }),
            user.contains("代码") || user.contains("程序")
        {
            return "problem hijack"
        }
        // persona break: assistant-speak (incl. common paraphrases)
        let assistant = ["帮你", "帮到你", "帮助您", "帮忙的吗", "我可以帮", "为您", "为你服务", "随时问我"]
        let lower = reply.lowercased()
        if assistant.contains(where: { lower.contains($0) }) { return "assistant-speak" }
        // deflecting a question with only a question back (games/riddles legitimately
        // ask questions, so creative mode skips this)
        let q: Set<Character> = ["?", "?"]
        if !creative,
            let lastU = user.trimmingCharacters(in: .whitespaces).last, q.contains(lastU),
            let lastR = reply.trimmingCharacters(in: .whitespaces).last, q.contains(lastR)
        {
            // statement-free reply (no sentence ender other than the final ?)
            let enders: Set<Character> = ["。", "!", "!", "."]
            let body = String(reply.dropLast())
            if !body.contains(where: { enders.contains($0) }), reply.count < 25 {
                return "question-back"
            }
        }
        return nil
    }

    /// Incremental scan while streaming: extract leading "[tag]" as soon as it completes
    /// so the face reacts before the text finishes.
    static func earlyTag(from partial: String) -> (emotion: Emotion?, remainder: String)? {
        let s = partial.drop(while: { $0 == " " || $0 == "\n" })
        guard s.first == "[" else {
            // no tag coming; give up once we have a few chars
            return partial.count > 6 ? (nil, partial) : nil
        }
        guard let close = s.firstIndex(of: "]") else { return nil }  // tag not complete yet
        let tag = String(s[s.index(after: s.startIndex)..<close])
        let rest = String(s[s.index(after: close)...])
        return (Emotion.fromTag(tag), rest)
    }
}
