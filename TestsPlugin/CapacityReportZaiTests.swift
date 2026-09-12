import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CapacityReportZaiTests {
    private actor Requests {
        var paths: [String] = []
        func append(_ path: String) {
            self.paths.append(path)
        }
    }

    @Test
    func `report plugin fetches quota without historical requests`() async throws {
        let requests = Requests()
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "zai",
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                await requests.append(url.path)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                let body = """
                {"success":true,"code":200,"data":{"limits":[
                  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25},
                  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":70}
                ]}}
                """
                return (Data(body.utf8), response)
            })
        let snapshot = try await runtime.fetchUsage(
            settings: ["CODEXBAR_REPORT_ONLY": "1"],
            secrets: ["Z_AI_API_KEY": "fixture-key"])
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.secondary?.usedPercent == 70)
        #expect(await requests.paths == ["/api/monitor/usage/quota/limit"])
    }

    @Test
    func `report plugin rejects an empty quota list`() async throws {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "zai",
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]))
                return (Data(#"{"success":true,"code":200,"data":{"limits":[]}}"#.utf8), response)
            })
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(
                settings: ["CODEXBAR_REPORT_ONLY": "1"],
                secrets: ["Z_AI_API_KEY": "fixture-key"])
        }
    }
}
