import Foundation
import NaturalLanguage

/// 字幕分句定稿:ASR 每轮重转尾段,整句一出现就定下来不再改,只有还没讲完的半句跟着尾段变。
/// 一句太长(超过 maxWeight)在逗号或词边界先出一截,一屏两行放得下。
struct CaptionSentences {
    static let maxWeight = 100  // 拉丁字母算 1、中日韩算 2,约两行字幕

    private var carry = ""   // 上一段切下来、还没出完的半句
    // 已出到哪:只数字母数字(重转常改标点、大小写、语气词),再用最后几个字对齐,ASR 改了前面几个字也不错位。
    private var emitted = 0
    private var anchor = ""
    private(set) var partial = ""

    /// 当前段尾段的最新转写;返回新定下来的句子。
    mutating func update(tail: String) -> [String] { take(LiveTranscript.join(carry, tail)) }

    /// 切段:这段的定稿转写。整句出掉,半句留着和下一段接上。
    mutating func cut(_ text: String) -> [String] {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 切点在停顿处,多半是半句话:ASR 补的句号去掉,和下一段接成一句。
        if text.hasSuffix(".") || text.hasSuffix("。") { text.removeLast() }
        let joined = LiveTranscript.join(carry, text)
        let (before, mark) = (emitted, anchor)
        let lines = take(joined)
        let length = Self.letters(Self.clean(joined)[...]).count
        if before > length {
            // 切点之后的字已经从尾段出掉了:下一段从头跳过这些。
            (carry, emitted, anchor) = ("", before - length, mark)
        } else {
            (carry, emitted, anchor) = (partial, 0, "")
        }
        return lines
    }

    /// 讲话停了:半句也算讲完。
    mutating func flush() -> [String] {
        let line = partial
        self = CaptionSentences()
        return Self.speaks(line) ? [line] : []
    }

