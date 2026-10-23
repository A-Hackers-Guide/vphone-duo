import Foundation

extension GuestAPI {
    static func executeHomePodDisplay(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard method == "homepod.display.state" else { return nil }
        return try GuestHomePodDisplay.state()
    }
}
