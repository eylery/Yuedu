import Foundation
import CoreFoundation
import CommonCrypto
import Security
import CoreGraphics
import CoreText
import ImageIO

/// JSON-only native operations for the isolated reading-rule runtime.
/// Binary arguments/results are arrays of unsigned bytes. Java signed bytes are
/// accepted on input as well; no imported code or filesystem paths are executed.
enum LegadoNativeUtilities {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    private static let maximumBytes = 16 * 1_024 * 1_024

    static func call(_ method: String, arguments: [Any]) throws -> Any {
        func argument(_ index: Int) throws -> Any {
            guard arguments.indices.contains(index) else { throw Failure.invalid("\(method)：缺少参数 \(index + 1)") }
            return arguments[index]
        }
        func text(_ index: Int) throws -> String {
            guard let value = try argument(index) as? String else { throw Failure.invalid("\(method)：需要字符串参数") }
            return value
        }
        func data(_ index: Int) throws -> Data { try bytes(argument(index)) }
        switch method {
        case "encode", "strToBytes": return try Array(encode(text(0), charset: arguments.count > 1 ? text(1) : "UTF-8"))
        case "decode", "bytesToStr": return try decode(data(0), charset: arguments.count > 1 ? text(1) : "UTF-8")
        case "base64Encode": return try data(0).base64EncodedString()
        case "base64Decode":
            let input = try text(0).filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard input.utf8.count <= maximumBytes * 4 / 3 + 4 else { throw Failure.invalid("Base64 数据过大") }
            let padded = input + String(repeating: "=", count: (4 - input.count % 4) % 4)
            guard let result = Data(base64Encoded: padded), result.count <= maximumBytes else { throw Failure.invalid("Base64 数据无效或过大") }
            return Array(result)
        case "hexEncode": return try data(0).map { String(format: "%02x", $0) }.joined()
        case "hexDecode": return try Array(hex(text(0)))
        case "urlEncode":
            let encoded = try encode(text(0), charset: arguments.count > 1 ? text(1) : "UTF-8")
            return encoded.map { byte -> String in
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) { return String(UnicodeScalar(byte)) }
                return String(format: "%%%02X", byte)
            }.joined()
        case "digest":
            let digest = try digest(text(0), input: data(1))
            return (arguments.count > 2 && (arguments[2] as? String) == "bytes") ? Array(digest) as Any : digest.map { String(format: "%02x", $0) }.joined()
        case "crypto":
            guard let config = try argument(0) as? [String: Any] else { throw Failure.invalid("crypto：需要配置对象") }
            return try crypto(config)
        case "transform":
            let direction = try text(1)
            guard direction == "s2t" || direction == "t2s" else { throw Failure.invalid("未知简繁转换方向") }
            return try call(direction, arguments: [text(0)])
        case "s2t", "t2s":
            let transform = StringTransform(method == "s2t" ? "Hans-Hant" : "Hant-Hans")
            guard let result = try text(0).applyingTransform(transform, reverse: false) else { throw Failure.invalid("简繁转换失败") }
            return result
        case "timeFormat", "timeFormatUTC":
            guard let milliseconds = try argument(0) as? NSNumber, milliseconds.doubleValue.isFinite else { throw Failure.invalid("时间戳无效") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = method == "timeFormatUTC" ? TimeZone(secondsFromGMT: 0) : .current
            if arguments.count > 2, let zone = arguments[2] as? String {
                guard let timezone = TimeZone(identifier: zone) else { throw Failure.invalid("时区无效：\(zone)") }
                formatter.timeZone = timezone
            }
            formatter.dateFormat = arguments.count > 1 ? try text(1) : "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000))
        case "randomUUID": return UUID().uuidString.lowercased()
        case "chapterNumber": return chapterNumber(try text(0))
        case "bitmapDecode": return try bitmap(data(0))
        case "fontReplace", "fontMap":
            let source = try data(0), target = try data(1)
            let input = arguments.count > 2 ? try text(2) : String(String.UnicodeScalarView((0xE000...0xF8FF).compactMap(UnicodeScalar.init)))
            let mapping = try fontMapping(source: source, target: target, text: input)
            if method == "fontMap" { return mapping }
            return input.unicodeScalars.map { mapping[String($0)] ?? String($0) }.joined()
        default: throw Failure.invalid("未实现的原生工具：\(method)")
        }
    }

