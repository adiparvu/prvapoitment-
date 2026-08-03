import Foundation

/// Shared remote-image infrastructure for the platform.
///
/// PRV is a media-heavy catalogue: salon heroes, treatment galleries,
/// professional portfolios, and avatars are re-shown constantly as people
/// move between Discover, profiles, chat, and CRM — and the same salon hero
/// is fetched again on every visit. `AsyncImage` honors standard HTTP
/// caching, so pairing it with a generously sized private `URLCache` means a
/// second look at a salon renders from memory or disk instead of the network.
///
/// The cache is private to imagery, so a flood of gallery bytes can never
/// evict API responses (and vice versa).
///
/// ```swift
/// AsyncImage(request: URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)) { phase in
///     …
/// }
/// .asyncImageURLSession(PRVImageStore.imageSession)
/// ```
///
/// ``PRVAsyncImage`` and ``PRVAvatar`` already load through it, so most
/// feature code gets the cache for free.
public enum PRVImageStore {
    /// In-memory budget: roughly a screenful of hero imagery plus the avatars
    /// around it, kept ready so scrolling back never re-decodes.
    private static let memoryCapacity = 64 * 1024 * 1024

    /// On-disk budget: a full browsing session of galleries and portfolios,
    /// surviving app launches so returning users open to instant imagery.
    private static let diskCapacity = 512 * 1024 * 1024

    /// The `URLSession` every PRV remote image loads through.
    ///
    /// Its cache policy is `.returnCacheDataElseLoad`, matching the
    /// platform's offline-first stance: cached bytes render immediately and
    /// the network is only touched when there is nothing to show.
    public static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            directory: cacheDirectory
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// Empties the image cache.
    ///
    /// Call this on sign-out and GDPR erase: cached client photos, portfolios,
    /// and gallery imagery must never survive into the next account on a
    /// shared device.
    public static func clearCache() {
        imageSession.configuration.urlCache?.removeAllCachedResponses()
    }

    /// Dedicated on-disk location so image bytes stay separate from the
    /// shared URL cache. `nil` falls back to the system default location.
    private static var cacheDirectory: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "PRVImageCache", directoryHint: .isDirectory)
    }
}
