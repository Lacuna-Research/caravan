import Foundation
import Testing

@testable import CaravanUI

/// The plain-text config, whose path and format are public API.
///
/// The tests worth having here are the ones about *a user having edited the file*: a
/// settings form that quietly rewrote someone's comments, or that trusted a hand-typed
/// number, would make "user-editable" a claim rather than a property.
@MainActor
@Suite("Config file")
struct ConfigFileTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "caravan-config-\(UUID().uuidString)")
            .appending(path: "caravan.conf")
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Values

    @Test("a value written is a value read back, from disk")
    func roundTrip() {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        config.set("Andale Mono", forKey: "chat.font-family")
        config.set(17.5, forKey: "chat.font-size")
        config.set(2000, forKey: "chat.scrollback-lines")
        config.set(true, forKey: "chat.raw-traffic")

        // A second instance, so this is about the file rather than about memory.
        let reread = ConfigFile(url: url)
        #expect(reread.string("chat.font-family") == "Andale Mono")
        #expect(reread.double("chat.font-size") == 17.5)
        #expect(reread.int("chat.scrollback-lines") == 2000)
        #expect(reread.bool("chat.raw-traffic") == true)
    }

    @Test("an absent key is absent, not empty")
    func absentKey() {
        let config = ConfigFile(url: temporaryFile())
        #expect(config.string("chat.font-family") == nil)
        #expect(config.int("chat.scrollback-lines") == nil)
        #expect(config.bool("chat.raw-traffic") == nil)
    }

    /// The empty string is a value in its own right: it is how `timestamp-format` says
    /// "no timestamps at all", which is different from "not configured".
    @Test("an empty value is an empty string, not an absence")
    func emptyValue() {
        let url = temporaryFile()
        ConfigFile(url: url).set("", forKey: "chat.timestamp-format")
        #expect(ConfigFile(url: url).string("chat.timestamp-format") == "")
    }

    @Test("setting nil removes the line, restoring the default")
    func removal() {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        config.set("Menlo", forKey: "chat.font-family")
        config.set(nil, forKey: "chat.font-family")
        #expect(ConfigFile(url: url).string("chat.font-family") == nil)
    }

    @Test("yes, on and 1 all read as true")
    func booleanSpellings() throws {
        let url = temporaryFile()
        try write("a = yes\nb = on\nc = 1\nd = No\ne = perhaps\n", to: url)
        let config = ConfigFile(url: url)
        #expect(config.bool("a") == true)
        #expect(config.bool("b") == true)
        #expect(config.bool("c") == true)
        #expect(config.bool("d") == false)
        #expect(config.bool("e") == nil)
    }

    // MARK: - Surviving a text editor

    /// The point of the whole format. A form that ate this file's comments would make it
    /// editable in name only.
    @Test("comments and unknown keys survive a write")
    func preservesUserText() throws {
        let url = temporaryFile()
        try write(
            """
            # My settings. Do not lose this comment.
            chat.font-family = Menlo

            ; an unknown key from a later version
            future.setting = 42
            """,
            to: url
        )

        let config = ConfigFile(url: url)
        config.set("SF Mono", forKey: "chat.font-family")

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("# My settings. Do not lose this comment."))
        #expect(written.contains("; an unknown key from a later version"))
        #expect(written.contains("future.setting = 42"))
        #expect(written.contains("chat.font-family = SF Mono"))
        #expect(!written.contains("Menlo"))
    }

    @Test("spacing around the separator is not significant")
    func tolerantParsing() throws {
        let url = temporaryFile()
        try write("chat.font-family=Menlo\n   chat.font-size   =   14  \n", to: url)
        let config = ConfigFile(url: url)
        #expect(config.string("chat.font-family") == "Menlo")
        #expect(config.double("chat.font-size") == 14)
    }

    /// A value containing an `=` is a path or a format string, not two keys.
    @Test("only the first separator splits the line")
    func firstSeparatorWins() throws {
        let url = temporaryFile()
        try write("chat.timestamp-format = [HH:mm] = \n", to: url)
        #expect(ConfigFile(url: url).string("chat.timestamp-format") == "[HH:mm] =")
    }

    @Test("a file that does not exist yet reads as empty and writes cleanly")
    func missingFile() {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        #expect(config.string("anything") == nil)
        config.set("Menlo", forKey: "chat.font-family")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The explanatory header is written once, above a file with no comment of its own —
    /// not prepended again on every save.
    @Test("the header is written once")
    func headerWrittenOnce() throws {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        config.set("Menlo", forKey: "chat.font-family")
        config.set(14.0, forKey: "chat.font-size")
        config.set("SF Mono", forKey: "chat.font-family")

        let written = try String(contentsOf: url, encoding: .utf8)
        let headers = written.components(separatedBy: "# Caravan configuration").count - 1
        #expect(headers == 1)
    }

    @Test("saving repeatedly does not grow the file with blank lines")
    func stableLineCount() throws {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        for size in 10...20 { config.set(Double(size), forKey: "chat.font-size") }
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.components(separatedBy: "\n").count < 8)
        #expect(ConfigFile(url: url).double("chat.font-size") == 20)
    }

    // MARK: - Settings on top of it

    @Test("settings take their defaults from an untouched file")
    func settingsDefaults() {
        let settings = ChatSettings(config: ConfigFile(url: temporaryFile()))
        #expect(settings.fontFamily == ChatFont.defaultFamily)
        #expect(settings.fontSize == ChatFont.defaultSize)
        #expect(settings.timestampFormat == ChatSettings.Default.timestampFormat)
        #expect(settings.scrollbackLines == ChatSettings.Default.scrollbackLines)
        #expect(settings.showsRawTraffic == ChatSettings.Default.showsRawTraffic)
        #expect(settings.nickListWidth == ChatSettings.Default.nickListWidth)
        #expect(settings.isNickListVisible == ChatSettings.Default.nickListVisible)
    }

    /// This number and this size arrive from a text editor as readily as from the form,
    /// and a cap of zero would make every buffer silently empty.
    @Test("hand-edited numbers are clamped, not obeyed")
    func settingsClampHandEdits() throws {
        let url = temporaryFile()
        try write("chat.scrollback-lines = 0\nchat.font-size = 0\n", to: url)
        let settings = ChatSettings(config: ConfigFile(url: url))
        #expect(settings.scrollbackLines == ChatSettings.scrollbackRange.lowerBound)
        #expect(settings.fontSize == ChatSettings.fontSizeRange.lowerBound)

        settings.scrollbackLines = 10_000_000
        #expect(settings.scrollbackLines == ChatSettings.scrollbackRange.upperBound)
    }

    @Test("settings persist through the file, not through memory")
    func settingsPersist() {
        let url = temporaryFile()
        let settings = ChatSettings(config: ConfigFile(url: url))
        settings.timestampFormat = "[HH:mm]"
        settings.scrollbackLines = 250
        // The nick list's state moved here too: one persistence mechanism, or a setting
        // that does not stick has two places to look.
        settings.nickListWidth = 240
        settings.isNickListVisible = false

        let reloaded = ChatSettings(config: ConfigFile(url: url))
        #expect(reloaded.timestampFormat == "[HH:mm]")
        #expect(reloaded.scrollbackLines == 250)
        #expect(reloaded.nickListWidth == 240)
        #expect(reloaded.isNickListVisible == false)
    }

    // MARK: - The Connect sheet's values

    @Test("last-used connection values round-trip")
    func connectionSettingsRoundTrip() {
        let url = temporaryFile()
        let config = ConfigFile(url: url)
        let settings = ConnectionSettings(
            host: "irc.example.net",
            port: 6667,
            useTLS: false,
            nick: "alice",
            altNick: "alice_",
            ident: "alice",
            realName: "Alice Example",
            password: "s3cr3t-not-real"
        )
        settings.rememberAsLastUsed(in: config)

        let loaded = ConnectionSettings.lastUsed(from: ConfigFile(url: url))
        #expect(loaded.host == "irc.example.net")
        #expect(loaded.port == 6667)
        #expect(loaded.useTLS == false)
        #expect(loaded.nick == "alice")
        #expect(loaded.altNick == "alice_")
        #expect(loaded.realName == "Alice Example")
    }

    /// The rule the whole settings story rests on: credentials go to the Keychain, and
    /// until that exists they are written nowhere at all.
    @Test("a password never reaches the config file")
    func passwordIsNeverWritten() throws {
        let url = temporaryFile()
        var settings = ConnectionSettings.lastUsed(from: ConfigFile(url: url))
        settings.nick = "alice"
        settings.password = "s3cr3t-not-real"
        settings.rememberAsLastUsed(in: ConfigFile(url: url))

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("s3cr3t-not-real"))
        #expect(ConnectionSettings.lastUsed(from: ConfigFile(url: url)).password.isEmpty)
    }
}
