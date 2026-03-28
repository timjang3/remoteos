import Testing
@testable import AppCore

private actor ShareableContentCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@Test func listWindowsSkipsShareableContentUntilScreenRecordingIsGranted() async {
    let counter = ShareableContentCallCounter()
    let service = WindowInventoryService(
        permissionSnapshotProvider: {
            PermissionSnapshot(screenRecording: .needsPrompt, accessibility: .needsPrompt)
        },
        shareableContentProvider: {
            await counter.increment()
            throw AppCoreError.invalidResponse
        }
    )

    let windows = await service.listWindows()

    #expect(windows.isEmpty)
    #expect(await counter.value() == 0)
}

@Test func listWindowsQueriesShareableContentAfterScreenRecordingIsGranted() async {
    let counter = ShareableContentCallCounter()
    let service = WindowInventoryService(
        permissionSnapshotProvider: {
            PermissionSnapshot(screenRecording: .granted, accessibility: .needsPrompt)
        },
        shareableContentProvider: {
            await counter.increment()
            throw AppCoreError.invalidResponse
        }
    )

    let windows = await service.listWindows()

    #expect(windows.isEmpty)
    #expect(await counter.value() == 1)
}
