import Foundation

/// `AppCoordinator` の extension。在席スタンプ / 疑いチェックの Touch ID 演出
/// (カットインを伴う一連のセレモニー)の実装をここに集める。
extension AppCoordinator {

    /// 在席スタンプを押す。ペットが指を差し出し、Touch ID に指を置いて「指を合わせる」演出にする。
    ///
    /// 演出中に押し直されても何もしない。カットインが二重に出てしまうため。
    /// 押した時点で「いま席にいる」と示されたことになるので、進んでいた疑いはここで畳む。
    public func stampAttendance() {
        detection.acknowledgePresence()
        guard !isStampCeremonyRunning else { return }
        isStampCeremonyRunning = true
        Task { [weak self] in
            guard let self else { return }
            await runCeremony(.stamp)
            isStampCeremonyRunning = false
        }
    }

    /// 疑い 1 の Touch ID チェック。在席スタンプと同じ演出を、疑い用のセリフで流す。
    ///
    /// 成功しても履歴には残さない(`verify()`)。促されて置いた指で 5 分間見逃されては
    /// チェックの意味が無い。
    func confirmPresence(onPhone: Bool) async -> AttendanceStampOutcome {
        guard !isStampCeremonyRunning else { return .failed }
        isStampCeremonyRunning = true
        defer { isStampCeremonyRunning = false }
        return await runCeremony(.suspect(onPhone: onPhone))
    }

    /// 走っている Touch ID の演出を畳む。ダイアログを閉じ、結末を出さずにカットインも引っ込める。
    func cancelPresenceCheck() {
        ceremonyGeneration += 1
        attendance.cancelAuthentication()
        cutIn.dismiss()
    }

    /// Touch ID の演出をひと続きで進める。
    @discardableResult
    func runCeremony(_ variant: AttendanceCeremonyVariant) async -> AttendanceStampOutcome {
        ceremonyGeneration += 1
        let generation = ceremonyGeneration

        attendance.refreshAvailability()
        let definition = pet.controller.currentPet
        // パスワードにフォールバックする環境では「指を合わせる」が成立しないので、
        // カットインは出さずにペットの動きとセリフだけにする。
        let useCutIn = attendance.isBiometricsAvailable && (definition?.hasCutInImages ?? false)

        let opening = AttendanceCeremonyScript.opening(variant)
        pet.controller.playOnce(opening.animation)
        pet.controller.say(opening.kind)
        if useCutIn, let definition, let image = opening.cutInImage {
            cutIn.present(image, of: definition, on: pet.controller.currentScreen)
            // スライドインを見せてから認証ダイアログを出す。
            try? await Task.sleep(for: .seconds(Self.cutInLeadInSeconds))
        }

        let outcome = variant == .stamp ? await attendance.stamp() : await attendance.verify()

        // 待っているあいだに畳まれていたら、結末の演出は出さない(カットインは畳んだ側が閉じている)。
        guard generation == ceremonyGeneration else { return outcome }

        let closing = AttendanceCeremonyScript.closing(outcome, variant: variant)
        pet.controller.playOnce(closing.animation)
        pet.controller.say(closing.kind)
        guard useCutIn, let image = closing.cutInImage else { return outcome }
        cutIn.swap(to: image, flash: outcome == .stamped)
        try? await Task.sleep(for: .seconds(Self.cutInHoldSeconds))
        cutIn.dismiss()
        return outcome
    }
}
