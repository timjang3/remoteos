import CoreGraphics
import Foundation

public final class DisplayTopologyObserver: @unchecked Sendable {
    private static let callback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else {
            return
        }
        let observer = Unmanaged<DisplayTopologyObserver>.fromOpaque(userInfo).takeUnretainedValue()
        observer.onChange?()
    }

    private let onChange: (@Sendable () -> Void)?

    public init(onChange: (@Sendable () -> Void)?) {
        self.onChange = onChange
        CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }
}
