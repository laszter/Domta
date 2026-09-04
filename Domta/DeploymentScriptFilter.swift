//
//  DeploymentScriptFilter.swift
//  Domta
//

import Foundation

nonisolated struct DeploymentScriptFilterResult {
    let script: String
    let keptSectionCount: Int
    let removedSectionCount: Int
    /// section ที่ระบุไม่ได้ว่าเป็นของ object ไหน — เก็บไว้เสมอ
    let unattributedSectionCount: Int
    let removedObjectNames: [String]

    var didFilterAnything: Bool { removedSectionCount > 0 }
}

/// ตัด deployment script ของ sqlpackage ให้เหลือเฉพาะ object ที่ผู้ใช้ติ๊กไว้
///
/// `sqlpackage` กรอง script รายตัวไม่ได้ (ทำได้แค่ระดับ object type) แต่ script ที่มันสร้าง
/// มีโครงสร้างคงที่: batch ที่มีแต่ `PRINT N'...'` เปิดหัว section แล้วตามด้วย batch ของคำสั่งจริง
/// จนกว่าจะเจอ PRINT ตัวถัดไป — ตัดที่ระดับ section นี้จึงตัดได้ทั้งก้อนโดยไม่ผ่ากลางคำสั่ง
///
/// กติกาการตัดเป็นแบบ fail-open: ตัดเฉพาะ section ที่อ้างถึง object ที่รู้จักและไม่มีตัวไหนถูกติ๊กเลย
/// section ที่ระบุเจ้าของไม่ได้ หรือแตะ object ที่ติ๊กไว้แม้แต่ตัวเดียว จะถูกเก็บไว้เสมอ
nonisolated enum DeploymentScriptFilter {
    static func filter(
        script: String,
        includedNames: Set<String>,
        knownNames: Set<String>
    ) -> DeploymentScriptFilterResult {
        guard !script.isEmpty else {
            return DeploymentScriptFilterResult(
                script: script,
                keptSectionCount: 0,
                removedSectionCount: 0,
                unattributedSectionCount: 0,
                removedObjectNames: []
            )
        }

        let batches = makeBatches(from: script)
        var output: [String] = []
        var keptSectionCount = 0
        var removedSectionCount = 0
        var unattributedSectionCount = 0
        var removedNames: [String] = []

        var index = 0

        // batch ก่อน PRINT ตัวแรกคือ preamble (SET options, :setvar, USE) — เก็บไว้ทั้งหมด
        while index < batches.count, !isHeaderBatch(batches[index]) {
            output.append(batches[index])
            index += 1
        }

        while index < batches.count {
            let header = batches[index]
            var section = [header]
            index += 1

            while index < batches.count, !isHeaderBatch(batches[index]) {
                section.append(batches[index])
                index += 1
            }

            let body = section.joined(separator: "\n")
            let referenced = qualifiedNames(in: body).intersection(knownNames)

            if referenced.isEmpty {
                unattributedSectionCount += 1
                keptSectionCount += 1
                output.append(contentsOf: section)
            } else if referenced.isDisjoint(with: includedNames) {
                removedSectionCount += 1
                removedNames.append(contentsOf: referenced)
            } else {
                keptSectionCount += 1
                output.append(contentsOf: section)
            }
        }

        return DeploymentScriptFilterResult(
            script: output.joined(separator: "\n"),
            keptSectionCount: keptSectionCount,
            removedSectionCount: removedSectionCount,
            unattributedSectionCount: unattributedSectionCount,
            removedObjectNames: Array(Set(removedNames)).sorted()
        )
    }

    /// แบ่ง script ตามบรรทัด `GO` โดยเก็บบรรทัด GO ไว้ท้าย batch เพื่อให้ต่อกลับได้เหมือนเดิม
    private static func makeBatches(from script: String) -> [String] {
        let lines = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var batches: [String] = []
        var current: [String] = []

        for line in lines {
            current.append(line)

            if line.trimmingCharacters(in: .whitespaces).uppercased() == "GO" {
                batches.append(current.joined(separator: "\n"))
                current = []
            }
        }

        if !current.isEmpty {
            batches.append(current.joined(separator: "\n"))
        }

        return batches
    }

    /// batch ที่มีแต่คำสั่ง PRINT — sqlpackage ใช้เปิดหัวทุก operation
    private static func isHeaderBatch(_ batch: String) -> Bool {
        var sawPrint = false

        for rawLine in batch.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "GO" { continue }

            guard line.uppercased().hasPrefix("PRINT ") else { return false }
            sawPrint = true
        }

        return sawPrint
    }

    /// ดึงชื่อแบบ `[schema].[object]` ทั้งหมดที่โผล่ในข้อความ (ตัดส่วนที่ 3 เช่นชื่อ index ทิ้ง)
    static func qualifiedNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "[" else {
                index += 1
                continue
            }

            var parts: [String] = []

            while index < characters.count, characters[index] == "[" {
                index += 1
                var current = ""

                while index < characters.count {
                    if characters[index] == "]" {
                        if index + 1 < characters.count, characters[index + 1] == "]" {
                            current.append("]")
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }

                    current.append(characters[index])
                    index += 1
                }

                parts.append(current)

                // ต่อส่วนถัดไปเฉพาะเมื่อเป็นรูปแบบ `.[`
                guard index + 1 < characters.count, characters[index] == ".", characters[index + 1] == "[" else { break }
                index += 1
            }

            if parts.count >= 2 {
                names.insert("\(parts[0].lowercased()).\(parts[1].lowercased())")
            }
        }

        return names
    }
}