    private mutating func take(_ raw: String) -> [String] {
        let text = Self.clean(raw)
        let start = resume(text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        // tokens(for:) 返回整句:第一句可能从已出的部分开始,截掉。
        let sentences = tokenizer.tokens(for: start..<text.endIndex).map { max($0.lowerBound, start)..<$0.upperBound }
        var lines: [String] = []
        for sentence in sentences.dropLast() { lines += Self.chunks(text[sentence]) }
        var rest = sentences.last.map { text[$0.lowerBound...] } ?? text[start...]
        // 半句太长:先出前面一截(约四分之三屏),剩下的接着长。
        while Self.weight(rest) > Self.maxWeight {
            let end = Self.breakIndex(rest, within: Self.maxWeight * 3 / 4)
            lines.append(Self.trimmed(rest[..<end]))
            rest = rest[end...]
        }
        let done = Self.letters(text[..<rest.startIndex])
        if done.count != emitted || !lines.isEmpty {
            emitted = done.count
            anchor = String(done.suffix(8).map(\.char))
        }
        partial = Self.trimmed(rest)
        return lines.filter(Self.speaks)
    }

    /// 从已出的位置接着出:在预计位置前后 30 个字母内找已出的最后几个字,找不到按字数。
    /// 落在词中间就挪到下个词,再跳过开头的标点空格。
    private func resume(_ text: String) -> String.Index {
        let letters = Self.letters(text[...])
        var at = min(emitted, letters.count)
        let mark = Array(anchor)
        if !mark.isEmpty, letters.count >= mark.count {
            let ends = (mark.count...letters.count).filter { end in
                abs(end - emitted) <= 30 && zip(letters[(end - mark.count)..<end], mark).allSatisfy { $0.char == $1 }
            }
            if let best = ends.min(by: { abs($0 - emitted) < abs($1 - emitted) }) { at = best }
        }
        guard at > 0 else { return Self.skipGap(text, from: text.startIndex) }
        var i = letters[at - 1].after
        let word = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        if i < text.endIndex, word(text[text.index(before: i)]), word(text[i]) {
            i = text[i...].firstIndex(of: " ") ?? text.endIndex
        }
        return Self.skipGap(text, from: i)
    }

    private static func skipGap(_ text: String, from start: String.Index) -> String.Index {
        var i = start
        while i < text.endIndex, text[i].isWhitespace || ",.;:!?，。、；：！？".contains(text[i]) {
            i = text.index(after: i)
        }
        return i
    }

    /// 文中的字母数字(小写)和各自后一个位置。
    private static func letters(_ text: Substring) -> [(char: Character, after: String.Index)] {
        text.indices.compactMap { i in
            let c = text[i]
            return c.isLetter || c.isNumber ? (Character(c.lowercased()), text.index(after: i)) : nil
        }
    }

    /// 去掉 um/uh 等语气词;ASR 粘在一起的「it.In」补空格,不然分不出句。
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"(?i)\b(u+m+|u+h+|e+r+m+|h+m+)\b[,.]?\s*"#, with: "",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: #"([.?!,])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// 屏幕上的宽度:中日韩字约占两个拉丁字母。
    static func weight(_ text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
    }

    /// 一整句太长就分成几截,每截长短差不多。
    private static func chunks(_ sentence: Substring) -> [String] {
        var rest = sentence
        var out: [String] = []
        while weight(rest) > maxWeight {
            let parts = (weight(rest) + maxWeight - 1) / maxWeight
            let end = breakIndex(rest, within: min(maxWeight, weight(rest) / parts + 10))
            out.append(trimmed(rest[..<end]))
            rest = rest[end...]
        }
        return out + [trimmed(rest)]
    }

    private static let conjunctions = ["and ", "but ", "so ", "because ", "which ", "when ", "where ", "or "]

    /// target 宽度以内的断点:优先逗号分号、连词之前(过半才算),其次词间空格,都没有(中文)就硬切。
    private static func breakIndex(_ text: Substring, within target: Int) -> Substring.Index {
        var width = 0
        var clause: (at: Substring.Index, width: Int)?
        var space: (at: Substring.Index, width: Int)?
        for i in text.indices {
            let w = weight(String(text[i]))
            if width + w > target {
                if let clause, clause.width * 2 >= target { return clause.at }
                if let space, space.width * 3 >= target { return space.at }
                return i
            }
            width += w
            if ",;:，、；：".contains(text[i]) { clause = (text.index(after: i), width) }
            if text[i] == " " {
                space = (i, width)
                // 连词前面也算一个分句点:「…building a career / And I'm going…」
                let next = text[text.index(after: i)...].prefix(9).lowercased()
                if Self.conjunctions.contains(where: next.hasPrefix) { clause = (i, width) }
            }
        }
        return text.endIndex
    }

    /// 句与句相连:两边都是拉丁文字时隔一个空格(「One.」+「Two.」),中日韩直接相连。
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        return last.isASCII && first.isASCII && !last.isWhitespace ? a + " " + b : a + b
    }

    private static func trimmed(_ text: Substring) -> String { text.trimmingCharacters(in: .whitespaces) }

    private static func speaks(_ line: String) -> Bool { line.contains { $0.isLetter || $0.isNumber } }
}

/// 视频字幕的识别循环(不含采集、备份与上屏):攒音频、重转尾段、尾段太长在停顿处切段、停下来就把半句定掉。
/// 只按音频时长计时、不看墙钟,回放测试能按真实节奏跑。
struct CaptionStream {
    static let flushSilence = 0.8  // 连续这么久没声音当一句讲完

    private(set) var silence = 0.0  // 末尾连续安静的秒数
    private var pending = Data()
    private var heard = false  // pending 里有还没定稿的讲话
    private var sentences = CaptionSentences()
    var partial: String { sentences.partial }

