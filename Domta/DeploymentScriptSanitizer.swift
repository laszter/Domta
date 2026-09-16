//
//  DeploymentScriptSanitizer.swift
//  Domta
//

import Foundation

nonisolated struct DeploymentScriptSanitizerResult {
    let script: String
    /// จำนวนบรรทัดคำสั่ง SQLCMD (`:setvar`, `:on error exit`) และ batch ตรวจ SQLCMD mode ที่ถูกถอดออก
    let removedDirectiveCount: Int
    /// ตัวแปรที่ถูกแทนค่าลงไปใน script เช่น `DatabaseName`
    let substitutedVariables: [String: String]
}

/// แปลง deployment script ของ sqlpackage / DacFx ให้เป็น T-SQL ล้วน
///
/// script ที่ DacFx สร้างเป็น **SQLCMD script** เสมอ: มี `:setvar DatabaseName "..."`, `:on error exit`
/// และ batch ที่ตรวจว่าอยู่ใน SQLCMD mode ไหม (`IF N'$(__IsSqlCmdEnabled)' NOT LIKE N'True' ... SET NOEXEC ON`)
/// เอาไปวางใน query editor ธรรมดา (VS Code mssql, ADS ที่ไม่เปิด SQLCMD mode, SSMS ปกติ) จะได้
/// `Incorrect syntax near ':'` ที่บรรทัด `:setvar` หรือถ้าผ่านไปได้ก็โดน `SET NOEXEC ON` ทำให้ทั้ง script
/// ไม่ทำอะไรเลยแบบเงียบ ๆ — นี่คือสาเหตุยอดนิยมของ "gen script ได้แต่รันแล้ว error"
///
/// วิธีแปลง:
/// 1. อ่านค่า `:setvar Name "Value"` ทั้งหมดไว้ก่อน แล้วแทน `$(Name)` ทุกจุดด้วยค่านั้น
///    (`USE [$(DatabaseName)];` จึงกลายเป็น `USE [ชื่อจริง];` ซึ่ง sqlpackage ออกให้เฉพาะ target ที่ไม่ใช่ Azure)
/// 2. ถอดบรรทัดที่ขึ้นต้นด้วย `:` ทั้งหมด และทิ้ง batch ที่อ้าง `$(__IsSqlCmdEnabled)`
/// 3. batch ที่เหลือแต่ comment (เช่นกล่อง "Detect SQLCMD mode") ทิ้งไปด้วย ยกเว้น batch แรกที่เป็นหัว script
///
/// การแบ่ง batch ใช้ตัวเดียวกับ `DeploymentScriptFilter` (ตัดที่บรรทัด `GO`) จึงไม่ผ่ากลางคำสั่ง
nonisolated enum DeploymentScriptSanitizer {
    static func plainTSQL(_ script: String) -> DeploymentScriptSanitizerResult {
        guard !script.isEmpty else {
            return DeploymentScriptSanitizerResult(script: script, removedDirectiveCount: 0, substitutedVariables: [:])
        }

        let batches = DeploymentScriptFilter.makeBatches(from: script)

        var variables: [String: String] = [:]
        for batch in batches {
            for line in batch.components(separatedBy: "\n") {
                if let (name, value) = parseSetvar(line) {
                    variables[name] = value
                }
            }
        }

        var output: [String] = []
        var removed = 0

        for (index, batch) in batches.enumerated() {
            if batch.contains("$(__IsSqlCmdEnabled)") {
                removed += 1
                continue
            }

            var keptLines: [String] = []
            for line in batch.components(separatedBy: "\n") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(":") {
                    removed += 1
                    continue
                }
                keptLines.append(line)
            }

            var text = keptLines.joined(separator: "\n")
            for (name, value) in variables {
                text = text.replacingOccurrences(of: "$(\(name))", with: value)
            }

            // batch แรกคือหัว script (comment "Deployment script for ...") เก็บไว้ให้คนอ่านรู้ที่มา
            if index > 0, !containsExecutableStatement(text) {
                continue
            }

            output.append(text)
        }

        return DeploymentScriptSanitizerResult(
            script: output.joined(separator: "\n"),
            removedDirectiveCount: removed,
            substitutedVariables: variables
        )
    }

    /// `:setvar Name "Value"` — ค่าอาจว่างได้ (`:setvar DefaultDataPath ""`)
    static func parseSetvar(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(":setvar ") else { return nil }

        let rest = trimmed.dropFirst(":setvar ".count).trimmingCharacters(in: .whitespaces)
        guard let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (String(rest), "")
        }

        let name = String(rest[..<space])
        var value = rest[space...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }

        return (name, value)
    }

    /// มีคำสั่งจริงไหม หลังตัด comment (`/* */` และ `--`), บรรทัดว่าง และ `GO` ออก
    static func containsExecutableStatement(_ text: String) -> Bool {
        var isInsideBlockComment = false

        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine

            while !line.isEmpty {
                if isInsideBlockComment {
                    guard let end = line.range(of: "*/") else { line = ""; break }
                    line = String(line[end.upperBound...])
                    isInsideBlockComment = false
                    continue
                }

                if let start = line.range(of: "/*") {
                    let before = line[..<start.lowerBound]
                    if hasCode(String(before)) { return true }
                    line = String(line[start.upperBound...])
                    isInsideBlockComment = true
                    continue
                }

                if let comment = line.range(of: "--") {
                    line = String(line[..<comment.lowerBound])
                }

                if hasCode(line) { return true }
                line = ""
            }
        }

        return false
    }

    private static func hasCode(_ fragment: String) -> Bool {
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.uppercased() != "GO"
    }
}
