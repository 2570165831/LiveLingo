import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LiveLingo

/// Synthetic captions and injected callbacks only. No model, recording, app
/// container, focus change, opaque window or native popup is needed here.
/// This host does not reliably expose AX descendants. Real rendered pixels and
/// the event handlers shared by the production buttons remain mandatory.
@MainActor
final class ChineseRecognitionPresentationTests: XCTestCase {
    private var artifactDirectory: URL?

    private func english() -> TranscriptSegment {
        TranscriptSegment(startTime: 12, endTime: 15,
            english: "The reaction rate increases with temperature.",
            chinese: "反应速率随温度升高而增加。")
    }

    private func presentation(_ status: ChineseRecognitionStatus? = nil,
                              availability: ChineseRecognitionAvailability = .available,
                              canUndo: Bool = false) -> ChineseRecognitionRowPresentation {
        .init(status: status, availability: availability, canUndo: canUndo)
    }

    private func row(_ segment: TranscriptSegment, state: ChineseRecognitionPresentationState,
                     availability: ChineseRecognitionAvailability = .available,
                     stream: FinalCaptionState? = nil,
                     recognize: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                     undo: @escaping () -> Void = {}) -> ChineseRecognitionCaptionRow {
        ChineseRecognitionCaptionRow(segment: segment, textSize: 18, stream: stream ?? FinalCaptionState(),
            state: state, availability: { availability }, recognize: recognize, cancel: cancel, undo: undo)
    }

    func testMenuAvailabilityDependsOnAudioAndBlocksDuplicateRequests() {
        XCTAssertTrue(presentation().canRecognize)
        XCTAssertNil(presentation().unavailableReason)
        let reason = "只实时不保存模式未保留此句录音，无法重新识别。"
        let missing = presentation(availability: .unavailable(reason))
        XCTAssertFalse(missing.canRecognize)
        XCTAssertEqual(missing.unavailableReason, reason)
        XCTAssertNotNil(presentation(availability: .init(isAvailable: false, reason: nil)).unavailableReason)
        let active = presentation(.recognizing, canUndo: true)
        XCTAssertFalse(active.canRecognize)
        XCTAssertTrue(active.isRecognizing)
        XCTAssertFalse(active.canUndo)
        XCTAssertEqual(active.statusText, "正在按中文重新识别…")
        XCTAssertTrue(presentation(.completed, canUndo: true).canUndo)
        XCTAssertTrue(presentation(.completed, availability: .unavailable(reason), canUndo: true).canUndo,
                      "Undo must remain available even after the recording is gone")
        XCTAssertNil(presentation(.completed, canUndo: true).statusText)
    }

