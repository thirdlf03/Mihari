import Testing

@testable import MihariCore

@Suite("権限の定義")
struct PermissionKindTests {

    @Test("すべての権限に表示用の文言が揃っている")
    func metadataIsComplete() {
        for kind in PermissionKind.allCases {
            #expect(!kind.title.isEmpty, "title がない: \(kind.rawValue)")
            #expect(!kind.purpose.isEmpty, "purpose がない: \(kind.rawValue)")
            #expect(!kind.api.isEmpty, "api がない: \(kind.rawValue)")
            #expect(!kind.consequenceIfDenied.isEmpty, "consequenceIfDenied がない: \(kind.rawValue)")
        }
    }

    @Test("権限ごとに開くシステム設定のペインが重複しない")
    func panesAreDistinct() {
        let panes = PermissionKind.allCases.map(\.pane)
        #expect(Set(panes).count == panes.count)
    }

    @Test("オートメーションだけはアプリから要求できない")
    func onlyAutomationHasNoRequestButton() {
        for kind in PermissionKind.allCases {
            if kind == .automation {
                #expect(kind.requestButtonTitle == nil)
            } else {
                #expect(kind.requestButtonTitle != nil, "要求ボタンがない: \(kind.rawValue)")
            }
        }
    }

    @Test("オートメーションと画面収録は未許可時の案内がある")
    func setupHintForTrickyPermissions() {
        #expect(PermissionKind.camera.setupHint == nil)
        #expect(PermissionKind.motion.setupHint == nil)
        #expect(PermissionKind.screenRecording.setupHint == "許可後はアプリの再起動が必要")
        let hint = PermissionKind.automation.setupHint
        #expect(hint != nil)
        #expect(hint?.contains("Music") == true)
        #expect(hint?.contains("Spotify") == true)
        #expect(PermissionKind.automation.purpose.contains("Spotify"))
    }
}

@Suite("権限とセーフティートグルの対応")
struct PermissionFeatureMappingTests {

    @Test("マイクと入力監視は存在しない")
    func removedKindsDoNotExist() {
        #expect(PermissionKind.allCases.map(\.rawValue).contains("microphone") == false)
        #expect(PermissionKind.allCases.map(\.rawValue).contains("inputMonitoring") == false)
    }

    @Test("camera は macCamera、automation は sermonTakeover に紐づく")
    func featureMapping() {
        #expect(PermissionKind.camera.feature == .macCamera)
        #expect(PermissionKind.automation.feature == .sermonTakeover)
        #expect(PermissionKind.screenRecording.feature == nil)
        #expect(PermissionKind.motion.feature == nil)
    }

    @Test("全 OFF ならモーションだけが出て、必須も要求対象も無い")
    func allOffPattern() {
        let settings = SafetySettings.default
        #expect(PermissionKind.relevant(for: settings) == [.motion])
        #expect(PermissionKind.required(for: settings) == [])
        #expect(PermissionKind.requestableOnLaunch(for: settings) == [])
    }

    @Test("macCamera だけ ON ならカメラが必須になる")
    func macCameraOnlyPattern() {
        var settings = SafetySettings.default
        settings.enabled = [.macCamera]
        #expect(PermissionKind.relevant(for: settings) == [.camera, .motion])
        #expect(PermissionKind.required(for: settings) == [.camera])
        #expect(PermissionKind.requestableOnLaunch(for: settings) == [.camera])
    }

    @Test("sermonTakeover だけ ON でもオートメーションは必須にならず、要求もできない")
    func sermonTakeoverOnlyPattern() {
        var settings = SafetySettings.default
        settings.enabled = [.sermonTakeover]
        #expect(PermissionKind.relevant(for: settings) == [.automation, .motion])
        // 実際に Music / Spotify へ命令を送る瞬間までプロンプトが出せないため、必須にはしない。
        #expect(PermissionKind.required(for: settings) == [])
        #expect(PermissionKind.requestableOnLaunch(for: settings) == [])
    }

    @Test("全 ON でも必須はカメラだけで、画面収録は出ない")
    func allOnPattern() {
        var settings = SafetySettings.default
        settings.enabled = Set(SafetyFeature.allCases)
        #expect(PermissionKind.relevant(for: settings) == [.camera, .automation, .motion])
        #expect(PermissionKind.required(for: settings) == [.camera])
        #expect(PermissionKind.requestableOnLaunch(for: settings) == [.camera])
    }
}
