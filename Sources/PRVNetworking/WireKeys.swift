import Foundation

// MARK: - Any coding key

/// A coding key that carries whatever string a key strategy produces.
///
/// The `.custom` key strategies on `JSONEncoder`/`JSONDecoder` must hand back a
/// `CodingKey`; this is the minimal box that transports a converted key name.
public struct PRVAnyCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Key case conversion

/// camelCase ↔︎ snake_case conversion that is a genuine **inverse pair**.
///
/// Foundation ships `.convertToSnakeCase` / `.convertFromSnakeCase`, but the two are
/// famously *not* inverses: `salonID → salon_id → salonId`, and in the other direction
/// `galleryURLs → gallery_ur_ls`. Every PRV model has `...ID` / `...URL`-suffixed
/// properties and the Supabase schema serves exactly the matching `salon_id`,
/// `additional_client_ids`, `gallery_urls` columns, so Foundation's pair can neither
/// decode a PostgREST row (non-optional keys throw `keyNotFound`, optional ones
/// silently decode as `nil`) nor encode one the backend recognises.
///
/// ``JSONCoding`` therefore drives both wire coders with this matched pair, built
/// around a small acronym registry.
public enum PRVKeyCase {
    /// Words that are rendered fully uppercase when converting back to camelCase.
    /// Plural forms are derived (`id → ID`, `ids → IDs`), so only the singular is
    /// listed. This is the project's acronym registry — extend it when a model
    /// introduces a new one.
    public static let acronyms: Set<String> = ["id", "url"]

    /// `"heroImageURL" → "hero_image_url"`.
    ///
    /// An underscore is inserted before an uppercase character only when the previous
    /// character is lowercase (or a digit), so runs of capitals stay together and
    /// synthesized enum payload keys such as `_0` pass through untouched.
    public static func toSnakeCase(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var result = ""
        result.reserveCapacity(key.count + 4)
        var previous: Character?

        for character in key {
            if character.isUppercase {
                if let previous, previous != "_", !previous.isUppercase {
                    result.append("_")
                }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    /// `"hero_image_url" → "heroImageURL"`. Leading and trailing underscores survive.
    public static func toCamelCase(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        let characters = Array(key)

        var leading = 0
        while leading < characters.count, characters[leading] == "_" { leading += 1 }
        guard leading < characters.count else { return key }

        var trailing = 0
        while trailing < characters.count - leading,
              characters[characters.count - 1 - trailing] == "_" {
            trailing += 1
        }

        let core = String(characters[leading ..< (characters.count - trailing)])
        let components = core.split(separator: "_")
        guard let first = components.first else { return key }

        var body = String(first)
        for component in components.dropFirst() {
            body += displayForm(of: String(component))
        }
        return String(repeating: "_", count: leading) + body + String(repeating: "_", count: trailing)
    }

    private static func displayForm(of component: String) -> String {
        let lowered = component.lowercased()
        if acronyms.contains(lowered) {
            return lowered.uppercased()
        }
        if lowered.hasSuffix("s"), acronyms.contains(String(lowered.dropLast())) {
            return String(lowered.dropLast()).uppercased() + "s"
        }
        return lowered.prefix(1).uppercased() + String(lowered.dropFirst())
    }
}
