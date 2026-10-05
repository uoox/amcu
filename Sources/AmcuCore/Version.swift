import Foundation

/// The single place the version lives; the CLI, the native host and the
/// extension handshake all read it from here.
public enum AmcuVersion {
    public static let string = "0.10.0"
}
