import XCTest
@testable import Yuedu

@MainActor
final class YueduBackgroundNetworkTests: XCTestCase {
    func testRedirectCookieFailureFallsBackToSourceAwareForegroundTransport() async throws {
        let url = URL(string: "http://127.0.0.1:8080/background-cookie-redirect")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.background(withIdentifier: "Yuedu-cookie-test-" + UUID().uuidString)
        configuration.isDiscretionary = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let service = YueduBackgroundTransfer(directory: directory, configuration: configuration)
        let bookID = UUID()
        defer {
            service.remove(bookID: bookID)
            service.invalidate()
            try? FileManager.default.removeItem(at: directory)
        }
        await service.connect()
        var request = URLRequest(url: url)
        request.setValue("Yuedu-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let sourceID = UUID()
        try service.enqueue([YueduBackgroundTransfer.Plan(
            bookID: bookID, chapterID: UUID(), sourceID: sourceID, request: request
        )])
        for _ in 0..<200 {
            let state = service.summary(bookID: bookID)
            if state.ready + state.failed > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard service.summary(bookID: bookID).ready > 0 else {
            XCTFail("The native redirect fixture did not complete.")
            return
        }
        let prefetched = try await service.response(for: request, sourceID: sourceID)
        XCTAssertEqual(prefetched?.1.statusCode, 401)
        let http = LegadoHTTPClient(session: URLSession(configuration: .ephemeral),
                                    cookieDirectory: directory, backgroundTransfers: service)
        let response = try await http.request(["url": url.absoluteString], sourceID: sourceID)
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertEqual(response["body"] as? String, "redirect cookie accepted")
    }

    func testSystemSessionSavesAndReusesHTTPResponse() async throws {
        let url = URL(string: "http://127.0.0.1:8080/chapters/1")!
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2))
        } catch {
            throw XCTSkip("Start scripts/demo_source_server.py for the native background transport integration test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.background(withIdentifier: "Yuedu-test-" + UUID().uuidString)
        configuration.isDiscretionary = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let service = YueduBackgroundTransfer(directory: directory, configuration: configuration)
        let bookID = UUID()
        defer {
            service.remove(bookID: bookID)
            service.invalidate()
            try? FileManager.default.removeItem(at: directory)
        }
        await service.connect()
        let request = URLRequest(url: url)
        let sourceID = UUID()
        try service.enqueue([YueduBackgroundTransfer.Plan(
            bookID: bookID, chapterID: UUID(), sourceID: sourceID, request: request
        )])
        for _ in 0..<200 {
            let state = service.summary(bookID: bookID)
            if state.ready + state.failed > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = service.summary(bookID: bookID)
        guard state.ready + state.failed > 0 else {
            XCTFail("The OS did not complete the queued download in 20 seconds.")
            return
        }
        let response = try await service.response(for: request, sourceID: sourceID)
        XCTAssertEqual(response?.1.statusCode, 200)
        XCTAssertTrue(String(decoding: response!.0, as: UTF8.self).contains("窗边"))
        let restored = YueduBackgroundTransfer(directory: directory, configuration: .ephemeral)
        let diskResponse = try await restored.response(for: request, sourceID: sourceID)
        XCTAssertEqual(diskResponse?.0, response?.0)
    }
}
