import XCTest
import Security
import CoreGraphics
import ImageIO
@testable import Yuedu

final class LegadoNativeUtilitiesTests: XCTestCase {
    func testAESMatchesPublishedNISTCBCVector() throws {
        let key = try hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = try hex("000102030405060708090a0b0c0d0e0f")
        let plain = try hex("6bc1bee22e409f96e93d7e117393172a")
        let expected = try hex("7649abac8119b246cee98e9b12e9197d")
        let encrypted = try crypto(["algorithm": "AES/CBC/NoPadding", "action": "encrypt", "key": key, "iv": iv, "input": plain])
        XCTAssertEqual(encrypted, expected)
        XCTAssertEqual(try crypto(["algorithm": "AES/CBC/NoPadding", "action": "decrypt", "key": key, "iv": iv, "input": expected]), plain)
    }

    func testDESMatchesKnownVectorAndTripleDESSupportsTwoKeyInput() throws {
        let key = try hex("133457799bbcdff1")
        let plain = try hex("0123456789abcdef")
        XCTAssertEqual(try crypto(["algorithm": "DES/ECB/NoPadding", "action": "encrypt", "key": key, "input": plain]), try hex("85e813540f0ab405"))
        let tripleKey = try hex("0123456789abcdeffedcba9876543210")
        let encrypted = try crypto(["algorithm": "DESede/CBC/PKCS5Padding", "action": "encrypt", "key": tripleKey, "iv": [UInt8](repeating: 0, count: 8), "input": plain])
        XCTAssertEqual(try crypto(["algorithm": "DESede/CBC/PKCS5Padding", "action": "decrypt", "key": tripleKey, "iv": [UInt8](repeating: 0, count: 8), "input": encrypted]), plain)
    }

    func testAESPKCSAndZeroPaddingAreDistinctAndInvalidCiphertextFails() throws {
        let key = [UInt8](repeating: 7, count: 16), iv = [UInt8](repeating: 3, count: 16)
        let text = Array("中文正文".utf8)
        for padding in ["PKCS5Padding", "PKCS7Padding", "ZeroPadding"] {
            let encrypted = try crypto(["algorithm": "AES/CBC/\(padding)", "action": "encrypt", "key": key, "iv": iv, "input": text])
            XCTAssertEqual(try crypto(["algorithm": "AES/CBC/\(padding)", "action": "decrypt", "key": key, "iv": iv, "input": encrypted]), text)
        }
        XCTAssertThrowsError(try crypto(["algorithm": "AES/CBC/PKCS5Padding", "action": "decrypt", "key": key, "iv": iv, "input": [1, 2, 3]]))
        XCTAssertThrowsError(try crypto(["algorithm": "AES/CBC/PKCS5Padding", "action": "encrypt", "key": [1, 2, 3], "iv": iv, "input": text]))
    }

    func testHMACMatchesRFC4231AndVerifiesWithoutAcceptingDifferentSignature() throws {
        let config: [String: Any] = ["algorithm": "HmacSHA256", "action": "sign", "key": [UInt8](repeating: 0x0B, count: 20), "input": Array("Hi There".utf8)]
        let expected = try hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(try crypto(config), expected)
        var verify = config
        verify["action"] = "verify"; verify["signature"] = expected
        XCTAssertEqual(try LegadoNativeUtilities.call("crypto", arguments: [verify]) as? Bool, true)
        verify["signature"] = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(try LegadoNativeUtilities.call("crypto", arguments: [verify]) as? Bool, false)
    }

    func testDigestEncodingAndJavaSignedByteArrays() throws {
        XCTAssertEqual(try LegadoNativeUtilities.call("digest", arguments: ["MD5", Array("abc".utf8)]) as? String, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try LegadoNativeUtilities.call("digest", arguments: ["SHA-256", Array("abc".utf8)]) as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try LegadoNativeUtilities.call("base64Encode", arguments: [[-1, -2, 0]]) as? String, "//4A")
        XCTAssertEqual(try LegadoNativeUtilities.call("base64Decode", arguments: ["__4A"]) as? [UInt8], [255, 254, 0])
        let gbk = try XCTUnwrap(LegadoNativeUtilities.call("encode", arguments: ["中文", "GBK"]) as? [UInt8])
        XCTAssertEqual(gbk, [0xD6, 0xD0, 0xCE, 0xC4])
        XCTAssertEqual(try LegadoNativeUtilities.call("decode", arguments: [gbk, "GBK"]) as? String, "中文")
        XCTAssertEqual(try LegadoNativeUtilities.call("urlEncode", arguments: ["中文 &", "GBK"]) as? String, "%D6%D0%CE%C4%20%26")
        XCTAssertThrowsError(try LegadoNativeUtilities.call("decode", arguments: [[256], "UTF-8"]))
        XCTAssertThrowsError(try LegadoNativeUtilities.call("decode", arguments: [[true], "UTF-8"]))
        XCTAssertThrowsError(try LegadoNativeUtilities.call("hexDecode", arguments: ["01zz"]))
    }

