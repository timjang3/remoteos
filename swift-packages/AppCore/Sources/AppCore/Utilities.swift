import CoreGraphics
import Foundation
import RemoteOSCore

public typealias AppCoreError = RemoteOSCore.AppCoreError

public func isoNow() -> String {
    RemoteOSCore.isoNow()
}

func anyDictionary(from data: Data) throws -> [String: Any] {
    try RemoteOSCore.anyDictionary(from: data)
}

func dataFromJSONObject(_ object: Any) throws -> Data {
    try RemoteOSCore.dataFromJSONObject(object)
}

func stringDictionary(_ value: Any?) -> [String: Any] {
    RemoteOSCore.stringDictionary(value)
}
