// Clawd 伴随 —— 蹲在鼠须管候选框上的像素小螃蟹
//
// 工作方式：
//   1. lua/clawd.lua 在每次按键后把「是否在输入、光标前的拼音、上屏次数」写进
//      ~/Library/Caches/ClawdCompanion/state
//   2. 本程序监听这个文件；有输入时以 60 帧跟踪鼠须管候选框窗口的位置，
//      用和候选框相同的字体量出光标横坐标，让 Clawd 站在候选框上沿、光标正上方。
//   3. 没在打字时不跑任何定时器，几乎不占 CPU。
//
// 项目主页：https://github.com/yzysiu777/rime-clawd
// 编译：./build.sh（构建通用版 Clawd.app）；./build.sh install / ./build.sh dist

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 颜色

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let PALETTE: [Character: CGColor] = [
    "O": rgb(0xCB7A5D),  // Clawd 身体
    "o": rgb(0xA9644C),  // 身体暗部 / 帽檐阴影 / 扫帚绑绳
    "E": rgb(0x000000),  // 眼睛
    "K": rgb(0x2F2F2D),  // 女巫帽
    "k": rgb(0x4B4B47),  // 帽子高光
    "S": rgb(0x5B3A1B),  // 扫帚杆
    "D": rgb(0x2C1904),  // 扫帚杆暗部
    "Y": rgb(0xE6B464),  // 草穗
    "y": rgb(0xB58643),  // 草穗暗部
    "L": rgb(0xF0DCA2),  // 草穗高光
    "B": rgb(0x7FC4F0),  // 汗珠
    "W": rgb(0xFFFFFF),
    "A": rgb(0xD97757),  // Claude 橙：惊叹号、Zzz
    "H": rgb(0xF0668C),  // 爱心
    "h": rgb(0xD4476F),  // 爱心暗部
    "C": rgb(0x79B4E3),  // 球王装：天蓝条纹
    "g": rgb(0x2F8F5B),  // Siu 装：球衣绿边
    "G": rgb(0x8E8E8E),  // 侧身装拖着的小灰棍
    "R": rgb(0xC9483A),  // 圣诞帽
    "r": rgb(0xA3382E),  // 圣诞帽暗部
    "w": rgb(0xF6F1E7),  // 帽子的绒边、绒球
    "v": rgb(0xD8D0C0),  // 绒边暗部
    "N": rgb(0x6F83BD),  // 睡帽
    "n": rgb(0x566A9E),  // 睡帽暗部
]

// MARK: - 像素精灵（坐标单位：底层像素；Clawd 本体占 24×16）

struct P: Hashable { var x: Int; var y: Int }

struct Sprite {
    var px: [P: Character] = [:]

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Character) {
        guard w > 0, h > 0 else { return }
        for j in y..<(y + h) { for i in x..<(x + w) { px[P(x: i, y: j)] = c } }
    }

    mutating func stamp(_ rows: [String], _ dx: Int, _ dy: Int) {
        for (j, row) in rows.enumerated() {
            for (i, ch) in row.enumerated() where ch != "." { px[P(x: dx + i, y: dy + j)] = ch }
        }
    }

    mutating func merge(_ o: Sprite, dx: Int = 0, dy: Int = 0) {
        for (p, c) in o.px { px[P(x: p.x + dx, y: p.y + dy)] = c }
    }

    /// 以 x = axis2/2 为轴左右镜像
    func mirrored(_ axis2: Int) -> Sprite {
        var s = Sprite()
        for (p, c) in px { s.px[P(x: axis2 - p.x, y: p.y)] = c }
        return s
    }
}

enum Eyes { case open, closed, happy, wide }

struct Pose {
    var look = 0          // -1 往左看，0 正视，1 往右看
    var eyes = Eyes.open
    var legs = 0          // 0 站立；1、2 迈步的两个相位
    var armL = 0, armR = 0  // 0 平举，1 举起
    var sit = false       // 骑扫帚时腿收短
    var breathe = false   // 呼吸：钳子往下沉 1 像素
    var hideEyes = false  // 墨镜装：眼睛被镜片挡住
    var wide = false      // 两腿叉开站（Siu 落地）
    var back = false      // 背对镜头（Siu 空中转身）
    var tap = 0           // 电脑装敲键盘：0 手搭在键盘上，1 抬手，2 按下
}

/// 照 Claude 官方 Clawd 逐像素重画：身体 16×12，钳子各 4×4，眼睛 2×2，四条腿 2×4
func buildClawd(_ p: Pose) -> Sprite {
    var s = Sprite()
    s.rect(4, 0, 16, 12, "O")
    // 平举：身体两侧 4×4；举起：竖着伸到头顶上方，像在挥钳子
    // 2：双钳往下、往外一甩（Siu 落地的姿势）
    if p.armL == 2 { s.rect(1, 6, 3, 2, "O"); s.rect(0, 8, 2, 4, "O") }
    else if p.armL == 1 { s.rect(0, -4, 3, 4, "O"); s.rect(1, 0, 3, 2, "O") } else { s.rect(0, p.breathe ? 5 : 4, 4, 4, "O") }
    if p.armR == 2 { s.rect(20, 6, 3, 2, "O"); s.rect(22, 8, 2, 4, "O") }
    else if p.armR == 1 { s.rect(21, -4, 3, 4, "O"); s.rect(20, 0, 3, 2, "O") } else { s.rect(20, p.breathe ? 5 : 4, 4, 4, "O") }
    for x in p.hideEyes ? [] : [6 + p.look, 16 + p.look] {
        switch p.eyes {
        case .open: s.rect(x, 2, 2, 2, "E")
        case .closed: s.rect(x, 3, 2, 1, "E")
        case .wide: s.rect(x, 1, 2, 3, "E")
        case .happy:  // ^ ^
            let hx = x == 6 + p.look ? x - 1 : x
            s.rect(hx, 3, 1, 1, "E"); s.rect(hx + 1, 2, 1, 1, "E"); s.rect(hx + 2, 3, 1, 1, "E")
        }
    }
    for (i, x) in (p.wide ? [3, 7, 15, 19] : [4, 8, 14, 18]).enumerated() {
        var h = 4
        if p.sit { h = 2 }
        else if p.legs == 1 && i % 2 == 0 { h = 2 }
        else if p.legs == 2 && i % 2 == 1 { h = 2 }
        s.rect(x, 12, 2, h, "O")
    }
    return s
}

// 女巫帽：从你的截图按底层像素量化，原点 (-2, -10)
let HAT = [
    "..............kKKKKKKK......",
    "...........kKKKKKKKKKKK.....",
    "..........kKKKKKKKKK..K.....",
    "..........kKKKKKKKKK........",
    ".........kKKKKKKKKK.........",
    ".........kKKKKKKKKK.........",
    ".........kKKKKKKKKK.........",
    "........KKKKKKKKKKKK........",
    ".......KKKKKKKKKKKKKK.......",
    "..kkkKKKKKKKKKKKKKKKKKKKKK..",
    ".kKKKKKKKKKKKKKKKKKKKKKKKKK.",
    "...KKKooooooooooooooooKKK...",
]
// 扫帚杆：原点 (-8, 11)
let HANDLE = [
    "..DSS...........................",
    "..DDSSSS........................",
    "...DDSSSSSS.....................",
    "....DDDDDSSSSSSSSSSSSSSSS.......",
    ".........DDDDDDDDDDDDDDSSSSSSSD.",
    ".......................DDDDDDDD.",
]
// 草穗：重画成一缕一缕的扇形，橙色绑绳；原点 (22, 8)
let BRISTLE = [
    "...........L..Y.",
    ".........LYYy.Y.",
    ".......LYYYyyYYL",
    ".....yyYYYYLLLL.",
    "..oyYYLLLLyyyyyY",
    "ooyYYyyyyYYYYYYY",
    "ooYLLLLYYYyyyyyL",
    "ooyYyyyyyLLLLLYY",
    "..oyYYYYyyyYYYy.",
    ".....yyyLLLyyY..",
    ".......yyYYy..Y.",
    ".........Y...y..",
]

/// 头顶的「!」：经典装在头上方，女巫装在帽檐右侧
func addExclaim(_ s: inout Sprite, witch: Bool) {
    let (x, y) = witch ? (27, -9) : (11, -9)
    s.rect(x, y, 2, 4, "A")
    s.rect(x, y + 5, 2, 2, "A")
}

func buildWitch(_ p: Pose) -> Sprite {
    var pose = p
    pose.sit = true
    var s = Sprite()
    s.stamp(HANDLE, -8, 11)
    s.stamp(BRISTLE, 22, 8)
    s.merge(buildClawd(pose))
    s.stamp(HAT, -2, -10)
    return s
}

// MARK: - 皮肤

enum Skin: String, CaseIterable {
    case classic, witch, side, sleepy, santa, scholar, shades, striker, siu

    var title: String {
        switch self {
        case .classic: return "经典"
        case .witch: return "女巫"
        case .side: return "电脑"
        case .sleepy: return "瞌睡"
        case .santa: return "圣诞"
        case .scholar: return "学士"
        case .shades: return "墨镜"
        case .striker: return "球王"
        case .siu: return "Siu"
        }
    }
    /// 造型本身朝左，往右走时整体左右镜像
    var mirrors: Bool { self == .witch || self == .side }
    /// 骑着扫帚飘在空中：不迈腿、不呼吸
    var floats: Bool { self == .witch }
    /// 停手多少秒后打瞌睡（瞌睡装睡得快一些）
    var dozeAfter: CGFloat { self == .sleepy ? 5 : 25 }
    /// 睡着时身体往下沉几个像素（腿收起来趴下）
    var sleepSink: Int {
        switch self {
        case .witch: return 0
        case .side: return 3
        default: return 2
        }
    }
    /// 头顶（含帽子）最高到第几行
    var headTop: Int {
        switch self {
        case .witch, .sleepy, .santa: return -10
        case .scholar: return -7
        case .side: return 2
        default: return 0
        }
    }
    /// 头顶「!」的位置
    func exclaimAt(_ facing: Int) -> (Int, Int) {
        switch self {
        case .witch: return (27, -9)
        case .side: return (11, -7)
        case .sleepy, .santa: return (0, -10)
        case .scholar: return (11, -15)
        default: return (11, -9)
        }
    }
    /// Zzz 从哪里冒出来、往哪边飘
    func zzzAt(_ facing: Int) -> (x: Int, y: Int, dir: Int) {
        switch self {
        case .witch: return (27, -11, 1)
        case .side: return facing > 0 ? (22, -2, 1) : (-1, -2, -1)
        case .sleepy, .santa: return (25, -6, 1)
        case .scholar: return (24, -8, 1)
        default: return (21, -4, 1)
        }
    }
    func sweatX(_ facing: Int) -> Int {
        switch self {
        case .witch: return facing > 0 ? -3 : 25
        case .side: return facing > 0 ? 1 : 22
        default: return 25
        }
    }
}

func recolor(_ rows: [String], _ map: [Character: Character]) -> [String] {
    rows.map { String($0.map { map[$0] ?? $0 }) }
}

// 圣诞帽：帽尖往右耷拉，挂一个绒球；原点 (0, -10)
let SANTA_HAT = [
    "........RRRRRRR............",
    "......RRRRRRRRRRR..........",
    ".....RRRRRRRRRRRRRR........",
    "....RRRRRRRRRRRRrRRRR......",
    "....RRRRRRRRRRRRRrrRRR.....",
    "...RRRRRRRRRRRRRRRr.RRR....",
    "...RRRRRRRRRRRRRRRRr.rRR...",
    "...RRRRRRRRRRRRRRRRR..rr...",
    "..wwwwwwwwwwwwwwwwwwww.www.",
    "..vwwwwwwwwwwwwwwwwwwvwwwww",
    ".......................vwv.",
]
// 睡帽：同一顶帽子，换成夜空蓝
let NIGHT_CAP = recolor(SANTA_HAT, ["R": "N", "r": "n"])