    func testWaitingAndSavingExplainDisabledActionsAndAccessibilityLabels() {
        let waitingReason = "正在等待实时转写结束，暂不能重新识别或撤销；可取消本次请求。"
        let waiting = presentation(.waitingForRealtime, canUndo: true)
        XCTAssertTrue(waiting.isBusy)
        XCTAssertFalse(waiting.isRecognizing)
        XCTAssertTrue(waiting.canCancel)
        XCTAssertFalse(waiting.canRecognize)
        XCTAssertTrue(waiting.showsUndo)
        XCTAssertFalse(waiting.canUndo)
        XCTAssertFalse(waiting.isFailure)
        XCTAssertEqual(waiting.statusText, "等待实时转写结束…")
        XCTAssertEqual(waiting.unavailableReason, waitingReason)
        XCTAssertEqual(waiting.undoUnavailableReason, waitingReason)
        XCTAssertEqual(waiting.statusAccessibilityLabel, "等待实时转写结束，可取消中文重识别。")
        XCTAssertEqual(waiting.cancelAccessibilityLabel, "取消等待中的中文重识别")
        XCTAssertEqual(waiting.actionsAccessibilityLabel, "字幕操作：等待实时转写结束，可取消中文重识别。")

        let savingReason = "正在保存中文识别结果，保存结束后才能重新识别或撤销，暂不可取消。"
        let saving = presentation(.saving, canUndo: true)
        XCTAssertTrue(saving.isBusy)
        XCTAssertFalse(saving.isRecognizing)
        XCTAssertFalse(saving.canCancel)
        XCTAssertFalse(saving.canRecognize)
        XCTAssertTrue(saving.showsUndo, "Keep the undo action visible with its disabled explanation")
        XCTAssertFalse(saving.canUndo)
        XCTAssertFalse(saving.isFailure)
        XCTAssertEqual(saving.statusText, "中文已识别，正在保存，暂不可撤销。")
        XCTAssertEqual(saving.unavailableReason, savingReason)
        XCTAssertEqual(saving.undoUnavailableReason, savingReason)
        XCTAssertEqual(saving.statusAccessibilityLabel, "中文已识别，正在保存，暂不可撤销。")
        XCTAssertEqual(saving.actionsAccessibilityLabel, "字幕操作：中文已识别，正在保存，暂不可撤销。")

        let missingAudio = ChineseRecognitionAvailability.unavailable("此句录音已不在本机。")
        for (status, reason) in [(ChineseRecognitionStatus.waitingForRealtime, waitingReason), (.saving, savingReason)] {
            let busy = presentation(status, availability: missingAudio, canUndo: true)
            XCTAssertEqual(busy.unavailableReason, reason, "The owned task must explain why actions are blocked")
            XCTAssertEqual(busy.undoUnavailableReason, reason, "Undo is blocked by the task, not by missing audio")
        }
        XCTAssertFalse(presentation(.waitingForRealtime).showsUndo)
        XCTAssertNil(presentation(.waitingForRealtime).undoUnavailableReason)
        XCTAssertFalse(presentation(.saving).showsUndo)
        XCTAssertNil(presentation(.saving).undoUnavailableReason)

        let completed = presentation(.completed, canUndo: true)
        XCTAssertFalse(completed.isBusy)
        XCTAssertFalse(completed.canCancel)
        XCTAssertTrue(completed.canRecognize)
        XCTAssertTrue(completed.canUndo)
        XCTAssertNil(completed.statusText)
        XCTAssertNil(completed.statusAccessibilityLabel)
        XCTAssertNil(completed.unavailableReason)
        XCTAssertNil(completed.undoUnavailableReason)
        XCTAssertEqual(completed.actionsAccessibilityLabel, "字幕操作：按中文重新识别或撤销")
    }

    func testFailureAndCancellationExplicitlyPreserveOriginalCaption() {
        let failed = presentation(.failed("录音读取失败"))
        XCTAssertTrue(failed.isFailure)
        XCTAssertEqual(failed.statusText, "按中文重新识别失败：录音读取失败；原句已保留。")
        XCTAssertTrue(failed.canRecognize)
        let failedRetry = presentation(.failed("录音读取失败"), canUndo: true)
        XCTAssertEqual(failedRetry.statusText, "按中文重新识别失败：录音读取失败；原句已保留。")
        XCTAssertTrue(failedRetry.canUndo, "A previous Chinese revision must remain undoable after recognition fails")
        let cancelled = presentation(.cancelled)
        XCTAssertFalse(cancelled.isFailure)
        XCTAssertEqual(cancelled.statusText, "已取消中文重识别，原句已保留。")
        XCTAssertTrue(cancelled.canRecognize)
    }

    func testSavingFailureKeepsChinesePreservationNoticeAndAllowsUndo() throws {
        let reason = "中文原文已保留，但存档或导出尚未保存完成；可以撤销，或重试保存。"
        let failedSave = presentation(.failed(reason), canUndo: true)
        XCTAssertTrue(failedSave.isFailure)
        XCTAssertFalse(failedSave.isBusy)
        XCTAssertFalse(failedSave.canCancel)
        XCTAssertTrue(failedSave.canRecognize)
        XCTAssertTrue(failedSave.showsUndo)
        XCTAssertTrue(failedSave.canUndo)
        XCTAssertEqual(failedSave.statusText, reason)
        XCTAssertEqual(failedSave.statusAccessibilityLabel, reason)
        let notice = try XCTUnwrap(failedSave.statusText)
        XCTAssertFalse(notice.contains("按中文重新识别失败"))
        XCTAssertFalse(notice.contains("原句已保留"))
        XCTAssertNil(failedSave.unavailableReason)
        XCTAssertNil(failedSave.undoUnavailableReason)
    }

