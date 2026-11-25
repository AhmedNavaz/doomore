// Prints "on" if any camera on this Mac is switched on right now by any app, else "off".
// It reads a system status flag only. It never opens a camera and needs no permission.
// Used by scripts/selftest.sh as a stand-in for looking at the camera light.
import CoreMediaIO
import Foundation

func property(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func deviceIDs() -> [CMIOObjectID] {
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var address = property(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
    return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
}

func isRunning(_ id: CMIOObjectID) -> Bool {
    var address = property(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
    return status == 0 && value != 0
}

func name(_ id: CMIOObjectID) -> String {
    var address = property(kCMIOObjectPropertyName)
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
    guard status == 0, let value else { return "camera \(id)" }
    return value.takeRetainedValue() as String
}

let ids = deviceIDs()
guard !ids.isEmpty else {
    print("unknown (no cameras listed)")
    exit(0)
}
let running = ids.filter(isRunning).map(name)
print(running.isEmpty ? "off" : "on (\(running.joined(separator: ", ")))")