    private static func bytes(_ value: Any) throws -> Data {
        if let data = value as? Data {
            guard data.count <= maximumBytes else { throw Failure.invalid("二进制数据超过 16 MB") }; return data
        }
        guard let values = value as? [Any], values.count <= maximumBytes else { throw Failure.invalid("需要字节数组，且大小不超过 16 MB") }
        var result = Data(); result.reserveCapacity(values.count)
        for value in values {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue, (-128...255).contains(number.intValue) else {
                throw Failure.invalid("字节数组包含非整数或越界值")
            }
            result.append(UInt8(truncatingIfNeeded: number.intValue))
        }
        return result
    }

    private static func encoding(_ charset: String) throws -> String.Encoding {
        switch charset.uppercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "UTF8": return .utf8
        case "UTF16": return .utf16
        case "UTF16LE": return .utf16LittleEndian
        case "UTF16BE": return .utf16BigEndian
        case "UTF32": return .utf32
        case "ASCII", "USASCII": return .ascii
        case "ISO88591", "LATIN1": return .isoLatin1
        case "GBK", "GB2312", "GB18030":
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: encoding)
        default: throw Failure.invalid("不支持的字符编码：\(charset)")
        }
    }

    private static func encode(_ text: String, charset: String) throws -> Data {
        guard text.utf8.count <= maximumBytes, let data = text.data(using: try encoding(charset)), data.count <= maximumBytes else { throw Failure.invalid("文本无法按 \(charset) 编码，或数据过大") }
        return data
    }

    private static func decode(_ data: Data, charset: String) throws -> String {
        guard let value = String(data: data, encoding: try encoding(charset)) else { throw Failure.invalid("字节无法按 \(charset) 解码") }
        return value
    }

    private static func hex(_ text: String) throws -> Data {
        let input = text.filter { !$0.isWhitespace }
        guard input.utf8.count <= maximumBytes * 2, input.count % 2 == 0 else { throw Failure.invalid("十六进制长度无效") }
        var data = Data(); data.reserveCapacity(input.count / 2)
        var index = input.startIndex
        while index != input.endIndex {
            let end = input.index(index, offsetBy: 2)
            guard let byte = UInt8(input[index..<end], radix: 16) else { throw Failure.invalid("十六进制数据无效") }
            data.append(byte); index = end
        }
        return data
    }

    /// Converts the numeral portion of chapter labels while preserving the title.
    /// E.g. 第一百二十三章 一个人 -> 第123章 一个人; a bare numeral is also accepted.
    private static func chapterNumber(_ text: String) -> String {
        let numeralCharacters = "零〇一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟萬億0-9０-９"
        func number(_ input: String) -> String? {
            let digits: [Character: Int64] = ["零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "两": 2, "贰": 2, "三": 3, "叁": 3, "四": 4, "肆": 4, "五": 5, "伍": 5, "六": 6, "陆": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9]
            let units: [Character: Int64] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1_000, "仟": 1_000, "万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000]
            func add(_ a: Int64, _ b: Int64) -> Int64? { let result = a.addingReportingOverflow(b); return result.overflow ? nil : result.partialValue }
            func multiply(_ a: Int64, _ b: Int64) -> Int64? { let result = a.multipliedReportingOverflow(by: b); return result.overflow ? nil : result.partialValue }
            if !input.contains(where: { units[$0] != nil }) {
                let values = input.compactMap { digits[$0] ?? $0.wholeNumberValue.map(Int64.init) }
                guard values.count == input.count else { return nil }
                let normalized = values.map(String.init).joined()
                return Int64(normalized).map(String.init)
            }
            var total: Int64 = 0, section: Int64 = 0, digit: Int64 = 0
            for character in input {
                if let value = digits[character] ?? character.wholeNumberValue.flatMap({ (0...9).contains($0) ? Int64($0) : nil }) {
                    guard let shifted = multiply(digit, 10), let next = add(shifted, value) else { return nil }; digit = next
                } else if let unit = units[character] {
                    if unit < 10_000 {
                        guard let amount = multiply(max(1, digit), unit), let next = add(section, amount) else { return nil }; section = next
                    } else {
                        guard let amount = add(section, digit) else { return nil }
                        if unit == 100_000_000 {
                            guard let sum = add(total, amount), let next = multiply(max(1, sum), unit) else { return nil }; total = next
                        } else {
                            guard let scaled = multiply(max(1, amount), unit), let next = add(total, scaled) else { return nil }; total = next
                        }
                        section = 0
                    }
                    digit = 0
                } else { return nil }
            }
            guard let sum = add(total, section), let value = add(sum, digit) else { return nil }
            return String(value)
        }
        if let pattern = try? NSRegularExpression(pattern: "^[\(numeralCharacters)]+$"), pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return number(text) ?? text }
        guard let expression = try? NSRegularExpression(pattern: "第?([\(numeralCharacters)]+)[章回集节卷部篇]") else { return text }
        let original = text as NSString
        var result = text
        for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let range = match.range(at: 1)
            if let value = number(original.substring(with: range)), let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: value) }
        }
        return result
    }

    private static func digest(_ algorithm: String, input: Data) throws -> Data {
        let algorithm = algorithm.uppercased().replacingOccurrences(of: "-", with: "")
        let length: Int
        switch algorithm {
        case "MD5": length = Int(CC_MD5_DIGEST_LENGTH)
        case "SHA1": length = Int(CC_SHA1_DIGEST_LENGTH)
        case "SHA224": length = Int(CC_SHA224_DIGEST_LENGTH)
        case "SHA256": length = Int(CC_SHA256_DIGEST_LENGTH)
        case "SHA384": length = Int(CC_SHA384_DIGEST_LENGTH)
        case "SHA512": length = Int(CC_SHA512_DIGEST_LENGTH)
        default: throw Failure.invalid("不支持的摘要算法：\(algorithm)")
        }
        var output = [UInt8](repeating: 0, count: length)
        input.withUnsafeBytes { pointer in
            switch algorithm {
            case "MD5": _ = CC_MD5(pointer.baseAddress, CC_LONG(input.count), &output)
            case "SHA1": _ = CC_SHA1(pointer.baseAddress, CC_LONG(input.count), &output)
            case "SHA224": _ = CC_SHA224(pointer.baseAddress, CC_LONG(input.count), &output)
            case "SHA256": _ = CC_SHA256(pointer.baseAddress, CC_LONG(input.count), &output)
            case "SHA384": _ = CC_SHA384(pointer.baseAddress, CC_LONG(input.count), &output)
            default: _ = CC_SHA512(pointer.baseAddress, CC_LONG(input.count), &output)
            }
        }
        return Data(output)
    }

    private static func crypto(_ config: [String: Any]) throws -> Any {
        let transformation = (config["algorithm"] as? String ?? "AES/CBC/PKCS5Padding").uppercased()
        let action = (config["action"] as? String ?? "decrypt").lowercased()
        var input = try bytes(config["input"] ?? [])
        if transformation.hasPrefix("RSA") { return try rsa(config, input: input, action: action, transformation: transformation) }
        var key = try bytes(config["key"] ?? [])
        if transformation.hasPrefix("HMAC") {
            let algorithm: CCHmacAlgorithm
            let length: Int
            switch transformation.replacingOccurrences(of: "-", with: "") {
            case "HMACMD5": algorithm = CCHmacAlgorithm(kCCHmacAlgMD5); length = 16
            case "HMACSHA1": algorithm = CCHmacAlgorithm(kCCHmacAlgSHA1); length = 20
            case "HMACSHA224": algorithm = CCHmacAlgorithm(kCCHmacAlgSHA224); length = 28
            case "HMACSHA256": algorithm = CCHmacAlgorithm(kCCHmacAlgSHA256); length = 32
            case "HMACSHA384": algorithm = CCHmacAlgorithm(kCCHmacAlgSHA384); length = 48
            case "HMACSHA512": algorithm = CCHmacAlgorithm(kCCHmacAlgSHA512); length = 64
            default: throw Failure.invalid("不支持的 HMAC 算法")
            }
            var output = [UInt8](repeating: 0, count: length)
            key.withUnsafeBytes { keyBytes in input.withUnsafeBytes { inputBytes in CCHmac(algorithm, keyBytes.baseAddress, key.count, inputBytes.baseAddress, input.count, &output) } }
            if action == "verify" {
                let signature = try bytes(config["signature"] ?? [])
                guard signature.count == output.count else { return false }
                return zip(signature, output).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            }
            guard ["sign", "encrypt"].contains(action) else { throw Failure.invalid("HMAC 仅支持 sign/verify") }
            return output
        }
        guard action == "encrypt" || action == "decrypt" else { throw Failure.invalid("对称算法仅支持 encrypt/decrypt") }
        let parts = transformation.split(separator: "/").map(String.init)
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = (config["padding"] as? String)?.uppercased() ?? (parts.count > 2 ? parts[2] : "PKCS5PADDING")
        guard mode == "CBC" || mode == "ECB" else { throw Failure.invalid("不支持的加密模式：\(mode)") }
        guard ["PKCS5PADDING", "PKCS7PADDING", "ZEROPADDING", "NOPADDING"].contains(padding) else { throw Failure.invalid("不支持的填充方式：\(padding)") }
        let algorithm: CCAlgorithm
        let blockSize: Int
        switch parts[0] {
        case "AES":
            algorithm = CCAlgorithm(kCCAlgorithmAES); blockSize = kCCBlockSizeAES128
            guard [16, 24, 32].contains(key.count) else { throw Failure.invalid("AES 密钥必须是 16、24 或 32 字节") }
        case "DES":
            algorithm = CCAlgorithm(kCCAlgorithmDES); blockSize = kCCBlockSizeDES
            guard key.count == 8 else { throw Failure.invalid("DES 密钥必须是 8 字节") }
        case "DESEDE", "3DES", "TRIPLEDES":
            algorithm = CCAlgorithm(kCCAlgorithm3DES); blockSize = kCCBlockSize3DES
            if key.count == 16 { key.append(key.prefix(8)) }
            guard key.count == 24 else { throw Failure.invalid("3DES 密钥必须是 16 或 24 字节") }
        default: throw Failure.invalid("不支持的加密算法：\(parts[0])")
        }
        var iv = try bytes(config["iv"] ?? [UInt8](repeating: 0, count: blockSize))
        if mode == "ECB" { iv = Data(repeating: 0, count: blockSize) }
        guard iv.count == blockSize else { throw Failure.invalid("IV 长度必须为 \(blockSize) 字节") }
        if padding == "ZEROPADDING", action == "encrypt", input.count % blockSize != 0 { input.append(Data(repeating: 0, count: blockSize - input.count % blockSize)) }
        let usesPKCS = padding == "PKCS5PADDING" || padding == "PKCS7PADDING"
        guard (usesPKCS && action == "encrypt") || input.count % blockSize == 0 else { throw Failure.invalid("输入不是完整的加密块") }
        var output = [UInt8](repeating: 0, count: input.count + blockSize)
        let capacity = output.count
        var written = 0
        let options = CCOptions((usesPKCS ? kCCOptionPKCS7Padding : 0) | (mode == "ECB" ? kCCOptionECBMode : 0))
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in input.withUnsafeBytes { inputBytes in
            CCCrypt(CCOperation(action == "encrypt" ? kCCEncrypt : kCCDecrypt), algorithm, options, keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, input.count, &output, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw Failure.invalid("加解密失败（\(status)），请检查密钥、IV 与填充方式") }
        output = Array(output.prefix(written))
        if padding == "ZEROPADDING", action == "decrypt" { while output.last == 0 { output.removeLast() } }
        return output
    }

    private static func rsa(_ config: [String: Any], input: Data, action: String, transformation: String) throws -> Any {
        let isPrivate = config["privateKey"] != nil || (config["keyType"] as? String) == "private"
        let value = config["privateKey"] ?? config["publicKey"] ?? config["key"] ?? []
        var der: Data
        if let text = value as? String {
            let encoded = text.components(separatedBy: .newlines).filter { !$0.contains("-----") }.joined().filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: encoded) else { throw Failure.invalid("RSA 密钥不是有效的 PEM/Base64") }
            der = decoded
        } else { der = try bytes(value) }
        guard der.count <= 65_536 else { throw Failure.invalid("RSA 密钥过大") }
        der = try ASN1.unwrapKey(der, privateKey: isPrivate)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else { throw Failure.invalid("RSA 密钥无效：\(error?.takeRetainedValue().localizedDescription ?? "无法解析")") }
        let blockSize = SecKeyGetBlockSize(key)
        guard blockSize >= 64, blockSize <= 1_024, input.count <= 1_024 * blockSize else { throw Failure.invalid("RSA 密钥或输入超出限制") }
        if action == "sign" || action == "verify" {
            let digest = (config["digest"] as? String ?? "SHA256").uppercased().replacingOccurrences(of: "-", with: "")
            let algorithm: SecKeyAlgorithm
            switch digest {
            case "SHA1": algorithm = .rsaSignatureMessagePKCS1v15SHA1
            case "SHA224": algorithm = .rsaSignatureMessagePKCS1v15SHA224
            case "SHA256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
            case "SHA384": algorithm = .rsaSignatureMessagePKCS1v15SHA384
            case "SHA512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
            default: throw Failure.invalid("不支持的 RSA 签名摘要")
            }
            if action == "verify" {
                let publicKey = isPrivate ? SecKeyCopyPublicKey(key) : key
                guard let publicKey else { throw Failure.invalid("无法取得 RSA 公钥") }
                let verified = try SecKeyVerifySignature(publicKey, algorithm, input as CFData, bytes(config["signature"] ?? []) as CFData, &error)
                if let error { _ = error.takeRetainedValue() }
                return verified
            }
            guard isPrivate, let signed = SecKeyCreateSignature(key, algorithm, input as CFData, &error) else { throw Failure.invalid("RSA 签名失败：\(error?.takeRetainedValue().localizedDescription ?? "需要私钥")") }
            return Array(signed as Data)
        }
        guard action == "encrypt" || action == "decrypt" else { throw Failure.invalid("不支持的 RSA 操作") }
        let padding = (config["padding"] as? String)?.uppercased() ?? transformation.split(separator: "/").last.map(String.init) ?? "PKCS1PADDING"
        if action == "decrypt", !isPrivate {
            guard padding == "RSA" || padding == "PKCS1PADDING" || padding == "NOPADDING" else { throw Failure.invalid("RSA 公钥恢复仅支持 PKCS1Padding/NoPadding") }
            return try RSAPublicOperation.recover(input: input, keyDER: der, unpad: padding != "NOPADDING")
        }
        guard !(action == "encrypt" && isPrivate) else { throw Failure.invalid("私钥请使用 sign；encrypt 需要公钥") }
        let algorithm: SecKeyAlgorithm
        let overhead: Int
        switch padding {
        case "RSA", "PKCS1PADDING": algorithm = .rsaEncryptionPKCS1; overhead = 11
        case "NOPADDING": algorithm = .rsaEncryptionRaw; overhead = 0
        case "OAEPPADDING", "OAEPWITHSHA-1ANDMGF1PADDING": algorithm = .rsaEncryptionOAEPSHA1; overhead = 42
        case "OAEPWITHSHA-256ANDMGF1PADDING": algorithm = .rsaEncryptionOAEPSHA256; overhead = 66
        default: throw Failure.invalid("不支持的 RSA 填充：\(padding)")
        }
        let inputBlock = action == "encrypt" ? blockSize - overhead : blockSize
        guard inputBlock > 0, action == "encrypt" || input.count % blockSize == 0 else { throw Failure.invalid("RSA 密文块长度无效") }
        var output = Data()
        for offset in stride(from: 0, to: input.count, by: inputBlock) {
            let block = input.subdata(in: offset..<min(input.count, offset + inputBlock))
            let transformed = action == "encrypt" ? SecKeyCreateEncryptedData(key, algorithm, block as CFData, &error) : SecKeyCreateDecryptedData(key, algorithm, block as CFData, &error)
            guard let transformed else { throw Failure.invalid("RSA 加解密失败：\(error?.takeRetainedValue().localizedDescription ?? "数据无效")") }
            output.append(transformed as Data)
        }
        return Array(output)
    }

    private static func bitmap(_ data: Data) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 1_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.invalid("图片无效，或超过 100 万像素限制") }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = rgba.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard didDraw else { throw Failure.invalid("无法解码图片像素") }
        var pixels = [Int32](); pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = UInt32(rgba[index + 3])
            func channel(_ offset: Int) -> UInt32 { alpha == 0 ? 0 : min(255, UInt32(rgba[index + offset]) * 255 / alpha) }
            pixels.append(Int32(bitPattern: alpha << 24 | channel(0) << 16 | channel(1) << 8 | channel(2)))
        }
        return ["width": width, "height": height, "pixels": pixels]
    }

    private static func fontMapping(source: Data, target: Data, text: String) throws -> [String: String] {
        guard text.utf16.count <= 200_000 else { throw Failure.invalid("字体替换文本过长") }
        func font(_ data: Data) throws -> CTFont {
            guard let provider = CGDataProvider(data: data as CFData), let graphics = CGFont(provider) else { throw Failure.invalid("TTF/OTF 字体数据无效") }
            let font = CTFontCreateWithGraphicsFont(graphics, 1_000, nil, nil)
            guard CTFontGetGlyphCount(font) <= 65_536 else { throw Failure.invalid("字体字形数量超出限制") }
            return font
        }
        let sourceFont = try font(source), targetFont = try font(target)
        let characters = (0...65_535).map { UniChar($0) }
        var targetGlyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(targetFont, characters, &targetGlyphs, characters.count)
        var signatureCache: [CGGlyph: String] = [:]
        var targetCharacters: [String: UnicodeScalar] = [:]
        for (number, glyph) in targetGlyphs.enumerated() where glyph != 0 && !(0xD800...0xDFFF).contains(number) {
            guard let scalar = UnicodeScalar(number) else { continue }
            let signature: String
            if let cached = signatureCache[glyph] { signature = cached }
            else { signature = glyphSignature(font: targetFont, glyph: glyph) ?? ""; signatureCache[glyph] = signature }
            guard !signature.isEmpty else { continue }
            if targetCharacters[signature] == nil || (0x4E00...0x9FFF).contains(number) { targetCharacters[signature] = scalar }
        }
        var mapping: [String: String] = [:]
        var visited = Set<UnicodeScalar>()
        for scalar in text.unicodeScalars where scalar.value <= 0xFFFF && visited.insert(scalar).inserted {
            var character = UniChar(scalar.value), glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(sourceFont, &character, &glyph, 1), glyph != 0,
                  let signature = glyphSignature(font: sourceFont, glyph: glyph), let replacement = targetCharacters[signature] else { continue }
            mapping[String(scalar)] = String(replacement)
        }
        return mapping
    }

    private static func glyphSignature(font: CTFont, glyph: CGGlyph) -> String? {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        let box = path.boundingBoxOfPath
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return nil }
        var signature = [Int32]()
        path.applyWithBlock { element in
            guard signature.count < 40_000 else { return }
            let value = element.pointee
            signature.append(Int32(value.type.rawValue))
            let count: Int
            switch value.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for index in 0..<count {
                let point = value.points[index]
                let x = ((point.x - box.minX) / box.width * 10_000).rounded()
                let y = ((point.y - box.minY) / box.height * 10_000).rounded()
                if x.isFinite && y.isFinite && abs(x) < 1_000_000 && abs(y) < 1_000_000 { signature += [Int32(x), Int32(y)] }
            }
        }
        guard !signature.isEmpty, signature.count < 40_000 else { return nil }
        return signature.withUnsafeBytes { pointer in
            (try? digest("SHA256", input: Data(pointer)))?.base64EncodedString()
        }
    }

    private enum ASN1 {
        struct Node { let tag: UInt8; let content: Data }
        static func nodes(_ data: Data) throws -> [Node] {
            let data = [UInt8](data)
            var result: [Node] = [], offset = 0
            while offset < data.count {
                guard data.count - offset >= 2 else { throw Failure.invalid("RSA DER 数据不完整") }
                let tag = data[offset]; offset += 1
                var length = Int(data[offset]); offset += 1
                if length & 0x80 != 0 {
                    let count = length & 0x7F
                    guard (1...4).contains(count), count <= data.count - offset else { throw Failure.invalid("RSA DER 长度无效") }
                    length = 0
                    for _ in 0..<count { length = length * 256 + Int(data[offset]); offset += 1 }
                }
                guard length <= data.count - offset else { throw Failure.invalid("RSA DER 字段越界") }
                result.append(Node(tag: tag, content: Data(data[offset..<(offset + length)]))); offset += length
            }
            return result
        }
        static func sequence(_ data: Data) throws -> [Node] {
            let root = try nodes(data)
            guard root.count == 1, root[0].tag == 0x30 else { throw Failure.invalid("RSA 密钥不是 DER 序列") }
            return try nodes(root[0].content)
        }
        static func unwrapKey(_ data: Data, privateKey: Bool) throws -> Data {
            let fields = try sequence(data)
            if privateKey, fields.count >= 3, fields[1].tag == 0x30, fields[2].tag == 0x04 { return fields[2].content }
            if !privateKey, fields.count == 2, fields[0].tag == 0x30, fields[1].tag == 0x03, fields[1].content.first == 0 { return Data(fields[1].content.dropFirst()) }
            return data
        }
    }

    /// Public RSA recovery for Legado's setPublicKey(...).decryptStr(...). Only
    /// public operands are processed here; secret-key operations use Security.
    private enum RSAPublicOperation {
        static func recover(input: Data, keyDER: Data, unpad: Bool) throws -> [UInt8] {
            let fields = try ASN1.sequence(keyDER)
            guard fields.count == 2, fields.allSatisfy({ $0.tag == 0x02 }) else { throw Failure.invalid("RSA 公钥格式无效") }
            let modulusBytes = Array(fields[0].content.drop(while: { $0 == 0 }))
            let exponent = Array(fields[1].content.drop(while: { $0 == 0 }))
            guard (64...1_024).contains(modulusBytes.count), !exponent.isEmpty, exponent.count <= 8,
                  input.count % modulusBytes.count == 0 else { throw Failure.invalid("RSA 公钥或密文长度无效") }
            let count = (modulusBytes.count + 3) / 4
            let modulus = words(modulusBytes, count: count)
            guard modulus[0] & 1 == 1 else { throw Failure.invalid("RSA 模数必须为奇数") }
            var inverse = modulus[0]
            for _ in 0..<5 { inverse = inverse &* (2 &- modulus[0] &* inverse) }
            let factor = 0 &- inverse
            var one = [UInt32](repeating: 0, count: count); one[0] = 1
            var squaredR = one
            for _ in 0..<(64 * count) { squaredR = doubled(squaredR, modulus: modulus) }
            let identity = multiply(one, squaredR, modulus: modulus, factor: factor)
            var result = [UInt8]()
            let bytes = Array(input)
            for offset in stride(from: 0, to: bytes.count, by: modulusBytes.count) {
                let block = words(Array(bytes[offset..<(offset + modulusBytes.count)]), count: count)
                guard !atLeast(block, modulus) else { throw Failure.invalid("RSA 密文块超出模数") }
                let base = multiply(block, squaredR, modulus: modulus, factor: factor)
                var value = identity
                for byte in exponent {
                    for bit in stride(from: 7, through: 0, by: -1) {
                        value = multiply(value, value, modulus: modulus, factor: factor)
                        if byte & (1 << bit) != 0 { value = multiply(value, base, modulus: modulus, factor: factor) }
                    }
                }
                value = multiply(value, one, modulus: modulus, factor: factor)
                var plain = [UInt8]()
                for word in value.reversed() { plain += [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)] }
                plain = Array(plain.suffix(modulusBytes.count))
                if unpad {
                    guard plain.count >= 11, plain[0] == 0, plain[1] == 1 || plain[1] == 2,
                          let separator = plain[2...].firstIndex(of: 0), separator >= 10,
                          plain[1] != 1 || plain[2..<separator].allSatisfy({ $0 == 0xFF }) else { throw Failure.invalid("RSA PKCS1 填充无效") }
                    plain = Array(plain[(separator + 1)...])
                }
                result += plain
            }
            return result
        }
        static func words(_ data: [UInt8], count: Int) -> [UInt32] {
            var result = [UInt32](repeating: 0, count: count)
            for (index, byte) in data.reversed().enumerated() { result[index / 4] |= UInt32(byte) << UInt32((index % 4) * 8) }
            return result
        }
        static func atLeast(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
            for index in lhs.indices.reversed() where lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
            return true
        }
        static func subtract(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
            var result = lhs, borrow: UInt64 = 0
            for index in lhs.indices {
                let difference = UInt64(lhs[index]) &- UInt64(rhs[index]) &- borrow
                result[index] = UInt32(truncatingIfNeeded: difference); borrow = difference >> 63
            }
            return result
        }
        static func doubled(_ input: [UInt32], modulus: [UInt32]) -> [UInt32] {
            var value = input, carry: UInt32 = 0
            for index in value.indices { let next = value[index] >> 31; value[index] = value[index] << 1 | carry; carry = next }
            return carry != 0 || atLeast(value, modulus) ? subtract(value, modulus) : value
        }
        static func multiply(_ a: [UInt32], _ b: [UInt32], modulus: [UInt32], factor: UInt32) -> [UInt32] {
            let count = modulus.count
            var t = [UInt32](repeating: 0, count: count + 2)
            for index in 0..<count {
                var carry: UInt64 = 0
                for j in 0..<count {
                    let value = UInt64(a[j]) * UInt64(b[index]) + UInt64(t[j]) + carry
                    t[j] = UInt32(truncatingIfNeeded: value); carry = value >> 32
                }
                var value = UInt64(t[count]) + carry
                t[count] = UInt32(truncatingIfNeeded: value); t[count + 1] = UInt32(value >> 32)
                let m = t[0] &* factor
                carry = 0
                for j in 0..<count {
                    value = UInt64(m) * UInt64(modulus[j]) + UInt64(t[j]) + carry
                    if j > 0 { t[j - 1] = UInt32(truncatingIfNeeded: value) }
                    carry = value >> 32
                }
                value = UInt64(t[count]) + carry
                t[count - 1] = UInt32(truncatingIfNeeded: value)
                t[count] = t[count + 1] + UInt32(value >> 32); t[count + 1] = 0
            }
            let value = Array(t.prefix(count))
            return t[count] != 0 || atLeast(value, modulus) ? subtract(value, modulus) : value
        }
    }
}
