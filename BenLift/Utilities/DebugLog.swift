import Foundation

/// Console logging that compiles away in a release build.
///
/// The resolver explains every decision it makes and HealthKit reports every
/// fetch — invaluable while building, pure noise in something installed on
/// someone else's phone. `print` has a runtime cost even when nobody is
/// reading it, so this removes the call entirely rather than silencing it.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