    func testManualChineseKeepsExactOriginalForEveryDisplayTargetWithoutConversion() {
        var segment = english()
        let source = "這裡的 DNA 濃度是 0.5 mg/mL，温度是二十五度。"
        segment.applyChineseRecognition(source)
        XCTAssertTrue(segment.isChineseOriginal)
        XCTAssertTrue(segment.canUndoChineseRecognition)
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        for language in OutputLanguage.allCases {
            let caption = CaptionPresentation(segment, outputLanguage: language, converter: converter)
            XCTAssertTrue(caption.isSourceOnly, language.rawValue)
            XCTAssertEqual(caption.languageName, "中文原文", language.rawValue)
            XCTAssertEqual(caption.sourceLanguage, "zh", language.rawValue)
            XCTAssertEqual(Data(caption.primaryText.utf8), Data(source.utf8), language.rawValue)
        }
        for target in [CaptionTranslationTarget.simplifiedChinese, .english, .spanish, .french] {
            let caption = CaptionPresentation(segment, target: target)
            XCTAssertTrue(caption.isSourceOnly)
            XCTAssertEqual(caption.languageName, "中文原文")
            XCTAssertEqual(Data(caption.primaryText.utf8), Data(source.utf8))
        }
        XCTAssertEqual(converter.debugLoadCount, 0, "Manual source captions must not load script dictionaries")
    }

    func testEntryAndUnavailableMenuUseRealSharedSwiftUIActionsOffscreen() async throws {
        let segment = english()
        let state = ChineseRecognitionPresentationState()
        var recognitions = 0
        let recognize = { recognitions += 1; state.statuses[segment.id] = .recognizing }
        let actions = ChineseRecognitionCaptionMenu(presentation: presentation(),
            recognize: recognize, cancel: {}, undo: {})
        var hovered = row(segment, state: state, recognize: recognize)
        hovered.hoveredForTesting = true
        let entry = try await host(VStack(alignment: .leading, spacing: 16) {
            hovered
            // The shared menu content is mounted directly; an NSMenu popup
            // would require a visible surface and is deliberately never opened.
            VStack(alignment: .leading, spacing: 8) {
                Text("右键菜单内容").font(.caption).foregroundStyle(.secondary)
                actions
            }.padding(.horizontal, 84)
        }, height: 260)
        try capture(entry, name: "chinese-recognition-entry")
        let hoveredOnly = try await host(hovered, height: 200)
        let unhovered = try await host(row(segment, state: ChineseRecognitionPresentationState()), height: 200)
        XCTAssertNotEqual(try png(hoveredOnly), try png(unhovered), "The real hover menu entry must be drawn")
        XCTAssertTrue(actions.presentation.canRecognize)
        actions.performRecognition()
        XCTAssertEqual(recognitions, 1)
        try await settle(entry)
        XCTAssertEqual(state.statuses[segment.id], .recognizing)
        let activeActions = ChineseRecognitionCaptionMenu(presentation: presentation(.recognizing),
            recognize: recognize, cancel: {}, undo: {})
        activeActions.performRecognition()
        XCTAssertEqual(recognitions, 1, "The shared button handler must also reject duplicate requests")

        let reason = "只实时不保存模式未保留此句录音，无法重新识别。"
        let unavailableActions = ChineseRecognitionCaptionMenu(
            presentation: presentation(availability: .unavailable(reason)),
            recognize: { XCTFail("Unavailable audio must not be submitted") }, cancel: {}, undo: {})
        let unavailable = try await host(VStack(alignment: .leading, spacing: 12) {
            unavailableActions
        }.padding(20), height: 160)
        try capture(unavailable, name: "chinese-recognition-unavailable")
        XCTAssertFalse(unavailableActions.presentation.canRecognize)
        XCTAssertEqual(unavailableActions.presentation.unavailableReason, reason)
        unavailableActions.performRecognition()
    }

