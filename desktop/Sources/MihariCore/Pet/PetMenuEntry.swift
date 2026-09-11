import Foundation

/// ペットメニューの 1 項目。右クリック(NSMenu)とメニューバー(SwiftUI)で同じ並びを出すための共通表現。
public enum PetMenuEntry {
    /// 項目。`isChecked` が true ならチェックを付ける。`isEnabled` が false なら
    /// 灰色にして押せなくする(理由はタイトルに載せる)。
    case item(
        title: String,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        action: @MainActor () -> Void
    )
    /// 入れ子のメニュー。
    case submenu(title: String, entries: [PetMenuEntry])
    /// 区切り線。
    case separator
}

/// ペットメニューの並びを 1 か所で決める。
///
/// 右クリック(`PetContextMenu`)もメニューバー(`PetMenuContent`)もここから作るので、
/// 項目を足すときはここだけを直せばよい。
public enum PetMenuEntries {

    /// メニューの並びを組み立てる。呼ぶたびに、そのときの状態でチェックと文言を決める。
    @MainActor
    public static func make<Actions: PetMenuActions>(
        actions: Actions,
        presenter: LivePetPresenter
    ) -> [PetMenuEntry] {
        let pet = presenter.controller
        var entries: [PetMenuEntry] = [
            // 最上段はセーフティーモードの表示。押すと設定画面のセーフティータブへ直行する。
            // 末尾の › で「タップで別の場(設定)へ飛ぶ項目」だと分かるようにする。
            .item(
                title: actions.safetyStatusLine + "  ›",
                action: { actions.openSettings(tab: .safety) }
            ),
            .separator,
            .item(
                title: actions.isWatching ? "監視を止める" : "監視を再開する",
                action: {
                    if actions.isWatching {
                        actions.stopWatching()
                    } else {
                        actions.startWatching()
                    }
                }
            ),
            .item(
                title: "在席スタンプを押す",
                action: { actions.stampAttendance() }
            ),
            .item(
                title: actions.isOnBreak ? "休憩を終える" : "休憩する(15 分)",
                action: {
                    if actions.isOnBreak {
                        actions.endBreak()
                    } else {
                        actions.startBreak()
                    }
                }
            ),
            .separator,
            .submenu(
                title: "サイズ",
                entries: PetScale.allCases.map { item -> PetMenuEntry in
                    .item(
                        title: item.label,
                        isChecked: pet.scale == item.rawValue,
                        action: { pet.setScale(item.rawValue) }
                    )
                }
            ),
        ]
        // 着せ替えを持たないペットでは「髪色」「服」ごと出さない。
        entries.append(contentsOf: wardrobeEntries(pet: pet))
        entries.append(contentsOf: [
            .item(
                title: "声を出す",
                isChecked: pet.isVoiceEnabled,
                action: { pet.setVoiceEnabled(!pet.isVoiceEnabled) }
            ),
            .item(
                title: "スクショに写り込む",
                isChecked: actions.isPhotobombEnabled,
                action: { actions.setPhotobombEnabled(!actions.isPhotobombEnabled) }
            ),
            .separator,
            // じっくり決める設定(セーフティー / Discord / 権限)はこの 1 つに寄せてある。
            // タブは前回開いていたものを引き継ぐので、ここでは指定しない。
            .item(
                title: "設定…",
                action: { actions.openSettings(tab: nil) }
            ),
        ])
        // 執行猶予脱出は quitLock が ON でロック中のときだけ出す(#52)。
        switch actions.escapeMenuState {
        case .available:
            entries.append(
                .item(title: "どうしても終了する…", action: { actions.openEscapeDialog() })
            )
        case .coolingDown(let remaining):
            // 冷却中は灰色にして押せなくする。理由はタイトルに載せて伝える。
            entries.append(
                .item(
                    title: "どうしても終了する(あと\(EscapePolicy.durationDescription(remaining))で使えます)",
                    isEnabled: false,
                    action: {}
                )
            )
        case .countingDown(let remaining):
            entries.append(
                .item(
                    title: "終了を取り消す(あと\(EscapePolicy.durationDescription(remaining)))",
                    action: { actions.cancelEscape() }
                )
            )
        case .hidden:
            break
        }
        // デバッグメニューは開発中だけ出す。一般ユーザーの右クリックから消すのと同時に、
        // その直前の区切り線も消して「実在しない見た目の項目」を残さない。
        if actions.isDebugMenuVisible {
            entries.append(.separator)
            entries.append(
                .submenu(
                    title: "デバッグ",
                    entries: PetDebugMenuEntries.make(actions: actions, presenter: presenter)
                )
            )
        }
        return entries
    }

    /// 「髪色」「服」のチェック式サブメニュー。着せ替えを持たないペットでは空を返す。
    ///
    /// 一覧は `wardrobe` に書いた順のまま全部出し、絵が無くて選べない組み合わせだけ灰色にする。
    @MainActor
    private static func wardrobeEntries(pet: PetController) -> [PetMenuEntry] {
        guard let wardrobe = pet.currentPet?.wardrobe, let selection = pet.wardrobeSelection else {
            return []
        }
        let hairColors = Set(pet.availableHairColors.map(\.id))
        let outfits = Set(pet.availableOutfits.map(\.id))
        return [
            .submenu(
                title: "髪色",
                entries: wardrobe.hairColors.map { option -> PetMenuEntry in
                    .item(
                        title: option.label,
                        isChecked: selection.hairColor == option.id,
                        isEnabled: hairColors.contains(option.id),
                        action: { pet.setHairColor(option.id) }
                    )
                }
            ),
            .submenu(
                title: "服",
                entries: wardrobe.outfits.map { option -> PetMenuEntry in
                    .item(
                        title: option.label,
                        isChecked: selection.outfit == option.id,
                        isEnabled: outfits.contains(option.id),
                        action: { pet.setOutfit(option.id) }
                    )
                }
            ),
        ]
    }
}
