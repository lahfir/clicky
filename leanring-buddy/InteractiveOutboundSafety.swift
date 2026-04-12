//
//  InteractiveOutboundSafety.swift
//  leanring-buddy
//
//  Last-line defense for outbound sensitive data in Interactive Mode.
//  This file does NOT validate intent, and it does NOT gate what Claude can do.
//  It only ensures that values matching known credential patterns, or values
//  living inside secure/credential-manager accessibility fields, are stripped
//  before an accessibility snapshot is sent to Claude through the proxy.
//  It also performs a second check at `type`-tool dispatch time: payloads
//  that look like secrets are refused without mutating them.
//

import Foundation

/// Analytics-safe categories for counting what was redacted in a sanitization pass.
/// These raw values are embedded into the `<redacted:...>` placeholders that replace
/// the original sensitive values in the outbound snapshot.
enum InteractiveRedactionCategory: String {
    case secureTextField = "secure-field"
    case credentialManagerApp = "credential-manager"
    case secretPattern = "secret-pattern"
    case highEntropyToken = "high-entropy-token"
}

/// The result of sanitizing a single accessibility snapshot.
struct InteractiveRedactionSummary {
    let sanitizedJSONString: String
    let categoryToCount: [InteractiveRedactionCategory: Int]

    var totalRedactions: Int { categoryToCount.values.reduce(0, +) }
    var hasRedactions: Bool { totalRedactions > 0 }
}

/// Errors thrown while sanitizing an accessibility snapshot.
enum InteractiveOutboundSafetyError: Error {
    case snapshotParseFailed(underlying: Error)
    case snapshotReserializeFailed(underlying: Error)
}

/// Stateless namespace for outbound redaction logic.
/// Declared as an `enum` with only static members so it cannot be instantiated.
/// This matches the existing Clicky pattern used by `CompanionScreenCaptureUtility`.
enum InteractiveOutboundSafety {

    // MARK: - Pattern set

    /// The full set of secret regexes that the outbound safety layer recognizes.
    ///
    /// Notes on escaping in Swift string literals for `NSRegularExpression`:
    ///   - `\b` in a pattern is written as `\\b` in the Swift source literal.
    ///   - A literal hyphen inside a character class is placed at the end (`_-`)
    ///     so it doesn't get interpreted as a range delimiter.
    ///   - The PEM header pattern does not use `\\b` because `-----` is not a
    ///     word-boundary context; we match the literal ASCII marker instead.
    static let secretPatterns: [(category: InteractiveRedactionCategory, regex: NSRegularExpression)] = {
        let rawPatterns: [(InteractiveRedactionCategory, String)] = [
            // OpenAI-style secret key (e.g. "sk-abcd...20+ chars")
            (.secretPattern, "\\bsk-[A-Za-z0-9]{20,}\\b"),
            // Stripe restricted key (underscore variant)
            (.secretPattern, "\\bsk_[A-Za-z0-9]{20,}\\b"),
            // Stripe restricted live key
            (.secretPattern, "\\brk_live_[A-Za-z0-9]{20,}\\b"),
            // GitHub personal access token
            (.secretPattern, "\\bghp_[A-Za-z0-9]{20,}\\b"),
            // GitHub OAuth token
            (.secretPattern, "\\bgho_[A-Za-z0-9]{20,}\\b"),
            // AWS access key ID (fixed prefix + exactly 16 uppercase/digits)
            (.secretPattern, "\\bAKIA[0-9A-Z]{16}\\b"),
            // Google API key (fixed prefix + exactly 35 chars from a specific class)
            (.secretPattern, "\\bAIza[0-9A-Za-z_-]{35}\\b"),
            // PEM private key header (BEGIN ... PRIVATE KEY)
            (.secretPattern, "-----BEGIN [A-Z ]+ PRIVATE KEY-----"),
            // JWT: three base64url-ish segments separated by dots
            (.highEntropyToken, "\\b[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"),
        ]

        return rawPatterns.map { rawPattern in
            // `try!` here is acceptable because all regexes above are hardcoded
            // constants verified at compile time; a failure would be a programmer
            // error caught on the first launch.
            let compiledRegex = try! NSRegularExpression(
                pattern: rawPattern.1,
                options: []
            )
            return (category: rawPattern.0, regex: compiledRegex)
        }
    }()

    /// Bundle identifiers of credential-manager apps. When the Interactive Mode
    /// snapshot's root app is one of these, EVERY string value in the tree is
    /// redacted — we treat the entire surface as sensitive because these apps
    /// routinely render passwords, recovery codes, and private keys inline.
    static let credentialManagerBundleIDs: Set<String> = [
        "com.1password.1password7",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "org.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.dashlanephone",
    ]

    // MARK: - Secret detection (non-mutating)

