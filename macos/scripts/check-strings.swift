// 检查界面文字的翻译，由 check-strings.sh 调用（它先构建一遍）。
// 用法：swift scripts/check-strings.swift <macos 目录> <构建中间产物目录>
//
// 要翻译的键来自编译器构建时导出的 .stringsdata：代码里每个 Text("…")、String(localized: "…") 都在里面，
// 插值已经换成了格式占位符（%@、%lld），和运行时查的键一模一样。检查这些：
// - 每个键在每种语言的 Localizable.strings 里都有译文，译文里没有代码已经不用的键；
// - 每个键都在带 bundle: .module 的调用里查（不带的话会去 App 主 bundle 里找，永远显示英文）；
// - 译文的占位符和原文一致；英文原文用 ’ 和 …，不用 ' 和 ...；
// - Info.plist 的 CFBundleLocalizations、InfoPlist.strings 和各 target 的翻译是同一组语言。
import Foundation

let fileManager = FileManager.default
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("用法：swift scripts/check-strings.swift <macos 目录> <构建中间产物目录>")
    exit(2)
}
/// 解开符号链接（/tmp → /private/tmp），和编译器记下的源文件路径比较时才对得上
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

let packageURL = URL(fileURLWithPath: realPath(arguments[1]), isDirectory: true)
let buildPath = URL(fileURLWithPath: arguments[2], relativeTo: packageURL).path
let buildURL = URL(fileURLWithPath: realPath(buildPath), isDirectory: true)
let sourcesPath = packageURL.appendingPathComponent("Sources").path + "/"

var problems: [String] = []

/// 代码里用到一个键的地方
struct Use {
    var key: String
    /// 英文原文：一般就是键本身；count.* 这种另起名字的键是 defaultValue
    var english: String
    var table: String
    /// 相对 Sources/ 的路径
    var file: String
    var line: Int
    var column: Int

    var place: String { "\(file):\(line)" }
}

// MARK: - 读文件

/// .strings 文件：键 → 译文。顺便找出重复的键（解析时后一个会悄悄盖掉前一个）
func loadStrings(_ url: URL) -> (values: [String: String], duplicates: [String])? {
    guard let data = try? Data(contentsOf: url),
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
          let text = String(data: data, encoding: .utf8) else { return nil }
    let pattern = try! NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
    var counts: [String: Int] = [:]
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let raw = String(text[Range(match.range(at: 1), in: text)!])
        let key = raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#)
        counts[key, default: 0] += 1
    }
    return (values, counts.filter { $0.value > 1 }.map(\.key).sorted())
}

func lprojLanguages(in directory: String) -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".lproj") }
        .map { String($0.dropLast(".lproj".count)) }
        .sorted()
}

// MARK: - 格式占位符

let placeholderPattern = try! NSRegularExpression(
    pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAF%])"#)

/// 参数位置 → 类型（“@”“lld”）。不带位置的按出现顺序编号，%% 不算
func placeholders(_ text: String) -> [Int: String] {
    var result: [Int: String] = [:]
    var next = 1
    for match in placeholderPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let conversion = group(3), conversion != "%" else { continue }
        let position: Int
        if let explicit = group(1).flatMap(Int.init) {
            position = explicit
        } else {
            position = next
            next += 1
        }
        result[position] = (group(2) ?? "") + conversion
    }
    return result
}

// MARK: - 有没有指定 bundle

let quote = UInt8(ascii: "\"")
let backslash = UInt8(ascii: "\\")

/// 跳过从 start 开始的字符串字面量（插值里可以再有括号和字符串），返回它后面的位置
func skipString(_ bytes: [UInt8], from start: Int) -> Int? {
    guard start < bytes.count, bytes[start] == quote else { return nil }
    if start + 2 < bytes.count, bytes[start + 1] == quote, bytes[start + 2] == quote { return nil } // 多行字面量：不支持
    var index = start + 1
    while index < bytes.count {
        switch bytes[index] {
        case backslash where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "("):
            var depth = 1
            index += 2
            while index < bytes.count, depth > 0 {
                if bytes[index] == quote {
                    guard let end = skipString(bytes, from: index) else { return nil }
                    index = end
                    continue
                }
                if bytes[index] == UInt8(ascii: "(") { depth += 1 }
                if bytes[index] == UInt8(ascii: ")") { depth -= 1 }
                index += 1
            }
        case backslash:
            index += 2
        case quote:
            return index + 1
        case UInt8(ascii: "\n"):
            return nil
        default:
            index += 1
        }
    }
    return nil
}