    func testRSAEncryptionAndPublicRecoveryMatchIndependentOpenSSLFixture() throws {
        // Public, randomly generated test-only key; never used for any account or production data.
        let privateDER = Array(try XCTUnwrap(Data(base64Encoded: "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBALaaOFFLjljYWnrl0c2EtqH06rgddW0zKepxXDuq+6IyJQGRIcR9IKq1Xx+8SM8xhT/4vz30rHTckX/E8pTtQieYgqNgejhZfaMiy0PC5JGaZNTuql1nn1RqHxfoyj0h/GUZqUm4bCVo7fC96rQLcE9zftd+Woac76xLRvHPxuVNAgMBAAECgYBdedMsop4LEy42TaG6MJ8Bh4wElmf/b7qcXk2V6fCI1lylUbNUj62CVfiNGWi4UCRjXCYiRDdoV2VQX/TCkjZTirxDHY5L78JPay6VcOOm6/vdqWenIdmXQqQ07NHB0Yt02U/bcCYmPTqjhcTk1BUP5dhnC6CupbKP0xOMZmZwIQJBAOkj30ssICbagSu2unD9aTUaUwlKgxcxfoj1NNGBZLv1kPAV759M9P4cgMoybLXVc+8eT9C1TCmC56Rh3tbWOykCQQDIgci3Zj3gnxBvEHEO/T/6Ir80vu8Ynug+pJVRwq+zvCMcVMCN9xZTQ2cVBjx555dca7mXC6rcx4Xcu9OxJwGFAkEArfEVqABD/LkJppOuhp6K4BPD4Cq3o5ZJ0eUggy8G+TU97eJv5WqFXxHlBPaaJRAcb0suQYkCSfZg3UQn/iHYAQJAEvJ4tiP6OuytD+G83U6/KfL4oJJeY7Q4fBrvZU+BbPmdU8MKgx/TQ0D+T7VMJ7Tjz776RbS7i6trEeXJ5laqRQJAJ9Uvs/DwxPnpchXq1EIdx8LBLwdEbPlCWJH5euMkAVkWmymzOh+/uBmEVnHjxsofq937S6qtmcmGDT6XnPKV2w==")))
        let publicDER = Array(try XCTUnwrap(Data(base64Encoded: "MIGJAoGBALaaOFFLjljYWnrl0c2EtqH06rgddW0zKepxXDuq+6IyJQGRIcR9IKq1Xx+8SM8xhT/4vz30rHTckX/E8pTtQieYgqNgejhZfaMiy0PC5JGaZNTuql1nn1RqHxfoyj0h/GUZqUm4bCVo7fC96rQLcE9zftd+Woac76xLRvHPxuVNAgMBAAE=")))
        let text = Array(String(repeating: "章节正文", count: 30).utf8)
        let cipher = try crypto(["algorithm": "RSA", "action": "encrypt", "publicKey": publicDER, "input": text])
        XCTAssertEqual(try crypto(["algorithm": "RSA", "action": "decrypt", "privateKey": privateDER, "input": cipher]), text)

        // Legacy Legado sources recover content encrypted with the private key.
        // The public-only modular operation must recover an independent OpenSSL-produced PKCS#1 block.
        let message = Array("public-key chapter recovery".utf8)
        let signature = Array(try XCTUnwrap(Data(base64Encoded: "KlgWDvoC4YNOyCGyKRBZTzMV7FWEyxVNopZNCRZlTzpscdtbNkZ2qPDLOB32vvXeJtD/ZX9Z9inUicRxsZJMXSbBkaFkXKi/v/3Kvz7oOTNsTwPzDgFjECmzt7w2W+f0CeT+cz9LVZAbHAYD8zTEY/n+/ofcvg0NBg2wF5ypTtc=")))
        XCTAssertEqual(try crypto(["algorithm": "RSA", "action": "decrypt", "publicKey": publicDER, "input": signature]), message)
    }

    func testSimplifiedTraditionalAndUTCTimeFormatting() throws {
        XCTAssertEqual(try LegadoNativeUtilities.call("transform", arguments: ["汉语阅读", "s2t"]) as? String, "漢語閱讀")
        XCTAssertEqual(try LegadoNativeUtilities.call("transform", arguments: ["漢語閱讀", "t2s"]) as? String, "汉语阅读")
        XCTAssertEqual(try LegadoNativeUtilities.call("timeFormatUTC", arguments: [0, "yyyy-MM-dd HH:mm:ss"]) as? String, "1970-01-01 00:00:00")
        XCTAssertEqual(try LegadoNativeUtilities.call("timeFormat", arguments: [0, "yyyy-MM-dd HH:mm", "Asia/Shanghai"]) as? String, "1970-01-01 08:00")
    }

    func testChapterNumberConvertsTheLabelWithoutChangingTitleWords() throws {
        for (input, expected) in [("第一百二十三章 一个人", "第123章 一个人"), ("第两千零六回", "第2006回"), ("卷一 第一章", "卷一 第1章"), ("第三万二千零一章", "第32001章"), ("第１２章", "第12章"), ("一〇二四", "1024"), ("一亿零三万二千", "100032000"), ("一见钟情", "一见钟情")] {
            XCTAssertEqual(try LegadoNativeUtilities.call("chapterNumber", arguments: [input]) as? String, expected)
        }
    }

    func testBitmapDecodeReturnsAndroidARGBPixelsAndRejectsInvalidAssets() throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try XCTUnwrap(LegadoNativeUtilities.call("bitmapDecode", arguments: [Array(data as Data)]) as? [String: Any])
        XCTAssertEqual(decoded["width"] as? Int, 2)
        XCTAssertEqual(decoded["height"] as? Int, 1)
        XCTAssertEqual(decoded["pixels"] as? [Int32], [-65_536, -16_711_936])
        XCTAssertThrowsError(try LegadoNativeUtilities.call("bitmapDecode", arguments: [[1, 2, 3]]))
        XCTAssertThrowsError(try LegadoNativeUtilities.call("fontReplace", arguments: [[1], [2], "正文"]))
    }

    private func hex(_ value: String) throws -> [UInt8] {
        try XCTUnwrap(LegadoNativeUtilities.call("hexDecode", arguments: [value]) as? [UInt8])
    }
    private func crypto(_ value: [String: Any]) throws -> [UInt8] {
        let result = try LegadoNativeUtilities.call("crypto", arguments: [value])
        return try XCTUnwrap(result as? [UInt8])
    }
}