    func testMountedRowObservesProgressCancelAndFailureWithoutReplacingText() async throws {
        let segment = english()
        let state = ChineseRecognitionPresentationState()
        var cancellations = 0
        let root = row(segment, state: state, cancel: {
            cancellations += 1
            state.statuses[segment.id] = .cancelled
        })
        let view = try await host(root, height: 250)
        let originalPixels = try png(view)
        state.statuses[segment.id] = .recognizing
        try await settle(view)
        try capture(view, name: "chinese-recognition-progress")
        XCTAssertNotEqual(try png(view), originalPixels, "The mounted row must draw its progress and cancellation controls")
        XCTAssertEqual(presentation(state.statuses[segment.id]).statusText, "正在按中文重新识别…")
        root.performCancellation()
        try await settle(view)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(state.statuses[segment.id], .cancelled)
        try capture(view, name: "chinese-recognition-cancelled")
        XCTAssertEqual(presentation(state.statuses[segment.id]).statusText, "已取消中文重识别，原句已保留。")
        let expectedCancelled = try await host(expectedRow(segment, status: .cancelled), height: 250)
        XCTAssertEqual(try png(view), try png(expectedCancelled), "The mounted row must actually replace progress with the cancellation notice")
        root.performCancellation()
        XCTAssertEqual(cancellations, 1, "Inactive inline cancellation must not dispatch again")

        state.statuses[segment.id] = .failed("未得到可靠的中文结果")
        try await settle(view)
        try capture(view, name: "chinese-recognition-failed")
        XCTAssertEqual(presentation(state.statuses[segment.id]).statusText,
                       "按中文重新识别失败：未得到可靠的中文结果；原句已保留。")
        let expectedFailure = try await host(expectedRow(segment, status: .failed("未得到可靠的中文结果")), height: 250)
        XCTAssertEqual(try png(view), try png(expectedFailure), "Failure must render with the original bilingual caption still present")
    }

    func testWaitingRowAndMenusRenderReasonAndAllowCancellationOffscreen() async throws {
        var segment = english()
        segment.applyChineseRecognition("已有中文原文，等待中的请求不应替换它。")
        let state = ChineseRecognitionPresentationState()
        var recognitions = 0
        var cancellations = 0
        var undos = 0
        let root = row(segment, state: state, recognize: { recognitions += 1 }, cancel: {
            cancellations += 1
            state.statuses[segment.id] = .cancelled
        }, undo: { undos += 1 })
        let view = try await host(root, height: 250)
        let originalPixels = try png(view)
        state.statuses[segment.id] = .waitingForRealtime
        try await settle(view)
        try capture(view, name: "chinese-recognition-waiting")
        XCTAssertNotEqual(try png(view), originalPixels, "Waiting must be visible on the mounted caption")
        XCTAssertEqual(CaptionPresentation(segment).primaryText, "已有中文原文，等待中的请求不应替换它。")

        let actions = ChineseRecognitionCaptionMenu(
            presentation: presentation(.waitingForRealtime, canUndo: segment.canUndoChineseRecognition),
            recognize: { recognitions += 1 }, cancel: root.performCancellation, undo: { undos += 1 })
        let menu = try await host(VStack(alignment: .leading, spacing: 12) { actions }.padding(20), height: 200)
        try capture(menu, name: "chinese-recognition-waiting-menu")
        XCTAssertFalse(actions.presentation.canRecognize)
        XCTAssertFalse(actions.presentation.canUndo)
        XCTAssertTrue(actions.presentation.showsUndo)
        XCTAssertTrue(actions.presentation.canCancel)
        XCTAssertNotNil(actions.presentation.unavailableReason)
        actions.performRecognition()
        actions.performUndo()
        XCTAssertEqual(recognitions, 0)
        XCTAssertEqual(undos, 0)
        actions.performCancellation()
        XCTAssertEqual(cancellations, 1, "The menu must cancel a queued request")
        XCTAssertEqual(state.statuses[segment.id], .cancelled)
        try await settle(view)
        let expectedCancelled = try await host(expectedRow(segment, status: .cancelled), height: 250)
        XCTAssertEqual(try png(view), try png(expectedCancelled), "Cancelling a queued request must preserve the caption")

        state.statuses[segment.id] = .waitingForRealtime
        let inline = ChineseRecognitionCaptionStatus(presentation: presentation(.waitingForRealtime),
            cancel: root.performCancellation)
        inline.performCancellation()
        XCTAssertEqual(cancellations, 2, "The inline button must also cancel a queued request")
        XCTAssertEqual(state.statuses[segment.id], .cancelled)
        root.performCancellation()
        XCTAssertEqual(cancellations, 2, "An inactive row must not dispatch another cancellation")
    }

