import Foundation

// Minimal stand-in for the app type so ZModemEngine can be exercised headlessly.
struct ZModemProgress: Equatable {
    enum Direction { case receive, send }
    var direction: Direction
    var fileName: String
    var transferred: Int64
    var total: Int64
    var message: String
    var isFinished: Bool
    var isError: Bool
    var savedPath: String? = nil
}
