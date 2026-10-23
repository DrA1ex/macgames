import Foundation
import Testing
@testable import MacGamesCore

@Suite struct HiDPITests {
    @Test func olderSettingsAdoptExistingRetinaModeAndKeepAnExplicitChoice() throws {
        let fixture = try FakeEnvironment(.aoe4)
        defer { fixture.cleanUp() }
        let paths = fixture.runtime.paths
        try write(#"{"optimized":true,"hud":true}"#, to: LaunchSettings.url(paths))
        try write(#"""
        WINE REGISTRY Version 2
        [Software\\Wine\\Mac Driver] 123
        "RetinaMode"="Y"
        "LogPixels"=dword:00000060
        """#, to: paths.prefix.appendingPathComponent("user.reg"))
        var settings = LaunchSettings.load(from: paths)
        #expect(settings.hiDPI == true)
        #expect(settings.optimized && settings.hud)
        settings.hiDPI = false
        try settings.save(to: paths)
        #expect(LaunchSettings.load(from: paths).hiDPI == false, "the saved switch overrides the previous registry value")
        #expect(fixture.calls.isEmpty, "reading or saving a switch must not start Wine")
    }

    @Test func toggleChangesReachAnAlreadyConfiguredPrefixInBothDirections() throws {
        let fixture = try FakeEnvironment(.aoe4)
        defer { fixture.cleanUp() }
        let game = fixture.runtime
        let env = game.environment(optimized: false, hud: false)
        func imported() throws -> String {
            let data = try Data(contentsOf: fixture.dir.appendingPathComponent("root/imported.reg"))
            return try #require(String(data: data.dropFirst(2), encoding: .utf16LittleEndian))
        }
        game.settings = LaunchSettings(hiDPI: true)
        try game.ensureRecipes(environment: env)
        #expect(try imported().contains(#""RetinaMode"="Y""#))
        try game.ensureRecipes(environment: env)
        #expect(fixture.calls.filter { $0.hasPrefix("wine reg import") }.count == 1)
        game.settings = LaunchSettings(hiDPI: false)
        try game.ensureRecipes(environment: env)
        let disabled = try imported()
        #expect(disabled.contains(#""RetinaMode"="N""#))
        #expect(!disabled.contains("LogPixels"), "render resolution must not change Windows UI scaling")
        #expect(fixture.calls.filter { $0.hasPrefix("wine reg import") }.count == 2)
    }

    @Test func defaultsRemainCompatibleAndUserCanOverrideAnExistingGameRecipe() throws {
        let plain = try FakeEnvironment(.aoe4)
        defer { plain.cleanUp() }
        #expect(plain.runtime.settings.hiDPI == false)
        let retinaGame = try FakeEnvironment(.overwatch)
        defer { retinaGame.cleanUp() }
        #expect(retinaGame.runtime.settings.hiDPI == true)
        let values = GameRecipes.registry(for: retinaGame.runtime.paths.environment, hiDPI: false)
            .filter { $0.key == WineHiDPI.key && $0.name == "RetinaMode" }
        #expect(values == [WineHiDPI.registryValue(false)], "explicit off must replace the recipe's Y value")
        try write(#"""
        [Unrelated]
        "RetinaMode"="Y"
        [Software\\Wine\\Mac Driver] 123
        "RetinaMode"="N"
        """#, to: retinaGame.runtime.paths.prefix.appendingPathComponent("user.reg"))
        #expect(retinaGame.runtime.settings.hiDPI == false, "an existing manual N also survives migration")
    }
}