    func testSavingRowAndMenusBlockActionsUntilCompletedOffscreen() async throws {
        var segment = english()
        segment.applyChineseRecognition("中文已经识别，保存中的原文应继续显示。")
        let state = ChineseRecognitionPresentationState()
        state.statuses[segment.id] = .saving
        var recognitions = 0
        var cancellations = 0
        var undos = 0
        let root = row(segment, state: state, recognize: { recognitions += 1 },
            cancel: { cancellations += 1 }, undo: { undos += 1 })
        let view = try await host(root, height: 250)
        try capture(view, name: "chinese-recognition-saving")
        let completedCaption = try await host(TranscriptCaptionRow(segment: segment, textSize: 18,
            stream: FinalCaptionState()).equatable(), height: 250)
        XCTAssertNotEqual(try png(view), try png(completedCaption), "Saving must remain distinct from completed")
        XCTAssertEqual(CaptionPresentation(segment).primaryText, "中文已经识别，保存中的原文应继续显示。")

        let actions = ChineseRecognitionCaptionMenu(
            presentation: presentation(.saving, canUndo: segment.canUndoChineseRecognition),
            recognize: { recognitions += 1 }, cancel: { cancellations += 1 }, undo: { undos += 1 })
        let menu = try await host(VStack(alignment: .leading, spacing: 12) { actions }.padding(20), height: 200)
        try capture(menu, name: "chinese-recognition-saving-menu")
        XCTAssertFalse(actions.presentation.canRecognize)
        XCTAssertFalse(actions.presentation.canCancel)
        XCTAssertFalse(actions.presentation.canUndo)
        XCTAssertTrue(actions.presentation.showsUndo)
        XCTAssertEqual(actions.presentation.unavailableReason,
                       "正在保存中文识别结果，保存结束后才能重新识别或撤销，暂不可取消。")
        actions.performRecognition()
        actions.performCancellation()
        actions.performUndo()
        root.performCancellation()
        ChineseRecognitionCaptionStatus(presentation: presentation(.saving),
            cancel: { cancellations += 1 }).performCancellation()
        XCTAssertEqual(recognitions, 0)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(undos, 0, "A saving action must be disabled before its handler is reached")

        state.statuses[segment.id] = .completed
        try await settle(view)
        try capture(view, name: "chinese-recognition-saved")
        XCTAssertEqual(try png(view), try png(completedCaption), "Only completed removes the saving notice")
        let completedActions = ChineseRecognitionCaptionMenu(
            presentation: presentation(.completed, canUndo: segment.canUndoChineseRecognition),
            recognize: { recognitions += 1 }, cancel: { cancellations += 1 }, undo: { undos += 1 })
        completedActions.performRecognition()
        completedActions.performUndo()
        completedActions.performCancellation()
        XCTAssertEqual(recognitions, 1, "A new request becomes available after saving completes")
        XCTAssertEqual(undos, 1, "A single undo must dispatch after saving completes")
        XCTAssertEqual(cancellations, 0)

        let savingFailure = ChineseRecognitionStatus.failed(
            "中文原文已保留，但存档或导出尚未保存完成；可以撤销，或重试保存。")
        state.statuses[segment.id] = savingFailure
        try await settle(view)
        try capture(view, name: "chinese-recognition-save-failed")
        let expectedFailure = try await host(expectedRow(segment, status: savingFailure), height: 250)
        XCTAssertEqual(try png(view), try png(expectedFailure), "A saving failure must keep the revised Chinese with its saving notice")
    }