    /// Returns the matching redaction category if the given text contains ANY
    /// known secret pattern. Returns `nil` if the text appears clean.
    ///
    /// This method does NOT mutate or redact the text. It is used by the
    /// `type`-tool dispatch layer to refuse payloads that look like secrets,
    /// without rewriting what the model asked to type.
    static func containsSecret(_ text: String) -> InteractiveRedactionCategory? {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for patternEntry in secretPatterns {
            if patternEntry.regex.firstMatch(in: text, options: [], range: searchRange) != nil {
                return patternEntry.category
            }
        }
        return nil
    }

    /// Non-destructive helper: if the text looks like a secret, return a
    /// `<redacted:category>` placeholder and the matched category. Otherwise
    /// return the original text unchanged and `nil`. Used when sanitizing raw
    /// log output where we want a single summary replacement instead of
    /// per-match substitution.
    static func redactTextIfSecret(_ text: String) -> (redacted: String, category: InteractiveRedactionCategory?) {
        if let matchedCategory = containsSecret(text) {
            return ("<redacted:\(matchedCategory.rawValue)>", matchedCategory)
        }
        return (text, nil)
    }

    // MARK: - Snapshot sanitization

    /// Sanitizes a raw JSON snapshot from `agent-desktop snapshot` in-place at
    /// the Swift object level, then reserializes it to a string.
    ///
    /// - Parameters:
    ///   - rawJSONData: The bytes produced by `agent-desktop snapshot`.
    ///   - rootBundleID: The bundle identifier of the frontmost app the
    ///     snapshot belongs to. When this is a known credential-manager app,
    ///     every string value in the tree is replaced with a credential-manager
    ///     placeholder regardless of pattern matching.
    /// - Returns: An `InteractiveRedactionSummary` containing the sanitized JSON
    ///   string and per-category redaction counts.
    /// - Throws: `InteractiveOutboundSafetyError.snapshotParseFailed` if the raw
    ///   data is not parseable JSON; `InteractiveOutboundSafetyError.snapshotReserializeFailed`
    ///   if the mutated tree cannot be reserialized.
    static func sanitizeSnapshotJSON(_ rawJSONData: Data, rootBundleID: String?) throws -> InteractiveRedactionSummary {
        // Step 1: parse the raw snapshot JSON into a Swift `Any` tree.
        let parsedRootObject: Any
        do {
            parsedRootObject = try JSONSerialization.jsonObject(
                with: rawJSONData,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw InteractiveOutboundSafetyError.snapshotParseFailed(underlying: error)
        }

        // Step 2: mutable category counter shared across the recursive walk.
        var mutableCategoryToCount: [InteractiveRedactionCategory: Int] = [:]

        // Step 3: determine whether the entire snapshot belongs to a known
        // credential-manager app, in which case every string value is sensitive.
        let snapshotBelongsToCredentialManager: Bool
        if let resolvedRootBundleID = rootBundleID {
            snapshotBelongsToCredentialManager = credentialManagerBundleIDs.contains(resolvedRootBundleID)
        } else {
            snapshotBelongsToCredentialManager = false
        }

        // Step 4: recursively walk and transform the parsed tree.
        let sanitizedRootObject = sanitizeAccessibilityNode(
            inputNode: parsedRootObject,
            snapshotBelongsToCredentialManager: snapshotBelongsToCredentialManager,
            mutableCategoryToCount: &mutableCategoryToCount
        )

        // Step 5: reserialize the sanitized tree back to JSON text.
        let sanitizedJSONData: Data
        do {
            sanitizedJSONData = try JSONSerialization.data(
                withJSONObject: sanitizedRootObject,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw InteractiveOutboundSafetyError.snapshotReserializeFailed(underlying: error)
        }

        let sanitizedJSONString = String(data: sanitizedJSONData, encoding: .utf8) ?? ""

        return InteractiveRedactionSummary(
            sanitizedJSONString: sanitizedJSONString,
            categoryToCount: mutableCategoryToCount
        )
    }

    /// Recursive sanitization helper. Returns a new `Any` value representing the
    /// sanitized subtree. A pure transform (rather than in-place `NSMutableDictionary`
    /// mutation) is used because:
    ///   1. `JSONSerialization.jsonObject(with:options:)` returns immutable Swift
    ///      collections by default, so a pure transform avoids extra allocator
    ///      dances with `.mutableContainers`.
    ///   2. The transform is easier to reason about — the caller can trust that
    ///      the returned value is the fully sanitized subtree, with no aliasing
    ///      back to the original parsed tree.
    private static func sanitizeAccessibilityNode(
        inputNode: Any,
        snapshotBelongsToCredentialManager: Bool,
        mutableCategoryToCount: inout [InteractiveRedactionCategory: Int]
    ) -> Any {
        // Dictionary case: an accessibility element node.
        if let inputDictionary = inputNode as? [String: Any] {
            var sanitizedDictionary: [String: Any] = [:]

            // Determine whether this node is a secure text field. Secure text
            // fields always have their `value` replaced regardless of content.
            let nodeRoleValue = inputDictionary["role"] as? String
            let nodeIsSecureTextField = (nodeRoleValue == "AXSecureTextField")

            for (childKey, childValue) in inputDictionary {
                if childKey == "value", let stringValue = childValue as? String {
                    // Priority 1: credential-manager-wide redaction.
                    if snapshotBelongsToCredentialManager {
                        sanitizedDictionary[childKey] = "<redacted:\(InteractiveRedactionCategory.credentialManagerApp.rawValue)>"
                        incrementCount(
                            forCategory: .credentialManagerApp,
                            inCounter: &mutableCategoryToCount
                        )
                        continue
                    }

                    // Priority 2: secure text field redaction.
                    if nodeIsSecureTextField {
                        sanitizedDictionary[childKey] = "<redacted:\(InteractiveRedactionCategory.secureTextField.rawValue)>"
                        incrementCount(
                            forCategory: .secureTextField,
                            inCounter: &mutableCategoryToCount
                        )
                        continue
                    }

                    // Priority 3: per-value secret pattern detection.
                    if let matchedCategory = containsSecret(stringValue) {
                        sanitizedDictionary[childKey] = "<redacted:\(matchedCategory.rawValue)>"
                        incrementCount(
                            forCategory: matchedCategory,
                            inCounter: &mutableCategoryToCount
                        )
                        continue
                    }

                    // Clean value: leave as-is.
                    sanitizedDictionary[childKey] = stringValue
                } else {
                    // Recurse into all non-`value` child entries so nested
                    // element trees also get sanitized.
                    sanitizedDictionary[childKey] = sanitizeAccessibilityNode(
                        inputNode: childValue,
                        snapshotBelongsToCredentialManager: snapshotBelongsToCredentialManager,
                        mutableCategoryToCount: &mutableCategoryToCount
                    )
                }
            }

            return sanitizedDictionary
        }

        // Array case: walk every element.
        if let inputArray = inputNode as? [Any] {
            var sanitizedArray: [Any] = []
            sanitizedArray.reserveCapacity(inputArray.count)
            for arrayElement in inputArray {
                let sanitizedElement = sanitizeAccessibilityNode(
                    inputNode: arrayElement,
                    snapshotBelongsToCredentialManager: snapshotBelongsToCredentialManager,
                    mutableCategoryToCount: &mutableCategoryToCount
                )
                sanitizedArray.append(sanitizedElement)
            }
            return sanitizedArray
        }

        // Leaf case: strings, numbers, bools, null. No transformation here;
        // string-level redaction is performed at the dictionary level so we
        // only touch values that live under a `value` key. Arbitrary loose
        // strings elsewhere in the tree are intentionally not scanned to avoid
        // mangling role names, identifiers, and other structural metadata.
        return inputNode
    }

    /// Increments the redaction count for a single category in the mutable counter.
    private static func incrementCount(
        forCategory redactionCategory: InteractiveRedactionCategory,
        inCounter mutableCategoryToCount: inout [InteractiveRedactionCategory: Int]
    ) {
        mutableCategoryToCount[redactionCategory, default: 0] += 1
    }

    // MARK: - Log sanitization

    /// Replaces every secret-pattern match inside `text` with the literal
    /// placeholder `<redacted>`, returning the cleaned string and the list of
    /// categories that were matched (in match order, with duplicates preserved
    /// so callers can count how many hits of each category appeared).
    ///
    /// This is used to sanitize non-JSON stdout/stderr coming from
    /// `AgentDesktopRunner` before it is written to any log sink.
    static func redactSecrets(_ text: String) -> (redacted: String, matchedCategories: [InteractiveRedactionCategory]) {
        var workingText = text
        var matchedCategoriesInOrder: [InteractiveRedactionCategory] = []

        for patternEntry in secretPatterns {
            // Re-scan each pattern against the current working text. We collect
            // all matches first, then apply replacements from the end so that
            // earlier match ranges remain valid.
            let searchRange = NSRange(workingText.startIndex..<workingText.endIndex, in: workingText)
            let allMatchesForPattern = patternEntry.regex.matches(
                in: workingText,
                options: [],
                range: searchRange
            )

            guard !allMatchesForPattern.isEmpty else { continue }

            // Record one category entry per match so callers can count.
            for _ in allMatchesForPattern {
                matchedCategoriesInOrder.append(patternEntry.category)
            }

            // Apply replacements from the last match to the first so the
            // earlier `NSRange` values remain valid as we mutate the string.
            for matchResult in allMatchesForPattern.reversed() {
                if let swiftRangeForMatch = Range(matchResult.range, in: workingText) {
                    workingText.replaceSubrange(swiftRangeForMatch, with: "<redacted>")
                }
            }
        }

        return (redacted: workingText, matchedCategories: matchedCategoriesInOrder)
    }
}