// 学士帽：菱形帽板 + 垂下来的流苏；原点 (1, -7)
let MORTARBOARD = [
    ".........kKKK.........",
    "......kkKKKKKKKK......",
    "...kkKKKKKKKKKKKKKK...",
    "kkKKKKKKKKKKKKKKKKKKKK",
    "...KKKKKKKKKKKKKKKKY..",
    "......KKKKKKKKKK...Y..",
    "....KKKKKKKKKKKKKK.Y..",
    "...................Y..",
    "..................YLY.",
    "..................YLY.",
]

/// 墨镜装：眼睛藏在镜片后面；吓一跳时墨镜滑下来，露出瞪大的眼睛
func buildShades(_ p: Pose) -> Sprite {
    var q = p
    q.hideEyes = true
    var s = buildClawd(q)
    let drop = p.eyes == .wide ? 2 : 0
    if drop > 0 { for x in [6 + p.look, 16 + p.look] { s.rect(x, 1, 2, 2, "E") } }
    let y = 2 + drop
    s.rect(4, y, 16, 1, "K")                               // 镜架
    for x in [5, 13] {
        s.rect(x, y, 6, 2, "K"); s.rect(x + 1, y + 2, 4, 1, "K")   // 镜片，下角收圆
        s.rect(x + 1 + max(0, p.look), y + 1, 2, 1, "k")           // 反光
    }
    return s
}

/// 电脑装：四分之三侧面的 Clawd 对着一台笔记本电脑敲键盘（照你给的截图重画）。造型朝左。
func buildSide(_ p: Pose) -> Sprite {
    var s = Sprite()
    let lie = p.sit                                         // 睡觉：合上电脑，收起腿趴下
    let cheer = p.armL == 1 || p.armR == 1
    if lie {
        s.rect(-9, 11, 8, 1, "G"); s.rect(-9, 12, 8, 1, "k")
    } else {
        s.rect(-8, 14, 8, 1, "k")                           // 键盘
        s.rect(-8, 15, 8, 1, "G")                           // 底座
        for i in 0..<6 {                                    // 屏幕斜着朝向 Clawd：外壳灰色，里面发着光
            s.rect(-9 - i, 12 - i, 1, 2, "G")
            s.rect(-8 - i, 12 - i, 1, 2, p.tap == 2 && i % 2 == 1 ? "w" : "B")
        }
    }
    s.rect(4, 2, 12, 11, "O")                               // 正面
    s.rect(16, 2, 4, 11, "o")                               // 侧面（暗一档）
    s.rect(0, 7, 4, lie ? 6 : 9, "O")                       // 前钳
    s.rect(0, 7, 4, 1, "o"); s.rect(0, 8, 1, 3, "o")
    if !lie {
        if cheer {                                          // 欢呼：把手举起来
            let up = p.armL == 1 ? 7 : 5
            s.rect(0, 7 - up, 3, up, "O")
        } else {                                            // 伸到键盘上的手，打字时一抬一按
            s.rect(-4, p.tap == 1 ? 11 : 12, 4, 2, "O")
        }
    }
    let shift = p.look > 0 ? 1 : 0                          // 回头看时眼睛往后挪一格
    for x in [4 + shift, 12 + shift] {
        switch p.eyes {
        case .open: s.rect(x, 5, 2, 2, "E")
        case .closed: s.rect(x, 6, 2, 1, "E")
        case .wide: s.rect(x, 4, 2, 3, "E")
        case .happy: s.rect(x, 6, 1, 1, "E"); s.rect(x + 1, 5, 1, 1, "E"); s.rect(x + 2, 6, 1, 1, "E")
        }
    }
    if !lie {
        for (i, x) in [4, 8, 14, 18].enumerated() {
            let c: Character = i == 3 ? "o" : "O"
            let lifted = (p.legs == 1 && i % 2 == 0) || (p.legs == 2 && i % 2 == 1)
            s.rect(x, 13, 2, 1, c)
            if lifted { continue }
            s.rect(x, 14, 3, 1, c)                           // 斜着踩出去的小脚
            s.rect(x + 1, 15, 2, 1, c)
        }
    }
    return s
}

// MARK: - 闲着时的小动作

let IDLE_COUNT = 8
let GLYPH_Q = ["AAA", "..A", ".A.", "...", ".A."]
let GLYPH_NOTE = ["..A.", "..AA", "..A.", "AAA.", "AAA."]

/// 停手挑候选时，隔几秒随机做一个小动作。返回 nil 表示这个动作做完了；glyph 是头顶冒出来的小符号。
func idleMove(_ kind: Int, _ t: CGFloat, _ pose: inout Pose, _ lift: inout CGFloat) -> (glyph: [String]?, dummy: Bool)? {
    var glyph: [String]? = nil
    switch kind {
    case 0:                                   // 伸懒腰
        guard t < 1.0 else { return nil }
        pose.armL = 1; pose.armR = 1; pose.eyes = .closed; pose.breathe = false
        if t > 0.3 && t < 0.7 { lift += 1 }
    case 1:                                   // 挥手
        guard t < 1.12 else { return nil }
        pose.eyes = .happy; pose.breathe = false
        pose.armR = Int(t / 0.14) % 2 == 0 ? 1 : 0
    case 2:                                   // 连蹦两下
        guard t < 0.72 else { return nil }
        let u = (t / 0.36).truncatingRemainder(dividingBy: 1)
        lift += (5 * 4 * u * (1 - u)).rounded()
        pose.eyes = .happy
    case 3:                                   // 跺脚
        guard t < 0.96 else { return nil }
        pose.legs = 1 + Int(t / 0.12) % 2
    case 4:                                   // 左看右看，冒个问号
        guard t < 1.6 else { return nil }
        pose.look = t < 0.8 ? -1 : 1
        if t > 0.15 { glyph = GLYPH_Q }
    case 5:                                   // 哼歌
        guard t < 1.8 else { return nil }
        pose.eyes = .happy
        let beat = Int(t / 0.3) % 2
        lift += CGFloat(beat)
        glyph = beat == 0 ? GLYPH_NOTE : GLYPH_NOTE + ["...."]
    case 6:                                   // 琢磨：省略号一个一个冒出来
        guard t < 1.6 else { return nil }
        let n = min(3, 1 + Int(t / 0.35))
        let row = String(repeating: "AA.", count: n)
        glyph = [row, row]
    default:                                  // 摇摇头
        guard t < 0.6 else { return nil }
        pose.look = Int(t / 0.1) % 2 == 0 ? -1 : 1
    }
    return (glyph, true)
}

func buildSkin(_ skin: Skin, _ p: Pose) -> Sprite {
    switch skin {
    case .classic: return buildClawd(p)
    case .witch: return buildWitch(p)
    case .side: return buildSide(p)
    case .shades: return buildShades(p)
    case .sleepy: var s = buildClawd(p); s.stamp(NIGHT_CAP, 0, -10); return s
    case .santa: var s = buildClawd(p); s.stamp(SANTA_HAT, 0, -10); return s
    case .scholar: var s = buildClawd(p); s.stamp(MORTARBOARD, 1, -7); return s
    case .striker:                       // 天蓝白竖条球衣；足球由 addBall 另外画
        var s = buildClawd(p)
        for y in 5...11 { for x in 4...19 { s.px[P(x: x, y: y)] = [3, 4, 7, 8, 11, 12].contains(x - 4) ? "w" : "C" } }
        return s
    case .siu:                           // 红球衣、绿下摆；转身时亮出背后的 7 号
        var q = p
        if p.back { q.hideEyes = true }
        var s = buildClawd(q)
        s.rect(4, 5, 16, 6, "R"); s.rect(4, 11, 16, 1, "g")
        if p.back { s.stamp(["wwww", "...w", "..w.", ".w..", ".w.."], 10, 5) } else { s.rect(11, 5, 2, 1, "w") }
        return s
    }
}

// 足球
let BALL = [".www.", "wwKww", "wKKKw", "vwKwv", ".vvv."]

/// 球王装的足球：走路时带球，停下来用钳子颠球，睡着了球停在脚边。lift 是身体被抬高的像素数（球不跟着身体跳）
func addBall(_ s: inout Sprite, clock: CGFloat, moving: Bool, facing: Int, asleep: Bool, lift: Int) {
    var x = facing > 0 ? 25 : -6, y = 11
    if moving {
        let b = [0, 1, 3, 1][Int(clock / 0.09) % 4]
        x += facing > 0 ? b : -b
        if b == 3 { y -= 1 }
    } else if !asleep {
        let u = (clock / 0.62).truncatingRemainder(dividingBy: 1)
        x = facing > 0 ? 20 : -1
        y = -1 - Int((4 * u * (1 - u) * 8).rounded()) - lift
    }
    s.stamp(BALL, x, y + lift)
}

/// Siu 落地时头顶蹦出来的「SIU!」
func addSiu(_ s: inout Sprite) {
    s.stamp(["AAA.A.A.A.A", "A...A.A.A.A", "AAA.A.A.A.A", "..A.A.A.A..", "AAA.A.AAA.A"], 7, -9)
}

func addExclaim(_ s: inout Sprite, at pos: (Int, Int)) {
    s.rect(pos.0, pos.1, 2, 4, "A")
    s.rect(pos.0, pos.1 + 5, 2, 2, "A")
}

// 睡着时飘起来的 Zzz：两个 Z 一前一后，越飘越大
let ZZZ: [[String]] = [
    ["ZZZ", ".Z.", "ZZZ"],
    ["ZZZZ", "..Z.", ".Z..", "ZZZZ"],
    ["ZZZZZ", "...Z.", "..Z..", ".Z...", "ZZZZZ"],
]

func addZzz(_ s: inout Sprite, clock: CGFloat, at o: (x: Int, y: Int, dir: Int)) {
    let period: CGFloat = 3.4
    for i in 0..<2 {
        let u = ((clock / period) + CGFloat(i) / 2).truncatingRemainder(dividingBy: 1)
        let glyph = recolor(ZZZ[min(2, Int(u * 3))], ["Z": "A"])
        let w = glyph[0].count
        let rise = Int((u * 15).rounded()), drift = Int((u * 11).rounded())
        let x = o.dir > 0 ? o.x + drift : o.x - drift - (w - 1)
        s.stamp(glyph, x, o.y - rise - (glyph.count - 1))
    }
}

// MARK: - 火花粒子（Claude 的 ✻ 风格小星星）

struct Spark {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
    var age: CGFloat = 0, life: CGFloat
    var color: Character
    var kind = 0               // 0 火花，1 小爱心，2 大爱心，3 足球
    var gravity: CGFloat = 18
}

let HEART_S = [".X.X.", "XXXXX", ".XXX.", "..X.."]
let HEART_B = [".XX.XX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX..", "...X..."]
// 打出「猪咪」时头顶那颗一跳一跳的大爱心
let HEART_M = [".HH.HH.", "HwHHHHH", "HHHHHHH", ".HHHHh.", "..HHh..", "...h..."]
let HEART_L = [".HH...HH.", "HHHH.HHHH", "HwwHHHHHH", "HwHHHHHHH", ".HHHHHHh.", "..HHHHh..", "...HHh...", "....h...."]