    func testCompletedChineseIsSourceOnlyAndUndoMenuCallsTheInjectedAction() async throws {
        let original = english()
        var segment = original
        segment.applyChineseRecognition("温度升高时，反应速率 increases，但不是任何情况下都成立。")
        let state = ChineseRecognitionPresentationState()
        state.statuses[segment.id] = .completed
        let completed = try await host(row(segment, state: state), height: 200)
        try capture(completed, name: "chinese-recognition-completed")
        let expected = try await host(TranscriptCaptionRow(segment: segment, textSize: 18, stream: FinalCaptionState())
            .equatable(), height: 200)
        XCTAssertEqual(try png(completed), try png(expected), "Completed manual Chinese must have only the original-caption row")
        let originalView = try await host(row(original, state: ChineseRecognitionPresentationState()), height: 200)
        XCTAssertNotEqual(try png(completed), try png(originalView), "The mounted row must visibly replace the original English")
        XCTAssertEqual(CaptionPresentation(segment).languageName, "中文原文")
        XCTAssertTrue(CaptionPresentation(segment).isSourceOnly)

        var undos = 0
        let undoActions = ChineseRecognitionCaptionMenu(presentation: presentation(.completed, canUndo: true),
            recognize: {}, cancel: {}, undo: {
                undos += 1
                XCTAssertTrue(segment.undoChineseRecognition())
            })
        let menu = try await host(VStack(alignment: .leading, spacing: 12) { undoActions }.padding(20), height: 150)
        try capture(menu, name: "chinese-recognition-undo-menu")
        undoActions.performUndo()
        XCTAssertEqual(undos, 1)
        XCTAssertEqual(segment, original)
        XCTAssertEqual(CaptionPresentation(segment), CaptionPresentation(original))
    }

    func testUnhoveredEnglishRowMatchesExistingRenderedPixelsAndHasNoPermanentActions() async throws {
        let segment = english()
        let stream = FinalCaptionState()
        let baseline = try await host(TranscriptCaptionRow(segment: segment, textSize: 18, stream: stream)
            .equatable(), height: 210)
        let state = ChineseRecognitionPresentationState()
        let wrapped = try await host(row(segment, state: state, stream: stream), height: 210)
        XCTAssertEqual(try png(wrapped), try png(baseline), "The English row must retain its exact rendered baseline")
        state.statuses[UUID()] = .recognizing
        try await settle(wrapped)
        XCTAssertEqual(try png(wrapped), try png(baseline), "Another caption's operation must not affect this row")
        XCTAssertTrue(TranscriptCaptionRow(segment: segment, textSize: 18, stream: stream)
            == TranscriptCaptionRow(segment: segment, textSize: 18, stream: stream))
    }

    func testUnopenedMenuDoesNotResolveRecordingDuringCaptionOrStatusUpdates() async throws {
        let segment = english()
        let state = ChineseRecognitionPresentationState()
        var availabilityReads = 0
        let root = ChineseRecognitionCaptionRow(segment: segment, textSize: 18, stream: FinalCaptionState(),
            state: state, availability: {
                availabilityReads += 1
                return .available
            }, recognize: {}, cancel: {}, undo: {})
        let view = try await host(root, height: 230)
        XCTAssertEqual(availabilityReads, 0, "Displaying a caption must not inspect recording headers")
        state.statuses[segment.id] = .recognizing
        try await settle(view)
        XCTAssertEqual(availabilityReads, 0, "Rendering recognition progress must not inspect recording headers")
        state.statuses[UUID()] = .recognizing
        try await settle(view)
        XCTAssertEqual(availabilityReads, 0, "Another caption's status must not inspect recording headers")
    }

    func testResolvingMenuChecksRecordingWhenSharedActionsAppear() async throws {
        var availabilityReads = 0
        let resolution = ChineseRecognitionMenuAvailabilityState()
        let reason = "此句录音已不在本机，无法重新识别。"
        let menu = ChineseRecognitionResolvingMenu(status: nil, canUndo: false, availability: {
            availabilityReads += 1
            return .unavailable(reason)
        }, recognize: { XCTFail("Missing audio must remain disabled") }, cancel: {}, undo: {},
            availabilityState: resolution)
        XCTAssertEqual(availabilityReads, 0, "Constructing the menu must not inspect recording headers")
        let view = try await host(VStack(alignment: .leading, spacing: 12) { menu }.padding(20), height: 170)
        if availabilityReads == 0 {
            print("MENU_APPEARANCE_CALLBACK_UNAVAILABLE: exercising the shared opening event explicitly")
            menu.menuDidAppear()
            try await settle(view)
        }
        try capture(view, name: "chinese-recognition-resolved-menu")
        XCTAssertEqual(availabilityReads, 1, "Appearing menu actions must resolve their actual audio availability")
        XCTAssertFalse(resolution.value.isAvailable)
        XCTAssertEqual(resolution.value.reason, reason)
        let expected = try await host(VStack(alignment: .leading, spacing: 12) {
            ChineseRecognitionCaptionMenu(presentation: presentation(availability: .unavailable(reason)),
                recognize: {}, cancel: {}, undo: {})
        }.padding(20), height: 170)
        XCTAssertEqual(try png(view), try png(expected), "The resolved unavailable state must actually reach the rendered actions")
    }