/// 从键的字面量往后读到所在调用的右括号，看这个调用的参数里有没有 bundle: .module。读不懂时返回 nil
func callNamesModuleBundle(_ bytes: [UInt8], literalAt start: Int) -> Bool? {
    guard var index = skipString(bytes, from: start) else { return nil }
    var depth = 0
    var arguments: [UInt8] = []
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case quote:
            guard let end = skipString(bytes, from: index) else { return nil }
            index = end
            continue
        case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
            while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            continue
        case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
            depth += 1
        case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
            if depth == 0 {
                let text = String(decoding: arguments, as: UTF8.self).filter { !$0.isWhitespace }
                return text.contains(",bundle:.module")
            }
            depth -= 1
        default:
            if depth == 0 { arguments.append(byte) }
        }
        index += 1
    }
    return false
}

var sourceCache: [String: (bytes: [UInt8], lineStarts: [Int])] = [:]

func source(_ file: String) -> (bytes: [UInt8], lineStarts: [Int])? {
    if let cached = sourceCache[file] { return cached }
    guard let data = fileManager.contents(atPath: sourcesPath + file) else { return nil }
    let bytes = [UInt8](data)
    var lineStarts = [0]
    for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(index + 1) }
    sourceCache[file] = (bytes, lineStarts)
    return (bytes, lineStarts)
}

// MARK: - 编译器导出的键

guard let enumerator = fileManager.enumerator(at: buildURL, includingPropertiesForKeys: nil) else {
    print("找不到 \(buildURL.path)：先在 macos 目录里运行 swift build -c release")
    exit(1)
}
var usesByTarget: [String: [Use]] = [:]
var seen = Set<String>()
var stringsdataCount = 0
for case let url as URL in enumerator where url.pathExtension == "stringsdata" {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sourcePath = (json["source"] as? String).map(realPath), sourcePath.hasPrefix(sourcesPath),
          fileManager.fileExists(atPath: sourcePath), // 删掉的源文件留下的旧导出不算
          let tables = json["tables"] as? [String: [[String: Any]]] else { continue }
    stringsdataCount += 1
    let file = String(sourcePath.dropFirst(sourcesPath.count))
    let target = String(file.prefix { $0 != "/" })
    for (table, entries) in tables {
        for entry in entries {
            guard let key = entry["key"] as? String,
                  let location = entry["location"] as? [String: Int],
                  let line = location["startingLine"], let column = location["startingColumn"],
                  seen.insert("\(file):\(line):\(column)").inserted // 每种 CPU 架构各有一份
            else { continue }
            let english = entry["value"] as? String ?? key
            usesByTarget[target, default: []].append(
                Use(key: key, english: english, table: table, file: file, line: line, column: column))
        }
    }
}
guard stringsdataCount > 0 else {
    print("\(buildURL.path) 里没有编译器导出的 .stringsdata：要用 Swift Build 构建系统（swift build --build-system swiftbuild），"
          + "Package.swift 里要有 defaultLocalization")
    exit(1)
}

// MARK: - 逐个 target 检查

let infoURL = packageURL.appendingPathComponent("Resources/Info.plist")
let info = NSDictionary(contentsOf: infoURL) as? [String: Any] ?? [:]
let declaredLanguages = Set(info["CFBundleLocalizations"] as? [String] ?? [])
let developmentLanguage = info["CFBundleDevelopmentRegion"] as? String ?? "?"