/// 一个粒子占哪些格子（相对粒子中心）
func sparkCells(_ s: Spark) -> [(CGFloat, CGFloat)] {
    if s.kind > 0 {
        let g = s.kind == 2 ? HEART_B : HEART_S
        let ox = CGFloat(g[0].count / 2), oy = CGFloat(g.count / 2)
        var out: [(CGFloat, CGFloat)] = []
        for (j, row) in g.enumerated() { for (i, ch) in row.enumerated() where ch != "." { out.append((CGFloat(i) - ox, CGFloat(j) - oy)) } }
        return out
    }
    let k = s.age / s.life
    if k < 0.45 { return [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] }      // ✚ 形
    if k < 0.75 { return [(0, 0), (-1, -1), (1, 1), (-1, 1), (1, -1)] }    // ✕ 形
    return [(0, 0)]
}

// MARK: - 画布

final class SpriteView: NSView {
    var sprite = Sprite()
    var sparks: [Spark] = []
    var unit: CGFloat = 1.5
    let anchor = P(x: 44, y: 64)   // Clawd (0,0) 在画布里的位置
    static let canvasW = 112, canvasH = 86
    static let feetRow = 64 + 16   // 脚底所在的画布行

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        func cell(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: (x + CGFloat(anchor.x)) * unit, y: (y + CGFloat(anchor.y)) * unit, width: unit, height: unit)
        }
        var byColor: [Character: [CGRect]] = [:]
        for (p, ch) in sprite.px { byColor[ch, default: []].append(cell(CGFloat(p.x), CGFloat(p.y))) }
        for (ch, rects) in byColor {
            guard let c = PALETTE[ch] else { continue }
            ctx.setFillColor(c)
            ctx.fill(rects)
        }
        for s in sparks {
            let k = s.age / s.life
            let a = max(0, 1 - k * k)
            let base = PALETTE[s.color] ?? rgb(0xD97757)
            ctx.setFillColor(base.copy(alpha: a) ?? base)
            let cx = s.x.rounded(), cy = s.y.rounded()
            if s.kind == 3 {     // 踢出去的足球
                for (j, row) in BALL.enumerated() {
                    for (i, ch) in row.enumerated() where ch != "." {
                        guard let c = PALETTE[ch] else { continue }
                        ctx.setFillColor(c.copy(alpha: a) ?? c)
                        ctx.fill(cell(cx + CGFloat(i), cy + CGFloat(j)))
                    }
                }
                continue
            }
            ctx.fill(sparkCells(s).map { cell(cx + $0.0, cy + $0.1) })
        }
    }
}

// MARK: - 输入法状态（由 lua/clawd.lua 写入）

struct RimeState: Equatable {
    var sid = ""
    var composing = false
    var commits = 0
    var input = ""
    var preCaret = ""
    var commitText = ""   // 最近一次上屏的文字（旧版 clawd.lua 不写这一栏）
}

let STATE_DIR = NSHomeDirectory() + "/Library/Caches/ClawdCompanion"
let STATE_FILE = STATE_DIR + "/state"

func parseState(_ text: String) -> RimeState? {
    guard let line = text.split(separator: "\n").first else { return nil }
    let f = line.components(separatedBy: "\t")
    guard f.count >= 7, f[1] == "v1" else { return nil }
    return RimeState(sid: f[2], composing: f[3] == "1", commits: Int(f[4]) ?? 0, input: f[5], preCaret: f[6],
                     commitText: f.count > 7 ? f[7] : "")
}

final class StateWatcher {
    var onChange: ((RimeState) -> Void)?
    private var source: DispatchSourceFileSystemObject?

    func start() {
        try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: STATE_FILE) {
            FileManager.default.createFile(atPath: STATE_FILE, contents: Data())
        }
        let fd = open(STATE_FILE, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .attrib, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                src.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.start() }
                return
            }
            self.read()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    func read() {
        guard let text = try? String(contentsOfFile: STATE_FILE, encoding: .utf8), let st = parseState(text) else { return }
        onChange?(st)
    }
}

// MARK: - 鼠须管候选框定位

final class PanelTracker {
    private var pid: pid_t = 0
    private var windowIDs: [CGWindowID] = []
    private var lastScan: CFTimeInterval = 0

    private func refreshPID() {
        if pid == 0 || NSRunningApplication(processIdentifier: pid) == nil {
            pid = NSRunningApplication.runningApplications(withBundleIdentifier: "im.rime.inputmethod.Squirrel")
                .first?.processIdentifier ?? 0
        }
    }

    /// 找出鼠须管所有高层级窗口的 ID（候选框就是其中之一，ID 基本不变）
    private func scan() {
        refreshPID()
        lastScan = CACurrentMediaTime()
        guard pid != 0,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            windowIDs = []; return
        }
        windowIDs = list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int ?? 0) > 1000,
                  let id = w[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(id)
        }
    }

    /// 候选框在屏幕上的位置（AppKit 坐标，原点在主屏左下）；看不见时返回 nil
    func panelRect() -> NSRect? {
        if windowIDs.isEmpty || CACurrentMediaTime() - lastScan > 3 { scan() }
        guard !windowIDs.isEmpty else { return nil }
        // 注意：必须用 CFArrayCreate 直接存原始的窗口 ID。
        // 写成 `ids.map { UnsafeRawPointer(...) } as CFArray` 时 Swift 会把它们装箱成对象，
        // 系统一个窗口都认不出来，永远返回空 —— 这就是之前真实打字时 Clawd 不出现的原因。
        var raw = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let arr = CFArrayCreate(kCFAllocatorDefault, &raw, raw.count, nil),
              let desc = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for w in desc {
            guard (w[kCGWindowIsOnscreen as String] as? Bool) == true,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.width > 30, r.height > 14 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        if desc.count < windowIDs.count { scan() }   // 有窗口被销毁重建了，重新找
        guard let b = best, let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: b.minX, y: primary.frame.maxY - b.maxY, width: b.width, height: b.height)
    }
}

// MARK: - 读取鼠须管主题里的字号和边距（用来算光标位置）

struct SquirrelMetrics {
    var fontPoint: CGFloat = 15
    var insetX: CGFloat = 17

    static func load() -> SquirrelMetrics {
        var m = SquirrelMetrics()
        let path = NSHomeDirectory() + "/Library/Rime/squirrel.custom.yaml"
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return m }
        func num(_ key: String) -> CGFloat? {
            let pattern = "\"?style/\(key)\"?\\s*:\\s*(-?[0-9.]+)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let mt = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(mt.range(at: 1), in: s), let v = Double(s[r]) else { return nil }
            return CGFloat(v)
        }
        m.fontPoint = num("font_point") ?? 15
        m.insetX = max(0, (num("border_width") ?? 1)) + (num("corner_radius") ?? 16)
        return m
    }

    var font: NSFont {
        let base = NSFont.systemFont(ofSize: fontPoint)
        let cascade = ["Menlo-Regular", "PingFangSC-Regular"].map { NSFontDescriptor(name: $0, size: fontPoint) }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: fontPoint) ?? base
    }
}

// MARK: - 偏好设置

final class Prefs {
    static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// "auto"（每天换一套）或某个皮肤的名字
    static var costume: String {
        get { let v = d.string(forKey: "costume") ?? "auto"; return Skin(rawValue: v) != nil ? v : "auto" }
        set { d.set(newValue, forKey: "costume") }
    }
    static var size: String {   // s / m / l
        get { d.string(forKey: "size") ?? "m" }
        set { d.set(newValue, forKey: "size") }
    }
    static var unit: CGFloat { ["s": 1.0, "m": 1.5, "l": 2.0][size] ?? 1.5 }

    /// 中文模式下默认用英文标点；写进 punct 文件，由 lua/clawd_punct.lua 读取
    static var englishPunct: Bool {
        get { d.object(forKey: "englishPunct") as? Bool ?? true }
        set { d.set(newValue, forKey: "englishPunct"); writePunct() }
    }

    static func writePunct() {
        try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
        try? (englishPunct ? "en\n" : "zh\n").write(toFile: STATE_DIR + "/punct", atomically: true, encoding: .utf8)
    }

    static var showIcon: Bool {
        get { d.object(forKey: "showIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showIcon") }
    }

    static var forced: Skin?   // 录制演示时用

    /// 「自动」：全部皮肤每天换一套，轮着来；万圣节固定女巫，平安夜和圣诞节固定圣诞帽
    static func autoSkin(on date: Date = Date()) -> Skin {
        let cal = Calendar.current
        let c = cal.dateComponents([.month, .day], from: date)
        if c.month == 10 && c.day == 31 { return .witch }
        if c.month == 12 && (c.day == 24 || c.day == 25) { return .santa }
        let days = cal.ordinality(of: .day, in: .era, for: date) ?? 0
        return Skin.allCases[days % Skin.allCases.count]
    }

    private static var autoCache: (at: CFAbsoluteTime, skin: Skin)?
    static var skin: Skin {
        if let f = forced { return f }
        if let s = Skin(rawValue: costume) { return s }
        let now = CFAbsoluteTimeGetCurrent()
        if let c = autoCache, now - c.at < 20 { return c.skin }
        let s = autoSkin()
        autoCache = (now, s)
        return s
    }
}

// MARK: - 安装 / 卸载输入法配置（主题 + clawd.lua）

enum RimeInstaller {
    /// 测试时可以用环境变量 CLAWD_RIME_DIR 指向别的目录
    static let testDir = ProcessInfo.processInfo.environment["CLAWD_RIME_DIR"]
    static let rime = testDir ?? NSHomeDirectory() + "/Library/Rime"
    static let beginMark = "# >>> clawd（由 Clawd.app 添加，卸载时会自动删除这一段）"
    static let endMark = "# <<< clawd"
    static var resDir: String { ProcessInfo.processInfo.environment["CLAWD_RES_DIR"] ?? (Bundle.main.resourcePath ?? "") + "/rime" }
    static let fm = FileManager.default

    static var squirrelApp: String? {
        ["~/Library/Input Methods/Squirrel.app", "/Library/Input Methods/Squirrel.app"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first { fm.fileExists(atPath: $0) }
    }

    static func read(_ name: String) -> String? { try? String(contentsOfFile: rime + "/" + name, encoding: .utf8) }

    static var isInstalled: Bool {
        fm.fileExists(atPath: rime + "/lua/clawd.lua")
            && (read("rime_ice.custom.yaml")?.contains("lua_translator@*clawd") ?? false)
    }

    static var statusText: String {
        if squirrelApp == nil { return "没有检测到鼠须管（Squirrel），请先安装鼠须管和雾凇拼音" }
        if !fm.fileExists(atPath: rime + "/rime_ice.schema.yaml") { return "没有检测到雾凇拼音（rime_ice），其他方案请参考 README 手动配置" }
        return isInstalled ? "已安装 ✓" : "尚未安装"
    }

    static let block = """
    \(beginMark)
      "engine/processors/@before 0": lua_processor@*clawd_punct
      "engine/translators/+":
        - lua_translator@*clawd
      clawd:
        style: companion
        sparkle: true
    \(endMark)
    """

    /// 只在「patch: 是唯一的顶层键」时才自动追加，避免把别人的 YAML 改坏
    static func topLevelKeys(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let c = line.first, c != " ", c != "\t", c != "#", line != "---" else { return nil }
            return String(line.split(separator: ":").first ?? "")
        }
    }

