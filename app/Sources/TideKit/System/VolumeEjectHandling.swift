import Foundation

/// Backends that hold files open on external drives implement this so a drive can eject cleanly:
/// called synchronously from NSWorkspace.willUnmountNotification.
public protocol VolumeEjectHandling: AnyObject {
    func volumeWillUnmount(_ mountPath: String)
}
