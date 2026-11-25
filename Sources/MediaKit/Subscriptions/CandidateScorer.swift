import Foundation
import PluginKit

/// Pure candidate validation and ranking (`SUB-11`).
public enum CandidateScorer {
    public struct Decision: Equatable, Sendable {
        public var accepted: Bool
        public var rejectionReason: String?
        public var formatBucket: String
    }

    /// Forbidden upload/derivative qualifiers rejected unless already present in the reference track's title/album.
    private static let forbiddenKeywords: [String] = [
        "nightcore",
        "slowed",
        "reverb",
        "8d",
        "karaoke",
        "instrumental",
        "tribute",
        "cover",
        "sped up",
        "bass boosted",
        "live",
        "remix",
        "mashup",
    ]

    private static let losslessContainers: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"]

    /// Ranks acceptable candidates best-first according to `policy` and `resolverOrder`.
    /// Candidates that violate rejection rules (`unavailable`, duration mismatch, forbidden noise words,
    /// missing significant title words, lossy bitrate below minimum, excluded format) are omitted.
    public static func rank(
        candidates: [Candidate],
        for ref: TrackRef,
        policy: QualityPolicy,
        resolverOrder: [String]
    ) -> [Candidate] {
        let resolverRank: [String: Int] = Dictionary(
            resolverOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let formatRank: [String: Int] = Dictionary(
            policy.preferredFormats.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let refNormalizedTitle = TrackTextNormalizer.normalizeTitle(ref.title)
        let refArtists = Set(ref.artists.flatMap { TrackTextNormalizer.artistComponents($0) })
        let refIsVideo = TrackTextNormalizer.hasVideoVersionQualifier(title: ref.title, album: ref.album)

        let scored: [(candidate: Candidate, tuple: ScoreTuple)] = candidates.compactMap { candidate in
            let decision = evaluate(candidate, against: ref, policy: policy)
            guard decision.accepted else { return nil }

            let tierRank = formatRank[decision.formatBucket]
                ?? formatRank["other"]
                ?? (policy.preferredFormats.count + 1)
            let availabilityRank = (candidate.availability?.freeSlot == true) ? 0 : 1
            let resRank = resolverRank[candidate.resolver] ?? (resolverOrder.count + 1)
            let videoRank: Int
            if refIsVideo {
                let isTopicArtist = (candidate.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .hasSuffix("- topic")
                let candHasVideoMarker = TrackTextNormalizer.hasVideoVersionQualifier(
                    title: candidate.title ?? candidate.displayName,
                    album: candidate.album
                )
                if candidate.resolver == "yt-dlp" && !isTopicArtist {
                    videoRank = candHasVideoMarker ? 0 : 1
                } else if !isTopicArtist && candHasVideoMarker {
                    videoRank = 1
                } else {
                    videoRank = 2
                }
            } else {
                videoRank = 0
            }

            let candTitle = TrackTextNormalizer.normalizeTitle(candidate.title ?? candidate.displayName)
            let titleExact = !refNormalizedTitle.isEmpty && candTitle == refNormalizedTitle ? 0 : 1
            let candArtists = Set((candidate.artist.map { TrackTextNormalizer.artistComponents($0) }) ?? [])
            let artistExact = !refArtists.isEmpty && !refArtists.isDisjoint(with: candArtists) ? 0 : 1

            let durationDelta: Int
            if let rMs = ref.durationMs, rMs > 0,
               let cMs = candidate.durationMs, cMs > 0 {
                durationDelta = abs(rMs - cMs)
            } else {
                durationDelta = Int.max
            }

            let tuple = ScoreTuple(
                videoPreferenceRank: videoRank,
                formatTierRank: tierRank,
                availabilityRank: availabilityRank,
                bitrateDescending: -(candidate.bitrateKbps ?? (isLossless(candidate) ? 1411 : 0)),
                resolverRank: resRank,
                exactTitleArtistRank: titleExact + artistExact,
                durationDeltaMs: durationDelta
            )
            return (candidate, tuple)
        }

        return scored.sorted { $0.tuple < $1.tuple }.map(\.candidate)
    }

    public static func evaluate(
        _ candidate: Candidate,
        against ref: TrackRef,
        policy: QualityPolicy
    ) -> Decision {
        let bucket = formatBucket(for: candidate)

        let isYouTube = candidate.resolver == "yt-dlp"
        if isYouTube && !policy.acceptYouTubeFallback {
            return Decision(accepted: false, rejectionReason: "youtube fallback disabled", formatBucket: bucket)
        }

        // Format filter: known buckets explicitly omitted from preferredFormats are rejected.
        let knownStandardBuckets: Set<String> = ["flac", "alac", "mp3-320", "aac-256", "mp3-v0"]
        if knownStandardBuckets.contains(bucket) && !policy.preferredFormats.contains(bucket) {
            return Decision(accepted: false, rejectionReason: "format '\(bucket)' excluded", formatBucket: bucket)
        }
        if bucket == "other" && !policy.preferredFormats.contains("other") {
            return Decision(accepted: false, rejectionReason: "format 'other' excluded", formatBucket: bucket)
        }

        // Lossy bitrate threshold (YouTube fallback caps at ~128–160 kbps, so exempt when explicitly enabled).
        if !isYouTube && !isLossless(candidate), let kbps = candidate.bitrateKbps, kbps > 0, kbps < policy.minimumBitrateKbps {
            return Decision(accepted: false, rejectionReason: "bitrate \(kbps) < \(policy.minimumBitrateKbps)", formatBucket: bucket)
        }

        // Duration tolerance (±3 s, ±5 s for yt-dlp).
        let toleranceMs = isYouTube ? 5000 : 3000
        if let refMs = ref.durationMs, refMs > 0, let candMs = candidate.durationMs, candMs > 0 {
            if abs(refMs - candMs) > toleranceMs {
                return Decision(accepted: false, rejectionReason: "duration mismatch", formatBucket: bucket)
            }
        }

        // Forbidden noise qualifiers unless present in the reference title/album.
        let refText = TrackTextNormalizer.foldAndLowercase(ref.title + " " + (ref.album ?? ""))
        let refWords = Set(TrackTextNormalizer.rawWords(in: refText))
        let candRaw = [candidate.title, candidate.displayName, candidate.album]
            .compactMap { $0 }
            .joined(separator: " ")
        let candFolded = TrackTextNormalizer.collapseWhitespaceAndPunctuation(
            TrackTextNormalizer.foldAndLowercase(candRaw)
        )
        let candWordList = candFolded.split(separator: " ").map(String.init)
        let candWords = Set(candWordList)

        for keyword in forbiddenKeywords {
            let refHas: Bool
            let candHas: Bool
            if keyword.contains(" ") {
                let normRef = TrackTextNormalizer.collapseWhitespaceAndPunctuation(refText)
                refHas = containsPhrase(keyword, in: normRef)
                candHas = containsPhrase(keyword, in: candFolded)
            } else {
                refHas = refWords.contains(keyword)
                candHas = candWords.contains(keyword)
            }
            if candHas && !refHas {
                return Decision(accepted: false, rejectionReason: "forbidden qualifier '\(keyword)'", formatBucket: bucket)
            }
        }

        // Every significant word (>= 3 chars excluding "the", "and") of reference title must appear in candidate.
        let requiredWords = TrackTextNormalizer.significantWords(in: ref.title)
        if !requiredWords.isEmpty {
            let searchCorpus = TrackTextNormalizer.collapseWhitespaceAndPunctuation(
                TrackTextNormalizer.foldAndLowercase(
                    [candidate.title, candidate.displayName].compactMap { $0 }.joined(separator: " ")
                )
            )
            let corpusWords = Set(searchCorpus.split(separator: " ").map(String.init))
            for word in requiredWords where !corpusWords.contains(word) {
                return Decision(accepted: false, rejectionReason: "missing word '\(word)'", formatBucket: bucket)
            }
        }

        return Decision(accepted: true, rejectionReason: nil, formatBucket: bucket)
    }

    public static func formatBucket(for candidate: Candidate) -> String {
        formatBucket(
            container: candidate.container,
            codec: candidate.codec,
            bitrateKbps: candidate.bitrateKbps,
            displayName: candidate.displayName,
            isLosslessHint: isLossless(candidate)
        )
    }

    /// Classifies an existing local track's format into the same buckets as `QualityPolicy.preferredFormats`.
    public static func formatBucket(
        container rawContainer: String,
        codec rawCodec: String? = nil,
        bitrateKbps: Int?,
        displayName: String = "",
        isLosslessHint: Bool = false
    ) -> String {
        let container = rawContainer.lowercased()
        let codec = (rawCodec ?? "").lowercased()
        let kbps = bitrateKbps ?? 0

        if isLosslessHint || losslessContainers.contains(container) || losslessContainers.contains(codec) {
            if container == "alac" || codec == "alac" { return "alac" }
            if container == "flac" || codec == "flac" { return "flac" }
            return "flac"
        }
        if container == "mp3" || codec == "mp3" {
            if kbps >= 300 { return "mp3-320" }
            if kbps >= 210 && kbps <= 265 { return "mp3-v0" }
            if displayName.lowercased().contains("v0") { return "mp3-v0" }
            if displayName.lowercased().contains("320") { return "mp3-320" }
            return kbps > 0 ? "other" : "mp3-320"
        }
        if container == "m4a" || container == "aac" || codec == "aac" {
            if kbps >= 240 { return "aac-256" }
            return kbps == 0 ? "aac-256" : "other"
        }
        return "other"
    }

    public static func tierRank(for bucket: String, policy: QualityPolicy) -> Int {
        policy.preferredFormats.firstIndex(of: bucket)
            ?? policy.preferredFormats.firstIndex(of: "other")
            ?? (policy.preferredFormats.count + 1)
    }

    /// True if an already-downloaded local file is below the policy's top achievable tier
    /// (for instance a YouTube fallback or lossy file when lossless is preferred).
    public static func canSeekUpgrade(
        localExtension: String,
        localBitrateKbps: Int,
        localIsLossless: Bool,
        wasYouTubeFallback: Bool,
        policy: QualityPolicy,
        hasNonYouTubeResolvers: Bool
    ) -> Bool {
        if wasYouTubeFallback && hasNonYouTubeResolvers {
            return true
        }
        guard hasNonYouTubeResolvers else { return false }
        let currentBucket = formatBucket(
            container: localExtension,
            bitrateKbps: localBitrateKbps,
            isLosslessHint: localIsLossless
        )
        return tierRank(for: currentBucket, policy: policy) > 0 && !localIsLossless
    }

    /// Returns `true` only when `candidate` offers a strictly better format/source than the existing local track.
    public static func isStrictlyBetterUpgrade(
        candidate: Candidate,
        thanLocalExtension localExtension: String,
        localBitrateKbps: Int,
        localIsLossless: Bool,
        wasYouTubeFallback: Bool,
        policy: QualityPolicy
    ) -> Bool {
        let currentBucket = formatBucket(
            container: localExtension,
            bitrateKbps: localBitrateKbps,
            isLosslessHint: localIsLossless
        )
        let currentRank = tierRank(for: currentBucket, policy: policy)
        let candBucket = formatBucket(for: candidate)
        let candRank = tierRank(for: candBucket, policy: policy)
        let candIsLossless = isLossless(candidate)

        if localIsLossless && !candIsLossless {
            return false
        }
        if candidate.resolver == "yt-dlp" && !wasYouTubeFallback {
            return false
        }
        if wasYouTubeFallback && candidate.resolver != "yt-dlp" {
            return candRank <= currentRank || candIsLossless
        }
        if candRank < currentRank {
            return true
        }
        if candRank == currentRank && !localIsLossless && candIsLossless {
            return true
        }
        if candRank == currentRank && !candIsLossless && !localIsLossless,
           let candKbps = candidate.bitrateKbps, localBitrateKbps > 0 {
            return candKbps >= localBitrateKbps + 64
        }
        return false
    }

    private static func isLossless(_ candidate: Candidate) -> Bool {
        let c = candidate.container.lowercased()
        let k = (candidate.codec ?? "").lowercased()
        return losslessContainers.contains(c) || losslessContainers.contains(k)
    }

    private static func containsPhrase(_ phrase: String, in haystack: String) -> Bool {
        let paddedHaystack = " " + haystack + " "
        let paddedPhrase = " " + phrase + " "
        return paddedHaystack.contains(paddedPhrase)
    }

    private struct ScoreTuple: Comparable {
        var videoPreferenceRank: Int
        var formatTierRank: Int
        var availabilityRank: Int
        var bitrateDescending: Int
        var resolverRank: Int
        var exactTitleArtistRank: Int
        var durationDeltaMs: Int

        static func < (lhs: ScoreTuple, rhs: ScoreTuple) -> Bool {
            if lhs.videoPreferenceRank != rhs.videoPreferenceRank { return lhs.videoPreferenceRank < rhs.videoPreferenceRank }
            if lhs.formatTierRank != rhs.formatTierRank { return lhs.formatTierRank < rhs.formatTierRank }
            if lhs.availabilityRank != rhs.availabilityRank { return lhs.availabilityRank < rhs.availabilityRank }
            if lhs.bitrateDescending != rhs.bitrateDescending { return lhs.bitrateDescending < rhs.bitrateDescending }
            if lhs.resolverRank != rhs.resolverRank { return lhs.resolverRank < rhs.resolverRank }
            if lhs.exactTitleArtistRank != rhs.exactTitleArtistRank { return lhs.exactTitleArtistRank < rhs.exactTitleArtistRank }
            return lhs.durationDeltaMs < rhs.durationDeltaMs
        }
    }
}