    static func reload() {
        guard testDir == nil, let app = squirrelApp else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: app + "/Contents/MacOS/Squirrel")
        p.arguments = ["--reload"]
        try? p.run()
    }

    /// 返回给用户看的结果说明
    static func install() -> String {
        guard squirrelApp != nil || testDir != nil else { return "没有检测到鼠须管，请先安装：https://rime.im" }
        do {
            try fm.createDirectory(atPath: rime + "/lua", withIntermediateDirectories: true)
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
            let backup = rime + "/backup_clawd_" + df.string(from: Date())
            try fm.createDirectory(atPath: backup, withIntermediateDirectories: true)
            for f in ["squirrel.custom.yaml", "rime_ice.custom.yaml"] where fm.fileExists(atPath: rime + "/" + f) {
                try? fm.copyItem(atPath: rime + "/" + f, toPath: backup + "/" + f)
            }
            UserDefaults.standard.set(backup, forKey: "rimeBackup")

            // 1. 主题
            let theme = try String(contentsOfFile: resDir + "/squirrel.custom.yaml", encoding: .utf8)
            try theme.write(toFile: rime + "/squirrel.custom.yaml", atomically: true, encoding: .utf8)
            // 2. Lua 脚本
            for f in ["clawd.lua", "clawd_punct.lua"] {
                try? fm.removeItem(atPath: rime + "/lua/" + f)
                try fm.copyItem(atPath: resDir + "/" + f, toPath: rime + "/lua/" + f)
            }
            // 3. 给雾凇拼音挂上脚本
            var note = ""
            if fm.fileExists(atPath: rime + "/rime_ice.schema.yaml") {
                var text = read("rime_ice.custom.yaml") ?? ""
                if text.contains(beginMark) {
                    note = ""
                } else if text.contains("lua_translator@*clawd") {
                    note = ""   // 之前手动配过
                } else if text.contains("engine/translators/+") {
                    note = "\n⚠️ 你的 rime_ice.custom.yaml 里已经有 engine/translators/+，为避免冲突没有自动修改，请按 README 手动加一行 lua_translator@*clawd。"
                } else {
                    let keys = topLevelKeys(text)
                    if keys.isEmpty {
                        text = "patch:\n" + block + "\n"
                    } else if keys == ["patch"] {
                        if !text.hasSuffix("\n") { text += "\n" }
                        text += block + "\n"
                    } else {
                        note = "\n⚠️ rime_ice.custom.yaml 结构比较特殊，没有自动修改，请按 README 手动配置。"
                    }
                    if note.isEmpty { try text.write(toFile: rime + "/rime_ice.custom.yaml", atomically: true, encoding: .utf8) }
                }
            } else {
                note = "\n⚠️ 没有检测到雾凇拼音，只安装了主题；其他方案请按 README 手动挂上 clawd.lua。"
            }
            reload()
            return "安装完成，鼠须管正在重新部署。原配置已备份到 \((backup as NSString).abbreviatingWithTildeInPath)。" + note
        } catch {
            return "安装失败：\(error.localizedDescription)"
        }
    }

    static func uninstall() -> String {
        if var text = read("rime_ice.custom.yaml"),
           let a = text.range(of: beginMark), let b = text.range(of: endMark, range: a.upperBound..<text.endIndex) {
            var end = b.upperBound
            if end < text.endIndex, text[end] == "\n" { end = text.index(after: end) }
            text.removeSubrange(a.lowerBound..<end)
            try? text.write(toFile: rime + "/rime_ice.custom.yaml", atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(atPath: rime + "/lua/clawd.lua")
        try? fm.removeItem(atPath: rime + "/lua/clawd_punct.lua")
        if let backup = UserDefaults.standard.string(forKey: "rimeBackup"),
           fm.fileExists(atPath: backup + "/squirrel.custom.yaml") {
            try? fm.removeItem(atPath: rime + "/squirrel.custom.yaml")
            try? fm.copyItem(atPath: backup + "/squirrel.custom.yaml", toPath: rime + "/squirrel.custom.yaml")
        } else if read("squirrel.custom.yaml")?.contains("claude_light") ?? false {
            try? fm.removeItem(atPath: rime + "/squirrel.custom.yaml")
        }
        reload()
        return "已卸载并恢复原来的主题，鼠须管正在重新部署。"
    }
}

// MARK: - 动画控制

final class ClawdController {
    var window: NSPanel
    var spaceCheckAt: CGFloat = 0
    let view = SpriteView()
    let tracker = PanelTracker()
    let watcher = StateWatcher()
    var metrics = SquirrelMetrics.load()
    lazy var font = metrics.font

    var state = RimeState()
    var timer: Timer?
    var lastTick = CACurrentMediaTime()
    var clock: CGFloat = 0

    // 演示模式：用一个假的候选框代替鼠须管
    var demoPanel: (() -> NSRect?)?

    // 运动
    var x: CGFloat = 0, targetX: CGFloat = 0, hasX = false
    var facing = 1
    var walkClock: CGFloat = 0
    var alpha: CGFloat = 0
    var showing = false
    var dropIn: CGFloat = 0
    var lastPanel: NSRect?
    var hiddenSince: CGFloat = 0

    // 表情
    var nextBlink: CGFloat = 2, blinkUntil: CGFloat = 0
    var nextLook: CGFloat = 5, lookUntil: CGFloat = 0, lookDir = 0
    var lastInputLen = 0, backUntil: CGFloat = 0
    var jumpT: CGFloat? = nil
    var hopT: CGFloat? = nil          // 退格时往后弹一下
    var cheerSparkAt: CGFloat = 0, trailAt: CGFloat = 0
    var lastKeyAt: CGFloat = 0
    var wasAsleep = false, startleUntil: CGFloat = 0
    var loveUntil: CGFloat = 0, loveSparkAt: CGFloat = 0, loveBurstAt: CGFloat = 0
    var landUntil: CGFloat = 0     // Siu 落地定格
    var idleKind: Int? = nil, idleT: CGFloat = 0, nextIdleAt: CGFloat = 0, lastIdleKind = -1
    var kickUntil: CGFloat = 0     // 球王把球踢出去了，球还没回来

    let offscreen: Bool

    init(watch: Bool = true, offscreen: Bool = false) {
        self.offscreen = offscreen
        window = ClawdController.makeWindow()
        window.contentView = view
        applySize()
        watcher.onChange = { [weak self] st in self?.receive(st) }
        if watch { watcher.start() }
    }

    static func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.alphaValue = 0
        return w
    }

    /// 悬浮窗有时会留在它第一次出现的那个桌面 / 全屏空间里，换到别的全屏应用就看不见了。
    /// 出场时、以及显示期间每半秒检查一次：不在当前空间就丢掉旧窗口，重建一个。
    func ensureOnActiveSpace(_ why: String) {
        guard !offscreen else { return }
        if window.isVisible && window.isOnActiveSpace { return }
        let wasVisible = window.isVisible
        window.orderOut(nil)
        window.contentView = nil
        window = ClawdController.makeWindow()
        window.contentView = view
        applySize()
        window.alphaValue = alpha
        window.orderFrontRegardless()
        log("space-\(Int(clock * 2))", "悬浮窗不在当前空间（\(why)，原先 visible=\(wasVisible)），已重建；现在 onActiveSpace=\(window.isOnActiveSpace)")
    }

    func applySize() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        view.unit = (Prefs.unit * scale).rounded() / scale
        let size = NSSize(width: CGFloat(SpriteView.canvasW) * view.unit, height: CGFloat(SpriteView.canvasH) * view.unit)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        metrics = SquirrelMetrics.load()
        font = metrics.font
    }

    // 自检日志：~/Library/Caches/ClawdCompanion/live.log，只在状态变化时写一行
    var logLines: [String] = []
    var lastLogKey = ""
    func log(_ key: String, _ msg: String) {
        guard key != lastLogKey else { return }
        lastLogKey = key
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(f.string(from: Date())) \(msg)")
        if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
        try? logLines.joined(separator: "\n").write(toFile: STATE_DIR + "/live.log", atomically: true, encoding: .utf8)
    }

    func receive(_ st: RimeState) {
        let old = state
        state = st
        if st.composing != old.composing || st.commits != old.commits {
            log("state\(st.composing)\(st.commits)", "收到输入法状态 composing=\(st.composing) commits=\(st.commits) input=\(st.input)")
        }
        if st.sid == old.sid && st.commits > old.commits && showing {
            jumpT = 0
            // 上屏的是「猪咪」→ 放爱心烟花（旧版脚本不报上屏文字，就按拼音判断）
            let lovely = st.commitText.isEmpty ? old.input.lowercased().contains("zhumi") : st.commitText.contains("猪咪")
            if lovely { loveUntil = clock + 1.9; loveBurstAt = 0 } else { burst(count: 8) }
            if Prefs.skin == .striker && !lovely {           // 球王：上屏就是一脚射门
                kickUntil = clock + 1.1
                view.sparks.append(Spark(x: facing > 0 ? 26 : -7, y: 10, vx: CGFloat(facing) * 85, vy: -48,
                                         life: 1.1, color: "w", kind: 3, gravity: 80))
            }
        }
        let n = st.input.count
        if st.composing {
            if n < lastInputLen { backUntil = clock + 0.6; hopT = 0 }
            if n != lastInputLen { lastKeyAt = clock }
        }
        lastInputLen = st.composing ? n : 0
        wake()
    }

    func wake() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sleep() {
        timer?.invalidate()
        timer = nil
    }

    func textWidth(_ s: String) -> CGFloat {
        s.isEmpty ? 0 : (s as NSString).size(withAttributes: [.font: font]).width
    }

    func burst(count: Int) {
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * .pi * 2 + CGFloat.random(in: -0.3...0.3)
            let sp = CGFloat.random(in: 14...24)
            view.sparks.append(Spark(x: 12, y: 2, vx: cos(a) * sp, vy: sin(a) * sp - 10,
                                     life: CGFloat.random(in: 0.45...0.7), color: i % 3 == 0 ? "L" : "O"))
        }
    }

    func loveBurst(count: Int) {
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * .pi * 2 + CGFloat.random(in: -0.25...0.25)
            let sp = CGFloat.random(in: 26...62)
            view.sparks.append(Spark(x: 12, y: 0, vx: cos(a) * sp, vy: sin(a) * sp - 16,
                                     life: CGFloat.random(in: 0.9...1.5), color: i % 2 == 0 ? "H" : "h",
                                     kind: i % 3 == 0 ? 2 : 1, gravity: 26))
        }
    }

    func tick(fixedDT: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        let dt = fixedDT ?? CGFloat(min(0.05, now - lastTick))
        lastTick = now
        clock += dt
        let u = view.unit

        let panel = demoPanel?() ?? (Prefs.enabled && state.composing ? tracker.panelRect() : nil)
        let want = panel != nil && (demoPanel != nil || (Prefs.enabled && state.composing))
        if state.composing && demoPanel == nil {
            if let p = panel {
                log("panel-ok", "找到候选框 \(Int(p.minX)),\(Int(p.minY)) \(Int(p.width))×\(Int(p.height))，显示 Clawd")
            } else {
                log("panel-none", Prefs.enabled ? "在输入，但没找到鼠须管候选框窗口" : "在输入，但「显示 Clawd」是关着的")
            }
        }
        let skin = Prefs.skin

        if want, let panel {
            lastPanel = panel
            if !showing {
                showing = true
                dropIn = 6
                lastKeyAt = clock
                nextBlink = clock + 0.8          // 一出场先眨个眼
                nextLook = clock + 1.6
                if !offscreen { window.orderFrontRegardless(); ensureOnActiveSpace("出场"); spaceCheckAt = clock + 0.5 }
            }
            // 光标横坐标 → Clawd 站在光标正上方
            let caretX = panel.minX + metrics.insetX + textWidth(state.preCaret) + 3
            let bodyW = 24 * u
            let lo = panel.minX + 6, hi = max(lo, panel.maxX - bodyW - 6)
            targetX = min(max(caretX - bodyW / 2, lo), hi)
            if !hasX { x = targetX; hasX = true }
            alpha = min(1, alpha + dt / 0.15)
            if clock > spaceCheckAt { spaceCheckAt = clock + 0.5; ensureOnActiveSpace("显示中") }
        } else {
            // 上屏跳跃时先跳完再淡出
            if jumpT == nil && clock >= loveUntil && clock >= landUntil { alpha = max(0, alpha - dt / 0.2) }
            if alpha == 0 && showing && jumpT == nil {
                showing = false
                hasX = false
                window.orderOut(nil)
                view.sparks.removeAll()
            }
        }

        // 位移：平滑追赶目标，追赶时迈腿
        let dx = targetX - x
        x += dx * (1 - exp(-dt * 14))
        let moving = abs(dx) > 0.75
        if moving {
            facing = dx > 0 ? 1 : -1
            walkClock += dt
        } else {
            walkClock = 0
        }
        let legPhase = moving ? [1, 0, 2, 0][Int(walkClock / 0.07) % 4] : 0

        // 表情
        var pose = Pose()
        pose.legs = skin.floats ? 0 : legPhase
        let idle = !moving && clock - lastKeyAt > 0.6     // 停下来挑候选的时候
        if moving {
            pose.look = facing
        } else if idle {
            if clock > nextLook {                          // 东张西望
                lookDir = lookDir == 1 ? -1 : 1
                lookUntil = clock + 0.55
                nextLook = clock + CGFloat.random(in: 1.0...2.2)
            }
            if clock < lookUntil { pose.look = lookDir }
            pose.breathe = !skin.floats && Int(clock / 0.55) % 2 == 1   // 呼吸：钳子一沉一浮
        }
        if clock > nextBlink {
            blinkUntil = clock + 0.13
            nextBlink = clock + CGFloat.random(in: 1.6...3.4)
        }
        if clock < blinkUntil { pose.eyes = .closed }
        if clock < backUntil { pose.eyes = .wide }

        let lower = state.input.lowercased()
        let cheering = state.composing && (lower.contains("claude") || lower.contains("kelaode"))
        if cheering {
            pose.eyes = .happy
            let phase = Int(clock / 0.16) % 2
            pose.armL = phase; pose.armR = 1 - phase
            if clock > cheerSparkAt {
                cheerSparkAt = clock + 0.14
                view.sparks.append(Spark(x: CGFloat.random(in: -2...26), y: CGFloat.random(in: -6...2),
                                         vx: CGFloat.random(in: -6...6), vy: -14, life: 0.6,
                                         color: Bool.random() ? "O" : "L"))
            }
        }

        var lift: CGFloat = 0

        // 打出「猪咪」：Clawd 蹦蹦跳跳，四周不停冒爱心
        let love = state.composing && lower.contains("zhumi")
        if love {
            pose.eyes = .happy
            let phase = Int(clock / 0.12) % 2
            pose.armL = phase; pose.armR = 1 - phase
            lift += (abs(sin(clock * 9)) * 3).rounded()
            if clock > loveSparkAt {
                loveSparkAt = clock + 0.06
                view.sparks.append(Spark(x: CGFloat.random(in: -38...62), y: CGFloat.random(in: -6...14),
                                         vx: CGFloat.random(in: -5...5), vy: CGFloat.random(in: -34 ... -18),
                                         life: CGFloat.random(in: 0.9...1.5), color: Bool.random() ? "H" : "h",
                                         kind: Bool.random() ? 1 : 2, gravity: -4))
            }
        }
        if clock < loveUntil && clock > loveBurstAt {       // 「猪咪」上屏后：接连放几轮爱心烟花
            loveBurstAt = clock + 0.45
            loveBurst(count: 22)
        }

        // 打瞌睡：停手一会儿就睡着（瞌睡装几乎一停就睡），一按键就醒
        let asleep = showing && want && !moving && !cheering && !love && jumpT == nil
            && clock >= backUntil && clock >= landUntil && clock - lastKeyAt > skin.dozeAfter
        if asleep {
            pose = Pose(eyes: .closed, sit: true, breathe: !skin.floats && Int(clock / 0.9) % 2 == 1)
            lift -= CGFloat(skin.sleepSink)
        } else if wasAsleep && skin == .sleepy && jumpT == nil {
            hopT = 0; startleUntil = clock + 0.35             // 瞌睡装被吵醒：一激灵
        }
        wasAsleep = asleep
        if clock < startleUntil && jumpT == nil && !asleep { pose.eyes = .wide }

        // 闲着挑候选的时候，隔几秒随机做个小动作
        var idleGlyph: [String]? = nil
        let free = idle && showing && want && !asleep && !cheering && !love && jumpT == nil
            && clock >= backUntil && clock >= landUntil && clock >= startleUntil
        if !free {
            idleKind = nil
            nextIdleAt = clock + CGFloat.random(in: 2.2...4)
        } else if let k = idleKind {
            idleT += dt
            if let r = idleMove(k, idleT, &pose, &lift) { idleGlyph = r.glyph } else {
                idleKind = nil
                nextIdleAt = clock + CGFloat.random(in: 2.5...5)
            }
        } else if clock > nextIdleAt {
            var k = Int.random(in: 0..<IDLE_COUNT)
            if k == lastIdleKind { k = (k + 1) % IDLE_COUNT }
            idleKind = k; lastIdleKind = k; idleT = 0
        }
        // 电脑装：你打字时它也在敲键盘
        if skin == .side && !asleep && (moving || clock - lastKeyAt < 0.45) { pose.tap = 1 + Int(clock / 0.07) % 2 }

        // 上屏：跳一下、举双钳
        let siu = skin == .siu && clock >= loveUntil
        if let t = jumpT {
            let T: CGFloat = siu ? 0.56 : 0.42
            if t < T {
                lift += (clock < loveUntil ? 14 : siu ? 16 : 10) * 4 * (t / T) * (1 - t / T)
                pose.armL = 1; pose.armR = 1; pose.eyes = .happy; pose.legs = 0
                if siu && t > T * 0.3 && t < T * 0.8 { pose.back = true }   // 空中转身，亮出背后的 7 号
                jumpT = t + dt
            } else {
                jumpT = clock < loveUntil - 0.3 ? 0 : nil   // 爱心烟花期间连着跳
                if siu { landUntil = clock + 0.8; burst(count: 10) }
            }
        }
        if clock < landUntil {                              // Siu 落地：两腿叉开，双钳往下一甩
            pose = Pose(eyes: .happy, armL: 2, armR: 2)
            pose.wide = true
        }
        if let t = hopT {                                   // 退格：吓得往上一弹
            let T: CGFloat = 0.22
            if t < T { lift += 4 * 4 * (t / T) * (1 - t / T); hopT = t + dt } else { hopT = nil }
        }
        if dropIn > 0 {
            lift += dropIn
            dropIn = max(0, dropIn - dt * 40)
        }

        let flip = skin.mirrors && facing > 0               // 朝左画的造型，往右走时镜像
        var spritePose = pose
        if flip { spritePose.look = -pose.look }
        var sprite = buildSkin(skin, spritePose)
        if flip { sprite = sprite.mirrored(23) }
        if skin.floats {
            lift += 5 + (1.5 * sin(clock * 3.2)).rounded()
            if moving && clock > trailAt {   // 草穗后面拖出一串小火花
                trailAt = clock + 0.05
                let tailX: CGFloat = facing > 0 ? -12 : 36
                view.sparks.append(Spark(x: tailX, y: CGFloat.random(in: 12...17),
                                         vx: CGFloat(-facing) * CGFloat.random(in: 8...16), vy: CGFloat.random(in: -4...4),
                                         life: 0.5, color: ["L", "Y", "O"].randomElement()!))
            }
        }

        if clock < backUntil { addExclaim(&sprite, at: skin.exclaimAt(facing)) }
        if asleep { addZzz(&sprite, clock: clock, at: skin.zzzAt(facing)) }
        if clock < landUntil { addSiu(&sprite) }
        if let g = idleGlyph { sprite.stamp(g, 15, skin.headTop - g.count - 2) }
        if skin == .striker && clock >= kickUntil {
            addBall(&sprite, clock: clock, moving: moving, facing: facing, asleep: asleep, lift: Int(lift.rounded()))
        }
        if love || clock < loveUntil {                      // 头顶一颗一跳一跳的大爱心
            let big = Int(clock / 0.22) % 2 == 0
            sprite.stamp(big ? HEART_L : HEART_M, big ? 8 : 9, skin.headTop - (big ? 13 : 12))
        }

        // 编码很长：冒汗
        if state.composing && state.input.count >= 16 && !cheering && !asleep && !love {
            let k = Int(clock / 0.12) % 6
            sprite.rect(skin.sweatX(facing), -2 + k, 1, 2, "B")
        }

        let liftPx = Int(lift.rounded())
        if liftPx != 0 {
            var s = Sprite(); s.merge(sprite, dy: -liftPx); sprite = s
        }
        view.sprite = sprite

        // 粒子
        view.sparks = view.sparks.compactMap { s in
            var s = s
            s.age += dt
            s.x += s.vx * dt; s.y += s.vy * dt
            s.vy += s.gravity * dt
            return s.age < s.life ? s : nil
        }

        // 窗口位置：脚底踩在候选框上沿
        if let p = lastPanel {
            let scale = window.screen?.backingScaleFactor ?? 2
            func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
            let feetY = p.maxY - 1
            let originY = feetY - CGFloat(SpriteView.canvasH - SpriteView.feetRow) * u
            let originX = x - CGFloat(view.anchor.x) * u
            window.setFrameOrigin(NSPoint(x: snap(originX), y: snap(originY)))
        }
        window.alphaValue = alpha
        view.needsDisplay = true

        // 不在输入、也没有动画了 → 停表省电
        if !showing && view.sparks.isEmpty && demoPanel == nil {
            sleep()
        } else if showing && !want && alpha == 0 && jumpT == nil {
            sleep()
        }
    }
}