    func testRecognitionStateKeepsPendingTranslationStreamIsolated() async throws {
        let segment = TranscriptSegment(startTime: 5, endTime: 8, english: "Synthetic pending sentence.")
        let stream = FinalCaptionState()
        stream.loadPresentationForTesting(segmentID: segment.id, text: "尚在生成的译文")
        let state = ChineseRecognitionPresentationState()
        let view = try await host(row(segment, state: state, stream: stream), height: 230)
        let before = try png(view)
        let baseline = SummaryRenderingDiagnostics.counts.streamingRows[segment.id.uuidString, default: 0]
        XCTAssertGreaterThan(baseline, 0)
        state.statuses[UUID()] = .recognizing
        try await settle(view)
        XCTAssertEqual(SummaryRenderingDiagnostics.counts.streamingRows[segment.id.uuidString, default: 0], baseline,
                       "Unrelated manual recognition must not redraw the pending stream")
        stream.loadPresentationForTesting(segmentID: segment.id, text: "已经继续生成的译文")
        try await settle(view)
        try capture(view, name: "chinese-recognition-pending-stream")
        XCTAssertEqual(stream.streamingChinese, "已经继续生成的译文")
        XCTAssertNotEqual(try png(view), before, "The mounted stream must visibly advance to the new payload")
        XCTAssertGreaterThan(SummaryRenderingDiagnostics.counts.streamingRows[segment.id.uuidString, default: 0], baseline)
    }

    private func expectedRow(_ segment: TranscriptSegment, status: ChineseRecognitionStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptCaptionRow(segment: segment, textSize: 18, stream: FinalCaptionState()).equatable()
            ChineseRecognitionCaptionStatus(presentation: presentation(status, canUndo: segment.canUndoChineseRecognition), cancel: {})
                .padding(.leading, 84)
                .padding(.trailing, 16)
                .padding(.bottom, 14)
        }
    }

    private func host<V: View>(_ root: V, height: CGFloat) async throws -> NSView {
        let size = NSSize(width: 760, height: height)
        let controller = NSHostingController(rootView: AnyView(root
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .contain)))
        let view = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        view.frame = NSRect(origin: .zero, size: size)
        addTeardownBlock { @MainActor in window.close() }
        XCTAssertEqual(window.alphaValue, 0)
        // Order the fully transparent, mouse-ignoring test surface without
        // requesting key status or application activation.
        window.orderFront(nil)
        try await settle(view)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isKeyWindow)
        return view
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let window = try XCTUnwrap(view.window)
        XCTAssertEqual(window.alphaValue, 0, "The ordered test surface must remain completely transparent")
        XCTAssertFalse(window.isKeyWindow, "Offscreen presentation tests must never take focus")
    }

    private func png(_ view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func capture(_ view: NSView, name: String) throws {
        let data = try png(view)
        if artifactDirectory == nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChineseRecognitionPresentation-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            artifactDirectory = directory
        }
        try data.write(to: try XCTUnwrap(artifactDirectory).appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Retain the image before assertions so failures still leave visual
        // evidence. A flat/transparent host is never accepted as a screenshot.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var colors = Set<UInt32>()
        var samples = 0
        var opaqueSamples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                if color.alphaComponent > 0.9 { opaqueSamples += 1 }
                let r = UInt32(min(255, max(0, color.redComponent * 255)))
                let g = UInt32(min(255, max(0, color.greenComponent * 255)))
                let b = UInt32(min(255, max(0, color.blueComponent * 255)))
                colors.insert(r << 16 | g << 8 | b)
            }
        }
        XCTAssertGreaterThan(colors.count, 4, "A flat image is not rendered caption evidence: \(name)")
        XCTAssertGreaterThan(opaqueSamples, samples * 4 / 5, "The offscreen view must contain opaque rendered content: \(name)")
    }
}