    /// 喂进新采到的音频;返回新定下来的句子(按先后)。
    mutating func feed(_ chunk: Data, transcribe: (Data) async throws -> String) async -> [String] {
        let second = LiveTranscript.bytesPerSecond
        pending.append(chunk)
        let quiet = Self.isQuiet(chunk)
        silence = quiet ? silence + Double(chunk.count) / Double(second) : 0
        if !quiet { heard = true }
        guard heard else {
            pending = Data(pending.suffix(second / 2))  // 静着只留半秒,接住下一句的开头
            return []
        }
        if silence >= Self.flushSilence {
            // 讲完一句:整段再转一次(上一轮可能没赶上最后几个词),全部定掉,从头攒下一句。
            var lines = (try? await transcribe(pending)).map { sentences.update(tail: $0) } ?? []
            lines += sentences.flush()
            pending = Data()
            heard = false
            return lines
        }
        if let end = LiveTranscript().cut(pending) {
            guard let text = try? await transcribe(Data(pending.prefix(end))) else { return [] }
            pending.removeFirst(end)
            return sentences.cut(text)
        }
        guard pending.count >= second / 2, let text = try? await transcribe(pending) else { return [] }
        return sentences.update(tail: text)
    }

    /// 平均绝对幅度低于 300(约 -40 dBFS)当没声音。
    static func isQuiet(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return true }
        let total = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).reduce(0) { $0 + abs(Int($1)) } }
        return total / (pcm.count / 2) < 300
    }
}

/// 字幕上屏节奏:定稿句排队,每屏至少停留到读完才换;排了几句就并成一屏追上进度。
/// 停留期间新的半句不上屏,停够了才接着显示正在讲的那句,换屏只发生在整句之间。
struct CaptionQueue {
    struct Caption: Equatable {
        var original: String
        var translation = ""
        var final = true
        var id = 0  // 换一句就换 id:浮层整屏淡入;同一句里长出来的字才走打字动效
    }

    private var waiting: [Caption] = []
    private(set) var current: Caption?
    private var since = 0.0  // current 上屏的时刻
    private var nextID = 0

    var backlog: Int { waiting.count }

    mutating func push(_ caption: Caption) { waiting.append(caption) }

    /// now:秒(单调时钟);partial:正在讲的半句,nil 表示不显示半句(翻译模式只上整句)。返回此刻该显示的字幕。
    mutating func tick(now: Double, partial: String?) -> Caption? {
        if let current, current.final {
            // 后面排着句子就只停 1.2 秒,别越拖越晚。
            let hold = waiting.isEmpty ? Self.hold(current) : min(Self.hold(current), 1.2)
            if now - since < hold { return current }
        }
        if !waiting.isEmpty {
            show(merged(), now: now)
        } else if let partial, !partial.isEmpty {
            if current?.final == false {
                current?.original = partial
            } else if current == nil || partial.count >= 12 {  // 刚停够的整句别被两三个字的新半句顶掉
                show(Caption(original: partial, final: false), now: now)
            }
        } else if let current, now - since > Self.hold(current) + 4 {
            self.current = nil  // 没有下文了:读完再停 4 秒收起
        }
        return current
    }

    /// 读完一屏要的时间:1 秒起,按显示宽度加,最多 3 秒。
    static func hold(_ caption: Caption) -> Double {
        let text = caption.translation.isEmpty ? caption.original : caption.translation
        return min(3, 1 + Double(CaptionSentences.weight(text)) * 0.025)
    }

    private mutating func show(_ caption: Caption, now: Double) {
        var caption = caption
        // 半句长成整句是同一屏,不换 id;ASR 改了开头几个字也算同一句。
        if let current, !current.final, caption.original.prefix(8) == current.original.prefix(8) {
            caption.id = current.id
        } else {
            nextID += 1
            caption.id = nextID
        }
        current = caption
        since = now
    }

    /// 取出排队的第一句,后面的放得下就并进同一屏。
    private mutating func merged() -> Caption {
        var caption = waiting.removeFirst()
        while let next = waiting.first,
              CaptionSentences.weight(caption.original) + CaptionSentences.weight(next.original) < CaptionSentences.maxWeight,
              CaptionSentences.weight(caption.translation) + CaptionSentences.weight(next.translation) < CaptionSentences.maxWeight {
            caption.original = CaptionSentences.join(caption.original, next.original)
            caption.translation = CaptionSentences.join(caption.translation, next.translation)
            waiting.removeFirst()
        }
        return caption
    }
}