// MARK: - 演示：屏幕中央放一个假候选框，跑一遍各种动作

final class DemoPanelView: NSView {
    var preedit = ""
    var cands: [String] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); bounds.fill(using: .copy)   // 圆角外保持透明
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        NSColor(srgbRed: dark ? 0.15 : 0.98, green: dark ? 0.15 : 0.976, blue: dark ? 0.14 : 0.96, alpha: 0.97).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (dark ? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.18, alpha: 1) : .white).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 44).fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 0.87, alpha: 0.15) : NSColor(white: 0.12, alpha: 0.15)).setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = SquirrelMetrics.load().font
        let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        let ink = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(srgbRed: 0.24, green: 0.24, blue: 0.23, alpha: 1)
        let pre = NSMutableAttributedString(string: preedit, attributes: [.font: font, .foregroundColor: ink])
        pre.append(NSAttributedString(string: "‸ ✻", attributes: [.font: font, .foregroundColor: orange]))
        pre.draw(at: NSPoint(x: 17, y: 14))
        var cx: CGFloat = 12
        for (i, c) in cands.enumerated() {
            let s = NSMutableAttributedString(string: "\(i + 1) ", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                 .foregroundColor: i == 0 ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor])
            s.append(NSAttributedString(string: c, attributes: [.font: font, .foregroundColor: i == 0 ? NSColor.white : (dark ? NSColor.white : NSColor.black)]))
            let w = s.size().width + 18
            if i == 0 {
                NSColor(srgbRed: 0.79, green: 0.39, blue: 0.26, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: cx, y: 54, width: w, height: 26), xRadius: 10, yRadius: 10).fill()
            }
            s.draw(at: NSPoint(x: cx + 9, y: 58))
            cx += w + 4
        }
    }
}

final class Demo {
    let panel: NSPanel
    let pv = DemoPanelView()
    weak var ctl: ClawdController?
    var steps: [(CGFloat, String, [String], Bool)] = []   // (时刻, 拼音, 候选, 是否上屏)