var summary: [String] = []
let targets = ((try? fileManager.contentsOfDirectory(atPath: sourcesPath)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
for target in targets {
    let uses = (usesByTarget[target] ?? []).sorted { ($0.file, $0.line, $0.column) < ($1.file, $1.line, $1.column) }
    let resourcesPath = sourcesPath + target + "/Resources"
    let languages = lprojLanguages(in: resourcesPath).filter {
        fileManager.fileExists(atPath: "\(resourcesPath)/\($0).lproj/Localizable.strings")
    }
    if uses.isEmpty && languages.isEmpty { continue }
    if languages.isEmpty {
        let examples = uses.prefix(5).map { "\"\($0.key)\"（\($0.place)）" }.joined(separator: "、")
        problems.append("\(target)：代码里有要翻译的文字，但没有 Resources/<语言>.lproj/Localizable.strings：\(examples)")
        continue
    }

    // 每个键：同一张表、同一个英文原文、查找时带 bundle、英文的标点
    var englishByKey: [String: String] = [:]
    for use in uses {
        if use.table != "Localizable" {
            problems.append("\(target)：\"\(use.key)\" 用了表 \(use.table)，这里只用默认的 Localizable（\(use.place)）")
        }
        if let english = englishByKey[use.key], english != use.english {
            problems.append("\(target)：\"\(use.key)\" 在不同地方的英文原文不一样：\"\(english)\" 和 \"\(use.english)\"（\(use.place)）")
        }
        englishByKey[use.key] = use.english
        if use.english.contains("'") || use.english.contains("...") {
            problems.append("\(target)：英文要用 ’ 和 …，不用 ' 和 ...：\"\(use.english)\"（\(use.place)）")
        }
        guard let text = source(use.file), use.line - 1 < text.lineStarts.count else {
            problems.append("\(target)：读不到 \(use.file)")
            continue
        }
        switch callNamesModuleBundle(text.bytes, literalAt: text.lineStarts[use.line - 1] + use.column - 1) {
        case true?: break
        case false?:
            problems.append("\(target)：\"\(use.key)\" 查找时没有指定 bundle: .module，会去 App 主 bundle 里找、永远显示英文。"
                            + "改用 Text(\"…\", bundle: .module) 或 String(localized: \"…\", bundle: .module)"
                            + "（\(use.place)）")
        case nil:
            problems.append("\(target)：看不懂 \"\(use.key)\" 所在的调用（\(use.place)），换成普通的单行字符串")
        }
    }

    // 每种语言的译文
    let usedKeys = Set(englishByKey.keys)
    var counts: [String] = []
    for language in languages {
        let label = "\(target)/\(language)"
        let stringsURL = URL(fileURLWithPath: "\(resourcesPath)/\(language).lproj/Localizable.strings")
        guard let loaded = loadStrings(stringsURL) else {
            problems.append("\(label)：Localizable.strings 解析不了（要 UTF-8，每行 \"键\" = \"译文\";）")
            continue
        }
        let values = loaded.values
        for key in loaded.duplicates { problems.append("\(label)：\"\(key)\" 重复了") }
        var missing = Set<String>()
        for use in uses where values[use.key] == nil && missing.insert(use.key).inserted {
            problems.append("\(label)：缺少 \"\(use.key)\" 的译文（\(use.place)）")
        }
        for key in values.keys.sorted() where !usedKeys.contains(key) {
            problems.append("\(label)：\"\(key)\" 代码里已经不用了，删掉这条译文")
        }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let english = englishByKey[key] else { continue }
            if value.isEmpty && !english.isEmpty {
                problems.append("\(label)：\"\(key)\" 的译文是空的")
            }
            if placeholders(value) != placeholders(english) {
                problems.append("\(label)：\"\(key)\" 的占位符和英文原文 \"\(english)\" 对不上：\"\(value)\"")
            }
        }
        counts.append("\(language) \(values.count) 条")
    }
    summary.append("\(target)：\(usedKeys.count) 个键，" + counts.joined(separator: "、"))

    let translated = Set(languages).union([developmentLanguage])
    if translated != declaredLanguages {
        problems.append("\(target)：翻译的语言 \(translated.sorted()) 和 Info.plist 的 CFBundleLocalizations "
                        + "\(declaredLanguages.sorted()) 不一致")
    }
}

// MARK: - App 的 Info.plist

let appResourcesPath = packageURL.appendingPathComponent("Resources").path
let appLanguages = Set(lprojLanguages(in: appResourcesPath))
if !declaredLanguages.contains(developmentLanguage) {
    problems.append("Info.plist：CFBundleDevelopmentRegion \(developmentLanguage) 不在 CFBundleLocalizations 里")
}
if appLanguages != declaredLanguages {
    problems.append("Resources：InfoPlist.strings 的语言 \(appLanguages.sorted()) 和 CFBundleLocalizations "
                    + "\(declaredLanguages.sorted()) 不一致")
}
var infoKeys: Set<String>?
for language in appLanguages.sorted() {
    let stringsURL = URL(fileURLWithPath: "\(appResourcesPath)/\(language).lproj/InfoPlist.strings")
    guard let loaded = loadStrings(stringsURL) else {
        problems.append("Resources/\(language).lproj：没有 InfoPlist.strings，或者解析不了")
        continue
    }
    let values = loaded.values
    for key in loaded.duplicates { problems.append("Resources/\(language).lproj/InfoPlist.strings：\"\(key)\" 重复了") }
    for key in values.keys where info[key] == nil {
        problems.append("Resources/\(language).lproj/InfoPlist.strings：Info.plist 里没有 \(key)")
    }
    if let infoKeys, infoKeys != Set(values.keys) {
        problems.append("Resources/\(language).lproj/InfoPlist.strings：和其他语言翻译的键不一样")
    }
    infoKeys = infoKeys ?? Set(values.keys)
}

// MARK: - 结果

if problems.isEmpty {
    print("翻译检查通过")
    summary.forEach { print("  \($0)") }
    exit(0)
}
problems.forEach { print($0) }
print("共 \(problems.count) 个问题")
exit(1)
