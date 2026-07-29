import Foundation
@testable import NostromoCodexCore
import XCTest

final class CodexSkillCatalogTests: XCTestCase {
    func testLoadTimesOutWhenAppServerNeverResponds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("silent-app-server")
        try Data("#!/bin/sh\nexec sleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let catalog = CodexSkillCatalog(
            executableURL: executable,
            workspace: directory,
            responseTimeout: 0.1
        )
        let started = Date()
        XCTAssertThrowsError(try catalog.load())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testParsesAuthoritativeSkillMetadataAndEnabledState() throws {
        let data = Data(
            """
            {
              "id": 2,
              "result": {
                "data": [{
                  "cwd": "/tmp/project",
                  "skills": [{
                    "name": "alpha-skill",
                    "description": "Alpha",
                    "path": "/tmp/alpha/SKILL.md",
                    "scope": "repo",
                    "enabled": false,
                    "interface": {"displayName": "Alpha Skill"}
                  }, {
                    "name": "beta-skill",
                    "description": "Beta",
                    "path": "/tmp/beta/SKILL.md",
                    "scope": "user",
                    "enabled": true
                  }],
                  "errors": []
                }]
              }
            }
            """.utf8
        )

        let skills = try CodexSkillCatalog.parseSkillsListResponse(data)
        XCTAssertEqual(skills.map(\.displayName), ["Alpha Skill", "beta skill"])
        XCTAssertFalse(skills[0].enabled)
        XCTAssertTrue(skills[1].enabled)
    }

    func testRejectsMalformedOrErrorResponse() {
        XCTAssertThrowsError(
            try CodexSkillCatalog.parseSkillsListResponse(Data("{}".utf8))
        )
        XCTAssertThrowsError(
            try CodexSkillCatalog.parseSkillsListResponse(
                Data(#"{"id":2,"error":{"message":"denied"}}"#.utf8)
            )
        )
    }
}