    init(ctl: ClawdController) {
        self.ctl = ctl
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = pv
        let seq = ["n", "ni", "ni h", "ni ha", "ni hao"]
        var t: CGFloat = 0.4
        for s in seq { steps.append((t, s, ["你", "你好", "拟好"], false)); t += 0.22 }
        t += 2.2
        steps.append((t, "ni ha", ["你哈", "你", "尼"], false)); t += 0.3
        steps.append((t, "ni hao", ["你好", "拟好", "你"], false)); t += 0.8
        steps.append((t, "ni hao", ["你好", "拟好", "你"], true)); t += 1.0
        for s in ["c", "cl", "cla", "clau", "claud", "claude"] { steps.append((t, s, ["Claude", "Claude Code"], false)); t += 0.2 }
        t += 1.8
        steps.append((t, "claude", ["Claude", "Claude Code"], true)); t += 1.2
        for s in ["z", "zh", "zhu", "zhu m", "zhu mi"] { steps.append((t, s, ["猪咪", "竹米", "主"], false)); t += 0.2 }
        t += 2.0
        steps.append((t, "zhu mi", ["猪咪", "竹米", "主"], true)); t += 2.6
        steps.append((t, "", [], false))
    }

    func run() {
        guard let ctl, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - 180, y: f.midY - 46))
        panel.orderFrontRegardless()
        ctl.demoPanel = { [weak self] in
            guard let self, self.panel.isVisible else { return nil }
            return self.panel.frame
        }
        var commits = 0
        for (t, py, cands, commit) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(t)) { [weak self, weak ctl] in
                guard let self, let ctl else { return }
                if py.isEmpty && !commit {
                    self.panel.orderOut(nil)
                    ctl.demoPanel = nil
                    ctl.receive(RimeState(sid: "demo", composing: false, commits: commits, input: "", preCaret: ""))
                    return
                }
                if commit { commits += 1 }
                self.pv.preedit = py
                self.pv.cands = cands
                self.pv.needsDisplay = true
                ctl.receive(RimeState(sid: "demo", composing: true, commits: commits, input: py.replacingOccurrences(of: " ", with: ""), preCaret: py))
            }
        }
    }
}

// MARK: - 菜单栏与开机自启动

func clawdImage(unit: CGFloat, skin: Skin = .classic, padding: CGFloat = 0) -> NSImage {
    let sprite = buildSkin(skin, Pose())
    let xs = sprite.px.keys.map(\.x), ys = sprite.px.keys.map(\.y)
    let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
    let w = CGFloat(maxX - minX + 1) * unit + padding * 2, h = CGFloat(maxY - minY + 1) * unit + padding * 2
    return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.setShouldAntialias(false)
        for (p, ch) in sprite.px {
            guard let c = PALETTE[ch] else { continue }
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: padding + CGFloat(p.x - minX) * unit, y: padding + CGFloat(p.y - minY) * unit, width: unit, height: unit))
        }
        return true
    }
}

