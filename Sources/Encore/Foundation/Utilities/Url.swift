import Foundation

internal func safeURL(_ raw: String, context: String? = nil) -> URL {
    if let url = URL(string: raw) {
        return url
    }
    if let context = context {
        Logger.warn("Url: Invalid URL '\(raw)' (\(context)); falling back to '/'")
    } else {
        Logger.warn("Url: Invalid URL '\(raw)'; falling back to '/'")
    }
    return URL(fileURLWithPath: "/")
}