import Foundation

/// Exercises the production process/file path using a fake sqlpackage; never connects to a database.
@main
struct DacpacExportTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "DacpacExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOMTA_EXPORT_TEST_DIR"]!)
        let record = root.appendingPathComponent("invocation.json")
        let destination = root.appendingPathComponent("Export with spaces.dacpac")
        let input = ConnectionInput(connectionString: "Server=fixture.invalid;Database=TestSchema;User ID=test;", password: "fixture-only-secret")
        func mode(_ value: String) throws { try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
        func invocation() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
        }
        func expectFailure(_ service: SqlPackageService = SqlPackageService(), input value: ConnectionInput? = nil) throws {
            do {
                try service.exportDacpac(input: value ?? input, to: destination)
            } catch { return }
            throw NSError(domain: "DacpacExportTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected export to fail"])
        }
        try mode("success")
        try SqlPackageService().exportDacpac(input: input, to: destination)
        try require(try Data(contentsOf: destination) == Data("schema fixture".utf8), "Export not saved")
        let call = try invocation()
        let arguments = call["arguments"] as! [String]
        try require(arguments.contains("/Action:Extract"), "Must extract, never export a bacpac")
        try require(arguments.contains("/p:ExtractAllTableData=False"), "Table data must be excluded")
        try require(!arguments.contains(where: { $0.lowercased().hasPrefix("/p:tabledata=") }), "Individual table data must be excluded")
        try require(arguments.contains("/p:IgnoreExtendedProperties=False"), "Export must retain schema metadata")
        try require(arguments.contains(where: { $0.contains("fixture-only-secret") }), "Separate password wasn't used")
        try require(call["permissions"] as? Int == 0o600, "Response file must be private")
        try require((call["argv"] as! [String]).count == 1, "Use response file, not credentials in process arguments")
        try require(!files.fileExists(atPath: call["response"] as! String), "Response file wasn't removed")
        try require(!files.fileExists(atPath: call["staging"] as! String), "Staging directory wasn't removed")
        print("PASS: schema-only arguments, password handoff, private response file, successful save and cleanup")

        try Data("existing schema".utf8).write(to: destination)
        for failure in ["failure", "missing", "empty"] {
            try mode(failure)
            try expectFailure()
            try require(try Data(contentsOf: destination) == Data("existing schema".utf8), "Failed export changed existing file")
            let failedCall = try invocation()
            try require(!files.fileExists(atPath: failedCall["response"] as! String), "Failed export leaked response file")
            try require(!files.fileExists(atPath: failedCall["staging"] as! String), "Failed export leaked staging")
        }
        print("PASS: process failure, missing output and empty output preserve existing files")

        try mode("success")
        try SqlPackageService().exportDacpac(input: input, to: destination)
        try require(try Data(contentsOf: destination) == Data("schema fixture".utf8), "Successful replacement failed")
        try files.removeItem(at: record)
        let cancelled = SqlPackageService()
        cancelled.cancel()
        try expectFailure(cancelled)
        try require(!files.fileExists(atPath: record.path), "Pre-cancelled export started process")
        try expectFailure(input: ConnectionInput(connectionString: "Server=fixture.invalid;User ID=test;Password=fixture-secret;", password: ""))
        try require(!files.fileExists(atPath: record.path), "Missing database started process")
        print("PASS: atomic replacement, cancellation before start, missing-database validation")

        try mode("wait")
        let running = SqlPackageService()
        let cancellation = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if files.fileExists(atPath: record.path) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            running.cancel()
            cancellation.signal()
        }
        try expectFailure(running)
        _ = cancellation.wait(timeout: .now() + 6)
        try require(try Data(contentsOf: destination) == Data("schema fixture".utf8), "Cancelled export changed destination")
        let cancelledCall = try invocation()
        try require(!files.fileExists(atPath: cancelledCall["staging"] as! String), "Cancelled export leaked partial output")
        print("PASS: running-process cancellation preserves destination and cleans partial output")
    }
}