enum LoginItem {
    static let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/local.clawd.companion.plist"

    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentPath)
    }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if !on { try? FileManager.default.removeItem(atPath: agentPath) }
            return nil
        } catch {
            // 退路：写一个 LaunchAgent
            if on {
                let exe = Bundle.main.executablePath ?? ""
                let plist: [String: Any] = ["Label": "local.clawd.companion", "ProgramArguments": [exe],
                                            "RunAtLoad": true, "ProcessType": "Interactive"]
                try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
                if (plist as NSDictionary).write(toFile: agentPath, atomically: true) { return nil }
            } else {
                try? FileManager.default.removeItem(atPath: agentPath)
                return nil
            }
            return error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var ctl: ClawdController!
    var item: NSStatusItem?
    var demo: Demo?
    var settingsWindow: NSWindow?
    lazy var model = SettingsModel(app: self)

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.writePunct()
        ctl = ClawdController()
        updateStatusItem()
        // 第一次启动：默认开机自启
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
            LoginItem.set(true)
        }
        ctl.watcher.read()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.ctl.applySize()
        }
        // 过了零点：「自动」换成今天的皮肤，菜单和设置窗口跟着刷新
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.prefsChanged()
        }
        // 装好后第一次启动时，主动把设置窗口弹出来
        if !UserDefaults.standard.bool(forKey: "didShowSettings2") || CommandLine.arguments.contains("--settings") {
            UserDefaults.standard.set(true, forKey: "didShowSettings2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showSettings() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.writeDiag() }
    }

    /// 在启动台 / 聚焦搜索 / 访达里再次打开 Clawd → 弹出设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func updateStatusItem() {
        if Prefs.showIcon {
            if item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                it.autosaveName = "ClawdCompanionStatusItem"
                it.button?.image = clawdImage(unit: 0.75)
                it.button?.toolTip = "Clawd 伴随"
                item = it
            }
            rebuildMenu()
        } else if let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    func prefsChanged() {
        rebuildMenu()
        ctl.wake()
        model.refresh()
    }

    func rebuildMenu() {
        guard let item else { return }
        let m = NSMenu()
        let title = NSMenuItem(title: Prefs.costume == "auto" ? "Clawd 伴随 · 今天是「\(Prefs.skin.title)」" : "Clawd 伴随", action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        m.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        m.addItem(settings)

        let show = NSMenuItem(title: "显示 Clawd", action: #selector(toggleShow), keyEquivalent: "")
        show.state = Prefs.enabled ? .on : .off
        show.target = self
        m.addItem(show)

        let punct = NSMenuItem(title: "英文标点", action: #selector(togglePunct), keyEquivalent: "")
        punct.state = Prefs.englishPunct ? .on : .off
        punct.toolTip = "勾上：中文模式下输出 , . ? 等英文标点（按 \\ 仍然是顿号）；取消：输出 ，。？ 等中文标点。⌃⇧3 也能临时切换。"
        punct.target = self
        m.addItem(punct)
        m.addItem(.separator())

        let costume = NSMenuItem(title: "装扮", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for (c, name) in [("auto", "自动（每天换一套）")] + Skin.allCases.map({ ($0.rawValue, $0.title) }) {
            let it = NSMenuItem(title: name, action: #selector(pickCostume(_:)), keyEquivalent: "")
            it.representedObject = c
            it.state = Prefs.costume == c ? .on : .off
            it.image = clawdImage(unit: 0.5, skin: Skin(rawValue: c) ?? Prefs.autoSkin())
            it.target = self
            cm.addItem(it)
            if c == "auto" { cm.addItem(.separator()) }
        }
        costume.submenu = cm
        m.addItem(costume)

        let size = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (k, name) in [("s", "小"), ("m", "中"), ("l", "大")] {
            let it = NSMenuItem(title: name, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.representedObject = k
            it.state = Prefs.size == k ? .on : .off
            it.target = self
            sm.addItem(it)
        }
        size.submenu = sm
        m.addItem(size)

        let preview = NSMenuItem(title: "预览动画", action: #selector(runDemo), keyEquivalent: "")
        preview.target = self
        m.addItem(preview)
        m.addItem(.separator())

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isOn ? .on : .off
        login.target = self
        m.addItem(login)

        let rime = NSMenuItem(title: "打开 Rime 配置文件夹", action: #selector(openRime), keyEquivalent: "")
        rime.target = self
        m.addItem(rime)
        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Clawd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        item.menu = m
    }

    @objc func openSettings() { showSettings() }
    @objc func toggleShow() { Prefs.enabled.toggle(); prefsChanged() }
    @objc func togglePunct() { Prefs.englishPunct.toggle(); prefsChanged() }
    @objc func pickCostume(_ s: NSMenuItem) {
        Prefs.costume = s.representedObject as? String ?? "auto"
        prefsChanged()
    }
    @objc func pickSize(_ s: NSMenuItem) {
        Prefs.size = s.representedObject as? String ?? "m"
        ctl.applySize(); prefsChanged()
    }
    @objc func runDemo() {
        demo = Demo(ctl: ctl)
        demo?.run()
        ctl.wake()
    }
    @objc func toggleLogin() {
        model.setLogin(!LoginItem.isOn)
        rebuildMenu()
    }
    @objc func openRime() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Rime")) }

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(m: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Clawd 伴随"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        model.refresh()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 自检：记录菜单栏图标的位置，方便排查「看不到图标」
    func writeDiag() {
        var lines = ["time=\(Date())"]
        if let it = item {
            lines.append("statusItem.isVisible=\(it.isVisible)")
            lines.append("button.window.frame=\(it.button?.window?.frame ?? .zero)")
            lines.append("button.window.visible=\(it.button?.window?.occlusionState.contains(.visible) ?? false)")
        } else {
            lines.append("statusItem=nil (showIcon=\(Prefs.showIcon))")
        }
        for sc in NSScreen.screens {
            lines.append("screen \(sc.localizedName) frame=\(sc.frame) notchLeft=\(sc.auxiliaryTopLeftArea ?? .zero) notchRight=\(sc.auxiliaryTopRightArea ?? .zero)")
        }
        try? lines.joined(separator: "\n").write(toFile: STATE_DIR + "/diag.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - 设置窗口

final class SettingsModel: ObservableObject {
    weak var app: AppDelegate?
    init(app: AppDelegate) { self.app = app }

    @Published var enabled = Prefs.enabled {
        didSet { if enabled != Prefs.enabled { Prefs.enabled = enabled; app?.prefsChanged() } }
    }
    @Published var englishPunct = Prefs.englishPunct {
        didSet { if englishPunct != Prefs.englishPunct { Prefs.englishPunct = englishPunct; app?.prefsChanged() } }
    }
    @Published var showIcon = Prefs.showIcon {
        didSet { if showIcon != Prefs.showIcon { Prefs.showIcon = showIcon; app?.updateStatusItem() } }
    }
    @Published var costume = Prefs.costume {
        didSet { if costume != Prefs.costume { Prefs.costume = costume; app?.prefsChanged() } }
    }
    @Published var today = Prefs.autoSkin()
    @Published var size = Prefs.size {
        didSet { if size != Prefs.size { Prefs.size = size; app?.ctl.applySize(); app?.prefsChanged() } }
    }
    @Published var login = LoginItem.isOn
    @Published var loginError: String?
    @Published var rimeStatus = RimeInstaller.statusText
    @Published var rimeInstalled = RimeInstaller.isInstalled
    @Published var rimeMessage: String?

    func installRime() { rimeMessage = RimeInstaller.install(); refresh() }
    func uninstallRime() { rimeMessage = RimeInstaller.uninstall(); refresh() }

    func refresh() {
        enabled = Prefs.enabled; showIcon = Prefs.showIcon; englishPunct = Prefs.englishPunct
        costume = Prefs.costume; size = Prefs.size; today = Prefs.autoSkin()
        login = LoginItem.isOn
        rimeStatus = RimeInstaller.statusText
        rimeInstalled = RimeInstaller.isInstalled
    }

    func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        login = LoginItem.isOn
    }
}

/// 设置窗口顶部的动画预览：Clawd 在一个小输入框上循环表演全部动作
final class PreviewSpriteView: NSView {
    var skin = Skin.classic
    private var timer: Timer?
    private var t: CGFloat = 0
    private var sparks: [Spark] = []
    private var sparkAt: CGFloat = 0
    private var lastSeg = -1
    override var isFlipped: Bool { true }

    // 只在设置窗口真的看得见时才跑动画；关掉或被完全遮住就停，免得后台白耗 CPU
    override func viewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self)
        if let w = window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: w)
            }
        }
        windowStateChanged(nil)
    }

    @objc private func windowStateChanged(_ n: Notification?) {
        let closing = n?.name == NSWindow.willCloseNotification
        let visible = !closing && (window?.isVisible ?? false) && (window?.occlusionState.contains(.visible) ?? false)
        if visible, timer == nil {
            let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        } else if !visible {
            timer?.invalidate(); timer = nil
        }
    }

    private func step() {
        let dt: CGFloat = 1.0 / 60.0
        t += dt
        sparks = sparks.compactMap { s in
            var s = s; s.age += dt; s.x += s.vx * dt; s.y += s.vy * dt; s.vy += 18 * dt
            return s.age < s.life ? s : nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.976, blue: 0.96, alpha: 1)).setFill()
        bounds.fill()
        // 一个 Claude 风格的小输入框
        let baseY = bounds.height - 34
        let box = NSRect(x: 60, y: baseY, width: bounds.width - 120, height: 70)
        let path = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
        (dark ? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.18, alpha: 1) : .white).setFill(); path.fill()
        (dark ? NSColor(white: 0.87, alpha: 0.15) : NSColor(white: 0.12, alpha: 0.15)).setStroke(); path.lineWidth = 1; path.stroke()

        let unit: CGFloat = 3
        let L: CGFloat = 8.8
        let k = t.truncatingRemainder(dividingBy: L)
        var pose = Pose()
        var xOff: CGFloat = 0, lift: CGFloat = 0, facing = 1, exclaim = false, moving = false, asleep = false
        var idleGlyph: [String]? = nil
        let seg: Int
        if k < 2.4 {                       // 横着爬来爬去
            seg = 0
            let ph = k / 2.4 * 2 * .pi
            xOff = sin(ph) * 46; facing = cos(ph) >= 0 ? 1 : -1; moving = true
            pose.look = facing; pose.legs = [1, 0, 2, 0][Int(k / 0.08) % 4]
        } else if k < 3.8 {                // 闲时小动作：每一轮换一个
            seg = 1
            pose.breathe = Int(k / 0.5) % 2 == 1
            if k > 2.55, let r = idleMove(Int(t / L) % IDLE_COUNT, k - 2.55, &pose, &lift) { idleGlyph = r.glyph }
        } else if k < 5.3 {                // 打出 claude：挥钳欢呼
            seg = 2
            pose.eyes = .happy
            let ph = Int(k / 0.16) % 2; pose.armL = ph; pose.armR = 1 - ph
            if t > sparkAt {
                sparkAt = t + 0.14
                sparks.append(Spark(x: CGFloat.random(in: -2...26), y: CGFloat.random(in: -6...2), vx: CGFloat.random(in: -6...6),
                                    vy: -14, life: 0.6, color: Bool.random() ? "O" : "L"))
            }
        } else if k < 5.8 {                // 上屏：跳！
            seg = 3
            let tt = (k - 5.3) / 0.42
            if tt < 1 { lift = 10 * 4 * tt * (1 - tt) }
            pose.armL = 1; pose.armR = 1; pose.eyes = .happy
        } else if k < 6.6 {                // 退格：吓一跳
            seg = 4
            pose.eyes = .wide; pose.look = -1; exclaim = true
            let tt = (k - 5.8) / 0.22
            if tt < 1 { lift = 4 * 4 * tt * (1 - tt) }
        } else {                           // 打瞌睡
            seg = 5
            asleep = true
            pose = Pose(eyes: .closed, sit: true, breathe: !skin.floats && Int(k / 0.9) % 2 == 1)
            lift = -CGFloat(skin.sleepSink)
        }
        if seg == 3 && lastSeg != 3 {
            for i in 0..<8 {
                let a = CGFloat(i) / 8 * .pi * 2
                sparks.append(Spark(x: 12, y: 2, vx: cos(a) * 20, vy: sin(a) * 20 - 10, life: 0.6, color: i % 3 == 0 ? "L" : "O"))
            }
        }
        lastSeg = seg

        var siuText = false
        if skin == .siu {
            if seg == 3 {
                let tt = (k - 5.3) / 0.42
                lift *= 1.6
                if tt > 0.3 && tt < 0.8 { pose.back = true }
            } else if seg == 4 {
                pose = Pose(eyes: .happy, armL: 2, armR: 2); pose.wide = true
                exclaim = false; lift = 0; siuText = true
            }
        }
        let flip = skin.mirrors && facing > 0
        if skin.floats { pose.legs = 0; pose.breathe = false }
        if skin == .side && (moving || seg == 2) { pose.tap = 1 + Int(t / 0.07) % 2 }
        if flip { pose.look = -pose.look }
        var sprite = buildSkin(skin, pose)
        if flip { sprite = sprite.mirrored(23) }
        if skin.floats {
            lift += 5 + (1.5 * sin(t * 3.2)).rounded()
            if moving && t > sparkAt {
                sparkAt = t + 0.05
                sparks.append(Spark(x: facing > 0 ? -12 : 36, y: CGFloat.random(in: 12...17),
                                    vx: CGFloat(-facing) * CGFloat.random(in: 8...16), vy: CGFloat.random(in: -4...4),
                                    life: 0.5, color: ["L", "Y", "O"].randomElement()!))
            }
        }
        if exclaim { addExclaim(&sprite, at: skin.exclaimAt(facing)) }
        if asleep { addZzz(&sprite, clock: t, at: skin.zzzAt(facing)) }
        if siuText { addSiu(&sprite) }
        if let g = idleGlyph { sprite.stamp(g, 15, skin.headTop - g.count - 2) }
        if skin == .striker {
            addBall(&sprite, clock: t, moving: moving, facing: facing, asleep: asleep, lift: Int(lift.rounded()))
        }

        let ox = (bounds.midX + xOff - 12 * unit).rounded()
        let oy = baseY + 1 - 16 * unit - (lift.rounded()) * unit
        ctx.setShouldAntialias(false)
        var byColor: [Character: [CGRect]] = [:]
        for (p, ch) in sprite.px {
            byColor[ch, default: []].append(CGRect(x: ox + CGFloat(p.x) * unit, y: oy + CGFloat(p.y) * unit, width: unit, height: unit))
        }
        for (ch, rects) in byColor { if let c = PALETTE[ch] { ctx.setFillColor(c); ctx.fill(rects) } }
        for s in sparks {
            let kk = s.age / s.life
            let base = PALETTE[s.color] ?? rgb(0xD97757)
            ctx.setFillColor(base.copy(alpha: max(0, 1 - kk * kk)) ?? base)
            let cx = ox + s.x.rounded() * unit, cy = oy + s.y.rounded() * unit
            ctx.fill(sparkCells(s).map { CGRect(x: cx + $0.0 * unit, y: cy + $0.1 * unit, width: unit, height: unit) })
        }
    }
}

struct ClawdPreview: NSViewRepresentable {
    var skin: Skin
    func makeNSView(context: Context) -> PreviewSpriteView { PreviewSpriteView() }
    func updateNSView(_ v: PreviewSpriteView, context: Context) { v.skin = skin }
}

/// 皮肤选择：一排排带缩略图的小方块
struct SkinGrid: View {
    @Binding var selection: String
    var today: Skin
    static let orange = Color(red: 0.79, green: 0.39, blue: 0.26)

    var body: some View {
        let items = [("auto", "自动", today)] + Skin.allCases.map { ($0.rawValue, $0.title, $0) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(items, id: \.0) { id, name, skin in
                let on = selection == id
                Button { selection = id } label: {
                    VStack(spacing: 3) {
                        Image(nsImage: clawdImage(unit: 1, skin: skin))
                            .interpolation(.none)
                            .frame(height: 30, alignment: .bottom)
                        Text(name).font(.caption).foregroundStyle(on ? Self.orange : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Self.orange.opacity(0.13) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Self.orange : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    var skinNow: Skin { Skin(rawValue: m.costume) ?? m.today }

    var body: some View {
        VStack(spacing: 0) {
            ClawdPreview(skin: skinNow)
                .frame(height: 150)
            Form {
                Section {
                    Toggle("打字时显示 Clawd", isOn: $m.enabled)
                    SkinGrid(selection: $m.costume, today: m.today)
                    Picker("大小", selection: $m.size) {
                        Text("小").tag("s"); Text("中").tag("m"); Text("大").tag("l")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("「自动」每天换一套，九套皮肤轮着来（今天是「\(m.today.title)」）；万圣节固定女巫，平安夜和圣诞节固定圣诞帽。停手几秒 Clawd 会打瞌睡；打出「猪咪」试试看。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("中文模式下使用英文标点", isOn: $m.englishPunct)
                } footer: {
                    Text("打开后，打中文时 , . ? ! 等都输出英文标点；关掉则输出 ，。？！。顿号例外：按 \\ 始终输出「、」。菜单栏里也能一键切换，⌃⇧3 可以临时切换。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text(m.rimeStatus).foregroundStyle(m.rimeInstalled ? .primary : .secondary)
                        Spacer()
                        if m.rimeInstalled {
                            Button("卸载") { m.uninstallRime() }
                            Button("重新安装") { m.installRime() }
                        } else {
                            Button("安装到鼠须管") { m.installRime() }
                                .buttonStyle(.borderedProminent).tint(Color(red: 0.79, green: 0.39, blue: 0.26))
                        }
                    }
                    if let msg = m.rimeMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("鼠须管主题与小螃蟹脚本")
                } footer: {
                    Text("会安装 Claude 风格的候选框主题和 clawd.lua；原有配置自动备份，卸载时还原。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("开机自动启动", isOn: Binding(get: { m.login }, set: { m.setLogin($0) }))
                    Toggle("在菜单栏显示图标", isOn: $m.showIcon)
                    if let e = m.loginError {
                        Text("开机启动设置失败：\(e)").font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("菜单栏放不下时，macOS 会把新图标收进菜单栏左侧的「»」里，点开「»」就能找到 Clawd；按住 ⌘ 拖动图标可以调整顺序。另外，随时在启动台或聚焦搜索里打开「Clawd」都能回到这个窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("预览动画") { m.app?.runDemo() }
                        Button("打开 Rime 配置") { m.app?.openRime() }
                        Spacer()
                        Button("退出 Clawd", role: .destructive) { NSApp.terminate(nil) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 480, height: 900)
    }
}

// MARK: - 命令行工具：导出图标 / 动画帧（自检用）

func savePNG(_ img: NSImage, _ path: String, pixels: NSSize? = nil) {
    let size = pixels ?? img.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    img.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func renderIcon(_ path: String, px: Int) {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
        let inset = s * 0.1
        let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
        NSGradient(starting: NSColor(srgbRed: 0.94, green: 0.92, blue: 0.88, alpha: 1),
                   ending: NSColor(srgbRed: 0.99, green: 0.98, blue: 0.96, alpha: 1))?.draw(in: bg, angle: -90)
        NSColor(white: 0, alpha: 0.08).setStroke(); bg.lineWidth = s / 256; bg.stroke()
        let unit = (r.width * 0.66 / 24).rounded(.down)
        let c = clawdImage(unit: unit)
        c.draw(in: NSRect(x: r.midX - c.size.width / 2, y: r.midY - c.size.height / 2 + unit, width: c.size.width, height: c.size.height))
        return true
    }
    savePNG(img, path, pixels: NSSize(width: s, height: s))
}

func renderSheet(_ path: String) {
    var poses: [(String, Sprite)] = []
    poses.append(("站立", buildClawd(Pose())))
    poses.append(("迈步1", buildClawd(Pose(look: 1, legs: 1))))
    poses.append(("迈步2", buildClawd(Pose(look: 1, legs: 2))))
    poses.append(("眨眼", buildClawd(Pose(eyes: .closed))))
    poses.append(("吓一跳", buildClawd(Pose(look: -1, eyes: .wide))))
    poses.append(("欢呼", buildClawd(Pose(eyes: .happy, armL: 1, armR: 1))))
    poses.append(("挥钳", buildClawd(Pose(eyes: .happy, armL: 1))))
    poses.append(("女巫", buildWitch(Pose())))
    poses.append(("女巫→", buildWitch(Pose(look: 1)).mirrored(23)))
    poses.append(("电脑", buildSide(Pose())))
    var typing = Pose(legs: 1); typing.tap = 1
    poses.append(("电脑打字", buildSide(typing)))
    poses.append(("电脑欢呼→", buildSide(Pose(eyes: .happy, armL: 1, armR: 1)).mirrored(23)))
    var napSide = Sprite(); napSide.merge(buildSide(Pose(eyes: .closed, sit: true)), dy: 3)
    addZzz(&napSide, clock: 0.3, at: Skin.side.zzzAt(-1))
    poses.append(("电脑睡觉", napSide))
    var q = Pose(look: -1); var ql: CGFloat = 0
    let qg = idleMove(4, 0.5, &q, &ql)?.glyph ?? []
    var asking = buildClawd(q); asking.stamp(qg, 15, -qg.count - 2)
    poses.append(("问号", asking))
    var hm = Pose(); let ng = idleMove(5, 0.1, &hm, &ql)?.glyph ?? []
    var humming = buildClawd(hm); humming.stamp(ng, 15, -ng.count - 2)
    poses.append(("哼歌", humming))
    var st = Pose(); _ = idleMove(0, 0.5, &st, &ql)
    poses.append(("伸懒腰", buildClawd(st)))
    poses.append(("瞌睡", buildSkin(.sleepy, Pose())))
    var nap = Sprite(); nap.merge(buildSkin(.sleepy, Pose(eyes: .closed, sit: true)), dy: 2)
    addZzz(&nap, clock: 0.3, at: Skin.sleepy.zzzAt(1))
    poses.append(("瞌睡 Zzz", nap))
    poses.append(("圣诞", buildSkin(.santa, Pose())))
    poses.append(("学士", buildSkin(.scholar, Pose())))
    poses.append(("墨镜", buildSkin(.shades, Pose())))
    var slip = buildSkin(.shades, Pose(eyes: .wide)); addExclaim(&slip, at: Skin.shades.exclaimAt(1))
    poses.append(("墨镜吓一跳", slip))
    var striker = buildSkin(.striker, Pose(look: 1)); addBall(&striker, clock: 0.2, moving: false, facing: 1, asleep: false, lift: 0)
    poses.append(("球王颠球", striker))
    var dribble = buildSkin(.striker, Pose(look: 1, legs: 1)); addBall(&dribble, clock: 0, moving: true, facing: 1, asleep: false, lift: 0)
    poses.append(("球王带球", dribble))
    poses.append(("Siu", buildSkin(.siu, Pose())))
    var turn = Pose(armL: 1, armR: 1); turn.back = true
    poses.append(("Siu 转身", buildSkin(.siu, turn)))
    var land = Pose(eyes: .happy, armL: 2, armR: 2); land.wide = true
    var landed = buildSkin(.siu, land); addSiu(&landed)
    poses.append(("Siu 落地", landed))
    var lovey = buildClawd(Pose(eyes: .happy, armL: 1)); lovey.stamp(HEART_L, 8, -13)
    poses.append(("猪咪", lovey))
    let unit: CGFloat = 6, cellW: CGFloat = 64 * unit, cellH: CGFloat = 44 * unit
    let cols = 4
    let rows = (poses.count + cols - 1) / cols
    let img = NSImage(size: NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows)), flipped: true) { b in
        NSColor(srgbRed: 0.98, green: 0.976, blue: 0.96, alpha: 1).setFill(); b.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        for (i, (name, sp)) in poses.enumerated() {
            let ox = CGFloat(i % cols) * cellW + 18 * unit, oy = CGFloat(i / cols) * cellH + 20 * unit
            ctx.setShouldAntialias(false)
            for (p, ch) in sp.px {
                guard let c = PALETTE[ch] else { continue }
                ctx.setFillColor(c)
                ctx.fill(CGRect(x: ox + CGFloat(p.x) * unit, y: oy + CGFloat(p.y) * unit, width: unit, height: unit))
            }
            ctx.setShouldAntialias(true)
            (name as NSString).draw(at: NSPoint(x: CGFloat(i % cols) * cellW + 12, y: CGFloat(i / cols) * cellH + 8),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.gray])
        }
        return true
    }
    savePNG(img, path)
}

// MARK: - 入口

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 2 < args.count {
    renderIcon(args[i + 1], px: Int(args[i + 2]) ?? 1024); exit(0)
}
/// 离屏录制演示动画：逐帧渲染「假候选框 + Clawd」到 PNG，再由脚本合成 GIF
func renderDemo(_ dir: String, skin: Skin, mode: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Prefs.forced = skin
    let ctl = ClawdController(watch: false, offscreen: true)
    let W: CGFloat = 400, H: CGFloat = mode == "love" ? 250 : 190, scale: CGFloat = 2
    let panelRect = NSRect(x: 20, y: 30, width: 360, height: 92)
    let pv = DemoPanelView(frame: NSRect(origin: .zero, size: panelRect.size))
    pv.appearance = NSAppearance(named: .aqua)
    ctl.view.appearance = NSAppearance(named: .aqua)
    var panelVisible = false
    ctl.demoPanel = { panelVisible ? panelRect : nil }

    // (时刻, 拼音, 候选, 是否上屏)
    var script: [(CGFloat, String, [String], Bool)] = []
    var t: CGFloat = 0.5
    for py in ["n", "ni", "ni h", "ni ha", "ni hao"] { script.append((t, py, ["你", "你好", "拟好", "泥"], false)); t += 0.24 }
    t += 1.9
    script.append((t, "ni ha", ["你哈", "你", "尼"], false)); t += 0.5
    script.append((t, "ni hao", ["你好", "拟好", "你"], false)); t += 0.7
    script.append((t, "ni hao", ["你好", "拟好", "你"], true)); t += 0.9
    for py in ["c", "cl", "cla", "clau", "claud", "claude"] { script.append((t, py, ["Claude", "Claude Code", "Claude Opus"], false)); t += 0.2 }
    t += 1.8
    script.append((t, "claude", ["Claude", "Claude Code"], true)); t += 1.1
    if mode == "love" {          // 打「猪咪」：爱心特效
        script.removeAll(); t = 0.4
        for py in ["z", "zh", "zhu", "zhu m", "zhu mi"] { script.append((t, py, ["猪咪", "竹米", "主"], false)); t += 0.22 }
        t += 1.8
        script.append((t, "zhu mi", ["猪咪", "竹米", "主"], true)); t += 2.6
    } else if mode == "nap" {    // 停手打瞌睡，再被吵醒
        script.removeAll(); t = 0.4
        for py in ["w", "wo", "wo k", "wo ku", "wo kun"] { script.append((t, py, ["我困", "我", "窝"], false)); t += 0.24 }
        t += skin.dozeAfter + 3.2
        script.append((t, "wo kun l", ["我困了", "我困", "我"], false)); t += 0.3
        script.append((t, "wo kun le", ["我困了", "我困", "我"], false)); t += 1.0
        script.append((t, "wo kun le", ["我困了", "我困", "我"], true)); t += 1.0
    }
    let total = t

    let fps: CGFloat = 25
    var commits = 0, si = 0, frame = 0
    var now: CGFloat = 0
    while now < total {
        while si < script.count && script[si].0 <= now {
            let (_, py, cands, commit) = script[si]
            if commit {
                commits += 1
                ctl.receive(RimeState(sid: "demo", composing: false, commits: commits, input: "", preCaret: ""))
                panelVisible = false
            } else {
                panelVisible = true
                pv.preedit = py; pv.cands = cands
                ctl.receive(RimeState(sid: "demo", composing: true, commits: commits, input: py.replacingOccurrences(of: " ", with: ""), preCaret: py))
            }
            si += 1
        }
        ctl.tick(fixedDT: 1 / fps)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.941, green: 0.933, blue: 0.902, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        if panelVisible, let cg = NSGraphicsContext.current?.cgContext {
            // 直接把假候选框画进画布（带阴影），圆角外保持背景色
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -5), blur: 14, color: CGColor(gray: 0, alpha: 0.16))
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.translateBy(x: panelRect.minX, y: panelRect.maxY)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            pv.draw(pv.bounds)
            NSGraphicsContext.restoreGraphicsState()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        if ctl.alpha > 0, let sr = ctl.view.bitmapImageRepForCachingDisplay(in: ctl.view.bounds) {
            ctl.view.cacheDisplay(in: ctl.view.bounds, to: sr)
            NSGraphicsContext.current?.imageInterpolation = .none
            sr.draw(in: NSRect(origin: ctl.window.frame.origin, size: ctl.view.bounds.size), from: .zero,
                    operation: .sourceOver, fraction: ctl.alpha, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", dir, frame)))
        frame += 1
        now += 1 / fps
    }
}

/// 参考造型：Mac 版和 Windows 版必须逐像素一致（windows/sprites.ref.txt 由这里生成，CI 用它比对）
func referencePoses() -> [(String, Sprite)] {
    var r: [(String, Sprite)] = []
    r.append(("stand", buildClawd(Pose())))
    r.append(("walk1", buildClawd(Pose(look: 1, legs: 1))))
    r.append(("walk2", buildClawd(Pose(look: 1, legs: 2))))
    r.append(("blink", buildClawd(Pose(eyes: .closed))))
    r.append(("breathe", buildClawd(Pose(look: -1, breathe: true))))
    var surprised = buildClawd(Pose(look: -1, eyes: .wide)); addExclaim(&surprised, witch: false)
    r.append(("surprised", surprised))
    r.append(("cheer", buildClawd(Pose(eyes: .happy, armL: 1, armR: 1))))
    r.append(("wave", buildClawd(Pose(eyes: .happy, armL: 1))))
    r.append(("witch", buildWitch(Pose())))
    r.append(("witch-right", buildWitch(Pose(look: 1)).mirrored(23)))
    var ws = buildWitch(Pose(look: -1, eyes: .wide)); addExclaim(&ws, witch: true)
    r.append(("witch-surprised", ws))
    r.append(("witch-cheer", buildWitch(Pose(eyes: .happy, armL: 1, armR: 1))))
    return r
}

func dumpSprites(_ path: String) {
    var out = ""
    for (name, sp) in referencePoses() {
        let xs = sp.px.keys.map(\.x), ys = sp.px.keys.map(\.y)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        out += "\(name) \(x0) \(y0) \(x1 - x0 + 1) \(y1 - y0 + 1)\n"
        for y in y0...y1 {
            out += String((x0...x1).map { sp.px[P(x: $0, y: y)] ?? "." }) + "\n"
        }
    }
    try? out.write(toFile: path, atomically: true, encoding: .utf8)
}

if let i = args.firstIndex(of: "--dump-sprites"), i + 1 < args.count { dumpSprites(args[i + 1]); exit(0) }
if args.contains("--install-rime") { print(RimeInstaller.install()); exit(0) }
if args.contains("--uninstall-rime") { print(RimeInstaller.uninstall()); exit(0) }
if let i = args.firstIndex(of: "--render-demo"), i + 2 < args.count {
    renderDemo(args[i + 1], skin: Skin(rawValue: args[i + 2]) ?? .classic, mode: i + 3 < args.count ? args[i + 3] : ""); exit(0)
}
if let i = args.firstIndex(of: "--render-sheet"), i + 1 < args.count {
    renderSheet(args[i + 1]); exit(0)
}

// 只跑一个实例
let me = Bundle.main.bundleIdentifier ?? "local.clawd.companion"
if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if args.contains("--demo") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.runDemo() }
}
app.run()
