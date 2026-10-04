import Foundation
import Vision
import CoreImage
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Computes and stores Vision feature prints for photos and groups them
/// into "similar" and "exact duplicate" clusters.
///
/// The indexer is deliberately decoupled from any photo-library framework:
/// callers decode images (PhotoKit, file URLs, ...) and hand over
/// `CGImage`s; grouping operates on opaque string identifiers plus
/// optional creation dates.
public actor FeaturePrintIndexer {
    /// Bump when fingerprint computation changes so stale prints are discarded.
    public static let fingerprintQualityVersion = 3

    // MARK: - Feature print computation

    /// Computes a Vision feature print for a still image.
    public static func computeFeaturePrint(
        for cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    #if canImport(UIKit)
    /// `UIImage` convenience wrapper; honors the image's orientation.
    public static func computeFeaturePrint(for image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        return computeFeaturePrint(for: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }
    #endif

    /// The current Vision request revision — persistence uses it to
    /// invalidate cached prints across OS upgrades.
    public static func currentFeaturePrintRevision() -> Int {
        VNGenerateImageFeaturePrintRequest().revision
    }

    // MARK: - State

    /// NSKeyedArchiver-encoded `VNFeaturePrintObservation`s keyed by asset ID.
    private var entries: [String: Data]
    /// Cached blur scores keyed by asset ID.
    private var blurScores: [String: Float]
    /// Last grouping result mirrored into `VisionGroupsDiskPayload.groups`.
    private var groupsState: VisionGroupsDiskPayload?
    /// Unarchived prints kept for the process lifetime so grouping does not
    /// re-unarchive the whole index on every pass.
    private var liveObservations: [String: VNFeaturePrintObservation] = [:]

    public init(diskState: VisionDiskState? = nil) {
        let qualityMatched = diskState?.quality == Self.fingerprintQualityVersion
        entries = qualityMatched ? (diskState?.entries ?? [:]) : [:]
        blurScores = qualityMatched ? (diskState?.blurScores ?? [:]) : [:]
        groupsState = qualityMatched ? diskState?.groups : nil
    }

    public var indexedCount: Int { entries.count }

    /// IDs in `ids` that do not yet have a feature print.
    public func missingPrintIDs(from ids: [String]) -> Set<String> {
        Set(ids.filter { entries[$0] == nil })
    }

    // MARK: - Indexing

    /// Stores a pre-computed feature print (and optional blur score) for an ID.
    public func index(
        featurePrint: VNFeaturePrintObservation?,
        blurScore: Float? = nil,
        for id: String
    ) {
        if let featurePrint {
            entries[id] = try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true)
            liveObservations[id] = featurePrint
        }
        if let blurScore {
            blurScores[id] = blurScore
        }
    }

    /// Explicitly updates or sets the blur score for an asset ID.
    public func setBlurScore(_ blurScore: Float, for id: String) {
        blurScores[id] = blurScore
    }

    /// Computes and stores the feature print (and optionally the blur score)
    /// for a decoded image.
    @discardableResult
    public func index(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        includeBlurScore: Bool = false,
        for id: String
    ) -> VNFeaturePrintObservation? {
        guard let print = Self.computeFeaturePrint(for: cgImage, orientation: orientation) else {
            return nil
        }
        let score = includeBlurScore ? BlurDetector.computeBlurScore(for: CIImage(cgImage: cgImage)) : nil
        index(featurePrint: print, blurScore: score, for: id)
        return print
    }

    public func removeEntries(for ids: Set<String>) {
        for id in ids {
            entries.removeValue(forKey: id)
            blurScores.removeValue(forKey: id)
            liveObservations.removeValue(forKey: id)
        }
    }

    public func reset() {
        entries.removeAll()
        blurScores.removeAll()
        liveObservations.removeAll()
        groupsState = nil
    }

    // MARK: - Pruning & windows (pure helpers)

    /// Prune prints missing from `decodeIDs` only when that set still
    /// contains most of the existing index (a full-library pass). A narrow
    /// subset (e.g. only newly added photos) must NOT wipe the whole index.
    public static func shouldPruneStalePrints(
        existingIDs: Set<String>,
        decodeIDs: Set<String>
    ) -> Bool {
        guard !existingIDs.isEmpty else { return false }
        let retained = existingIDs.intersection(decodeIDs).count
        return retained * 2 >= existingIDs.count
    }

    /// Chronological neighbor window around `target` in a date-sorted array.
    /// Used by incremental regroup instead of scanning every cluster member.
    public static func neighborBounds(
        target: Date,
        sortedDates: [Date],
        window: Int
    ) -> Range<Int> {
        guard !sortedDates.isEmpty, window > 0 else { return 0..<0 }
        var lo = 0
        var hi = sortedDates.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedDates[mid] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let lower = max(0, lo - window)
        let upper = min(sortedDates.count, lo + window)
        return lower..<upper
    }

    // MARK: - Blur

    /// IDs whose cached edge energy is below `threshold`, ascending score.
    public func blurryPhotoIDs(
        threshold: Float = VisionSimilarityConfig.blurThreshold
    ) -> [SearchResult] {
        blurScores
            .filter { $0.value < threshold }
            .map { SearchResult(identifier: $0.key, distance: $0.value) }
            .sorted { $0.distance < $1.distance }
    }

    // MARK: - Grouping

    /// Finds similar and exact-duplicate clusters over the indexed photos.
    ///
    /// - Parameters:
    ///   - assetIDs: Candidate IDs; only those with stored prints participate.
    ///   - creationDates: Optional dates used for chronological windowing
    ///     (burst photos sit close in time). Without dates, candidates keep
    ///     the given order and only the photo-gap window applies.
    ///   - maxCandidates: Optional prefix cap (chronological subset) for
    ///     progressive/partial grouping passes.
    ///   - persistGroups: When true the result becomes the cached-groups
    ///     payload consumed by incremental regroup.
    ///   - onPartial: Streamed growing subset of the final grouping (no
    ///     medoid refinement) — safe for mid-scan UI updates.
    ///   - onProgress: `(fraction, partialResult)`; the final call carries
    ///     the complete result.
    public func findSimilarGroups(
        assetIDs: [String],
        creationDates: [String: Date]? = nil,
        maxDistance: Float = VisionSimilarityConfig.maxDistance,
        duplicateMaxDistance: Float = VisionSimilarityConfig.duplicateMaxDistance,
        maxCandidates: Int? = nil,
        tuning: GroupingTuning = .default,
        persistGroups: Bool = true,
        onPartial: (@Sendable (VisionGroupingResult) -> Void)? = nil,
        onProgress: (@Sendable (Double, VisionGroupingResult?) -> Void)? = nil
    ) async -> VisionGroupingResult {
        var candidates: [(id: String, date: Date)] = []
        candidates.reserveCapacity(min(entries.count, assetIDs.count))
        if let creationDates {
            for id in assetIDs where entries[id] != nil {
                candidates.append((id, creationDates[id] ?? .distantPast))
            }
        } else {
            for id in assetIDs where entries[id] != nil {
                candidates.append((id, .distantPast))
            }
        }
        // Temporal windowing (lookahead + time-gap break) only finds bursts
        // when the walk is chronological.
        candidates.sort { $0.date < $1.date }
        if let maxCandidates {
            candidates = Array(candidates.prefix(maxCandidates))
        }

        let orderedIds = candidates.map(\.id)
        let dates = candidates.map(\.date)

        guard orderedIds.count >= 2 else {
            onProgress?(1.0, nil)
            return .empty
        }

        // Decode once per process — matching used to re-unarchive the same
        // prints on every grouping pass (dominant cost after indexing).
        onProgress?(0.02, nil)
        await prefetchObservations(for: orderedIds)
        let observationBag = ObservationBag()
        observationBag.map.reserveCapacity(orderedIds.count)
        for id in orderedIds {
            if let obs = liveObservations[id] {
                observationBag.map[id] = obs
            }
        }
        onProgress?(0.12, nil)

        let maxLookahead = tuning.maxLookahead
        let maxTimeGap = tuning.maxTimeGap
        let hardCap = max(1, tuning.hardCap)
        let chunkCount = max(1, tuning.matchChunkCount)
        let chunkSize = max(1, (orderedIds.count + chunkCount - 1) / chunkCount)

        let matches = await withTaskGroup(of: (similar: [Match], duplicate: [Match]).self) { group in
            for i in 0..<chunkCount {
                let start = i * chunkSize
                let end = min(start + chunkSize, orderedIds.count)
                if start >= end { continue }

                group.addTask {
                    var similarMatches: [Match] = []
                    var duplicateMatches: [Match] = []

                    for seedIndex in start..<end {
                        let seedId = orderedIds[seedIndex]
                        let seedDate = dates[seedIndex]
                        let compareEnd = min(orderedIds.count, seedIndex + 1 + hardCap)
                        guard let printA = observationBag.map[seedId] else { continue }

                        for otherIndex in (seedIndex + 1)..<compareEnd {
                            let photoGap = otherIndex - seedIndex
                            let timeGap = dates[otherIndex].timeIntervalSince(seedDate)
                            if photoGap > maxLookahead && timeGap > maxTimeGap {
                                break
                            }

                            guard let printB = observationBag.map[orderedIds[otherIndex]] else { continue }
                            var d: Float = .infinity
                            try? printA.computeDistance(&d, to: printB)

                            if d <= duplicateMaxDistance {
                                duplicateMatches.append(Match(u: seedIndex, v: otherIndex, distance: d))
                                similarMatches.append(Match(u: seedIndex, v: otherIndex, distance: d))
                            } else if d <= maxDistance {
                                similarMatches.append(Match(u: seedIndex, v: otherIndex, distance: d))
                            }
                        }
                    }
                    return (similarMatches, duplicateMatches)
                }
            }

            var allSimilar: [Match] = []
            var allDuplicate: [Match] = []
            var completed = 0
            for await chunkResult in group {
                allSimilar.append(contentsOf: chunkResult.similar)
                allDuplicate.append(contentsOf: chunkResult.duplicate)
                completed += 1
                // Stream the groups found so far — matches only accumulate,
                // so a union-find over matches-so-far is a valid growing
                // subset. Refinement (medoid) is skipped; the final result
                // still refines.
                if let onPartial, !chunkResult.similar.isEmpty || !chunkResult.duplicate.isEmpty {
                    onPartial(Self.unrefinedGrouping(
                        similar: allSimilar,
                        duplicate: allDuplicate,
                        orderedIds: orderedIds
                    ))
                }
                // Match phase is ~0.12...0.85 of grouping progress.
                let matchFraction = Double(min(orderedIds.count, completed * chunkSize))
                    / Double(orderedIds.count)
                onProgress?(0.12 + 0.73 * matchFraction, nil)
            }
            return (allSimilar, allDuplicate)
        }

        var parentSimilar = Array(0..<orderedIds.count)
        var rankSimilar = Array(repeating: 0, count: orderedIds.count)
        var parentDuplicate = Array(0..<orderedIds.count)
        var rankDuplicate = Array(repeating: 0, count: orderedIds.count)

        for match in matches.0 {
            Self.union(match.u, match.v, in: &parentSimilar, rank: &rankSimilar)
        }
        for match in matches.1 {
            Self.union(match.u, match.v, in: &parentDuplicate, rank: &rankDuplicate)
        }

        var bucketsSimilar: [Int: [Int]] = [:]
        var bucketsDuplicate: [Int: [Int]] = [:]
        for index in 0..<orderedIds.count {
            bucketsSimilar[Self.find(index, in: &parentSimilar), default: []].append(index)
            bucketsDuplicate[Self.find(index, in: &parentDuplicate), default: []].append(index)
        }

        let similarBuckets = bucketsSimilar.values.filter { $0.count >= 2 }
        let duplicateBuckets = bucketsDuplicate.values.filter { $0.count >= 2 }
        let refineTotal = max(1, similarBuckets.count + duplicateBuckets.count)
        onProgress?(0.86, nil)

        let refined = await withTaskGroup(
            of: (isDuplicate: Bool, cluster: VisionPhotoCluster?).self
        ) { group in
            for indices in similarBuckets {
                let memberIds = indices.map { orderedIds[$0] }
                group.addTask {
                    (false, Self.refineCluster(
                        memberIds: memberIds,
                        limitDistance: maxDistance,
                        observations: observationBag,
                        exactMedoidMemberLimit: tuning.exactMedoidMemberLimit
                    ))
                }
            }
            for indices in duplicateBuckets {
                let memberIds = indices.map { orderedIds[$0] }
                group.addTask {
                    (true, Self.refineCluster(
                        memberIds: memberIds,
                        limitDistance: duplicateMaxDistance,
                        observations: observationBag,
                        exactMedoidMemberLimit: tuning.exactMedoidMemberLimit
                    ))
                }
            }

            var similarClusters: [VisionPhotoCluster] = []
            var duplicateClusters: [VisionPhotoCluster] = []
            var done = 0
            for await item in group {
                if let cluster = item.cluster {
                    if item.isDuplicate {
                        duplicateClusters.append(cluster)
                    } else {
                        similarClusters.append(cluster)
                    }
                }
                done += 1
                if done % 8 == 0 || done == refineTotal {
                    onProgress?(0.86 + 0.13 * Double(done) / Double(refineTotal), nil)
                }
            }
            return (similarClusters, duplicateClusters)
        }

        var similarClusters = refined.0
        var duplicateClusters = refined.1
        similarClusters.sort { $0.members.count > $1.members.count }
        duplicateClusters.sort { $0.members.count > $1.members.count }

        let finalResult = VisionGroupingResult(similar: similarClusters, duplicates: duplicateClusters)
        onProgress?(1.0, finalResult)
        if persistGroups {
            saveGroupsCache(finalResult)
        }
        return finalResult
    }

    // MARK: - Cached groups & incremental regroup

    /// True only when every candidate has a feature print. Grouping over a
    /// partial index silently drops candidates and reshuffles clusters once
    /// indexing completes.
    public func hasCompleteEntries(for assetIDs: [String]) -> Bool {
        assetIDs.allSatisfy { entries[$0] != nil }
    }

    public func loadCachedGroups() -> VisionGroupingResult? {
        cachedGroupsIfValid(requireExactIndexedIDs: true)
    }

    /// Cached groups are usable even if a few indexed IDs are missing.
    public func loadCachedGroupsLenient() -> VisionGroupingResult? {
        cachedGroupsIfValid(requireExactIndexedIDs: false)
    }

    private func cachedGroupsIfValid(requireExactIndexedIDs: Bool) -> VisionGroupingResult? {
        guard let groupsState else { return nil }
        guard groupsState.revision == Self.currentFeaturePrintRevision() else { return nil }
        guard groupsState.minPercent == VisionSimilarityConfig.minimumPercent,
              groupsState.maxDistance == VisionSimilarityConfig.maxDistance,
              groupsState.duplicatePercent == VisionSimilarityConfig.duplicatePercent
        else { return nil }
        let indexedIDs = Set(entries.keys)
        if requireExactIndexedIDs {
            guard Set(groupsState.indexedIds) == indexedIDs else { return nil }
        } else {
            guard Set(groupsState.indexedIds).isSubset(of: indexedIDs) else { return nil }
        }
        let similar = groupsState.clusters.compactMap(decodeCluster(_:))
        let duplicates = groupsState.duplicateClusters.compactMap(decodeCluster(_:))
        return VisionGroupingResult(similar: similar, duplicates: duplicates)
    }

    /// Attaches newly indexed photos to the cached groups without a full
    /// regroup: only chronological neighbors of the new photos (plus
    /// new-vs-new pairs) are compared. Returns nil when no valid cached
    /// groups exist.
    public func mergeNewPhotosIntoCachedGroups(
        newIDs: [String],
        creationDates: [String: Date],
        neighborWindow: Int = GroupingTuning.default.hardCap
    ) async -> VisionGroupingResult? {
        guard let cached = cachedGroupsIfValid(requireExactIndexedIDs: false) else { return nil }
        let newWithPrints = newIDs.filter { entries[$0] != nil }
        guard !newWithPrints.isEmpty else { return nil }

        var memberDates: [String: Date] = [:]
        var allMembers: [String] = []
        var seenMembers = Set<String>()
        for cluster in cached.similar + cached.duplicates {
            for member in cluster.members where seenMembers.insert(member.identifier).inserted {
                allMembers.append(member.identifier)
                memberDates[member.identifier] = creationDates[member.identifier] ?? .distantPast
            }
        }
        let sortedMembers = allMembers.sorted {
            (memberDates[$0] ?? .distantPast) < (memberDates[$1] ?? .distantPast)
        }
        let sortedDates = sortedMembers.map { memberDates[$0] ?? .distantPast }

        var candidateIDs = Set<String>()
        candidateIDs.reserveCapacity(min(sortedMembers.count, newWithPrints.count * neighborWindow * 2))
        for newID in newWithPrints {
            let date = creationDates[newID] ?? .distantPast
            let bounds = Self.neighborBounds(
                target: date,
                sortedDates: sortedDates,
                window: neighborWindow
            )
            for index in bounds {
                candidateIDs.insert(sortedMembers[index])
            }
        }
        candidateIDs.subtract(newWithPrints)

        await prefetchObservations(for: newWithPrints + Array(candidateIDs))
        let bag = ObservationBag()
        for id in newWithPrints + Array(candidateIDs) {
            if let observation = liveObservations[id] {
                bag.map[id] = observation
            }
        }

        let maxDistance = VisionSimilarityConfig.maxDistance
        let duplicateMaxDistance = VisionSimilarityConfig.duplicateMaxDistance

        var similarMatches: [(new: String, old: String, distance: Float)] = []
        var duplicateMatches: [(new: String, old: String, distance: Float)] = []

        func compare(_ lhs: String, _ rhs: String) {
            guard let printA = bag.map[lhs], let printB = bag.map[rhs] else { return }
            var distance: Float = .infinity
            try? printA.computeDistance(&distance, to: printB)
            if distance <= duplicateMaxDistance {
                duplicateMatches.append((lhs, rhs, distance))
                similarMatches.append((lhs, rhs, distance))
            } else if distance <= maxDistance {
                similarMatches.append((lhs, rhs, distance))
            }
        }

        for newID in newWithPrints {
            for oldID in candidateIDs { compare(newID, oldID) }
        }
        for i in 0..<newWithPrints.count {
            for j in (i + 1)..<newWithPrints.count {
                compare(newWithPrints[i], newWithPrints[j])
            }
        }

        guard !similarMatches.isEmpty || !duplicateMatches.isEmpty else {
            // New photos match nothing — cached groups stand.
            saveGroupsCache(cached)
            return cached
        }

        let similar = mergedClusters(
            cachedClusters: cached.similar,
            newIDs: newWithPrints,
            matches: similarMatches
        )
        let duplicates = mergedClusters(
            cachedClusters: cached.duplicates,
            newIDs: newWithPrints,
            matches: duplicateMatches
        )
        let result = VisionGroupingResult(similar: similar, duplicates: duplicates)
        saveGroupsCache(result)
        return result
    }

    // MARK: - Disk snapshot

    /// Current state as a Codable payload (see `DiskStateCodec` for I/O).
    public func diskState() -> VisionDiskState {
        VisionDiskState(
            entries: entries,
            blurScores: blurScores,
            revision: Self.currentFeaturePrintRevision(),
            quality: Self.fingerprintQualityVersion,
            groups: groupsState
        )
    }

    /// Replaces the cached-groups payload (e.g. loaded from disk).
    public func restoreGroups(_ groups: VisionGroupsDiskPayload?) {
        groupsState = groups
    }

    // MARK: - Private

    struct Match: Sendable {
        let u: Int
        let v: Int
        let distance: Float
    }

    /// Shared decoded prints for parallel match + refine (`@unchecked` —
    /// Vision observations are reference types used read-only).
    final class ObservationBag: @unchecked Sendable {
        var map: [String: VNFeaturePrintObservation] = [:]
    }

    private func prefetchObservations(for ids: [String]) async {
        await withTaskGroup(of: (String, VNFeaturePrintObservation)?.self) { group in
            for id in ids where liveObservations[id] == nil {
                guard let data = entries[id] else { continue }
                group.addTask {
                    Self.unarchiveObservation(data).map { (id, $0) }
                }
            }
            for await result in group {
                if let (id, observation) = result {
                    liveObservations[id] = observation
                }
            }
        }
    }

    nonisolated static func unarchiveObservation(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Union-find over the matches accumulated so far, without medoid
    /// refinement. Matches only ever get appended, so each call returns a
    /// growing subset of the final grouping — safe for mid-scan updates.
    static func unrefinedGrouping(
        similar: [Match],
        duplicate: [Match],
        orderedIds: [String]
    ) -> VisionGroupingResult {
        let count = orderedIds.count
        var parentS = Array(0..<count)
        var rankS = [Int](repeating: 0, count: count)
        var parentD = Array(0..<count)
        var rankD = [Int](repeating: 0, count: count)

        for match in similar { union(match.u, match.v, in: &parentS, rank: &rankS) }
        for match in duplicate { union(match.u, match.v, in: &parentD, rank: &rankD) }

        func clusters(_ parent: inout [Int]) -> [VisionPhotoCluster] {
            var buckets: [Int: [Int]] = [:]
            for index in 0..<count {
                buckets[find(index, in: &parent), default: []].append(index)
            }
            return buckets.values
                .filter { $0.count >= 2 }
                .map { indices in
                    VisionPhotoCluster(
                        representativeId: orderedIds[indices[0]],
                        members: indices.map {
                            SearchResult(identifier: orderedIds[$0], distance: 0)
                        }
                    )
                }
                .sorted { $0.members.count > $1.members.count }
        }

        return VisionGroupingResult(
            similar: clusters(&parentS),
            duplicates: clusters(&parentD)
        )
    }

    /// Picks the cluster medoid (exact all-pairs minimization for small
    /// clusters) and drops members farther than `limitDistance` from it.
    static func refineCluster(
        memberIds: [String],
        limitDistance: Float,
        observations: ObservationBag,
        exactMedoidMemberLimit: Int
    ) -> VisionPhotoCluster? {
        guard memberIds.count >= 2 else { return nil }

        var bestMedoid = memberIds[0]
        if memberIds.count <= exactMedoidMemberLimit {
            var bestScore = Float.infinity
            for candidate in memberIds {
                guard let printCandidate = observations.map[candidate] else { continue }
                var total: Float = 0
                for other in memberIds where other != candidate {
                    guard let printOther = observations.map[other] else { continue }
                    var value: Float = .infinity
                    try? printCandidate.computeDistance(&value, to: printOther)
                    total += value
                }
                if total < bestScore {
                    bestScore = total
                    bestMedoid = candidate
                }
            }
        }

        guard let printMedoid = observations.map[bestMedoid] else { return nil }
        var members: [SearchResult] = [SearchResult(identifier: bestMedoid, distance: 0)]
        for id in memberIds where id != bestMedoid {
            guard let printOther = observations.map[id] else { continue }
            var value: Float = .infinity
            try? printMedoid.computeDistance(&value, to: printOther)
            if value <= limitDistance {
                members.append(SearchResult(identifier: id, distance: value))
            }
        }

        guard members.count >= 2 else { return nil }
        members.sort { $0.distance < $1.distance }
        return VisionPhotoCluster(representativeId: bestMedoid, members: members)
    }

    /// Union cached clusters with attached new photos for one match side.
    /// Untouched cached clusters carry over as-is; merged clusters keep the
    /// cached representative. New photos matching only each other form
    /// fresh clusters.
    func mergedClusters(
        cachedClusters: [VisionPhotoCluster],
        newIDs: [String],
        matches: [(new: String, old: String, distance: Float)]
    ) -> [VisionPhotoCluster] {
        let clusterCount = cachedClusters.count
        var memberToCluster: [String: Int] = [:]
        for (index, cluster) in cachedClusters.enumerated() {
            for member in cluster.members {
                memberToCluster[member.identifier] = index
            }
        }

        // Union-find over cluster indices + new-photo slots.
        var parent = Array(0..<(clusterCount + newIDs.count))
        var rank = [Int](repeating: 0, count: parent.count)
        func findLocal(_ x: Int) -> Int {
            if parent[x] != x { parent[x] = findLocal(parent[x]) }
            return parent[x]
        }
        func unionLocal(_ a: Int, _ b: Int) {
            var pa = findLocal(a)
            var pb = findLocal(b)
            if pa == pb { return }
            // Cached groups occupy 0..<clusterCount. When a new photo joins
            // one, that group stays the root so new shots are appended to it
            // instead of also forming a second cluster.
            let paIsCluster = pa < clusterCount
            let pbIsCluster = pb < clusterCount
            if paIsCluster != pbIsCluster {
                if !paIsCluster { Swift.swap(&pa, &pb) }
            } else if rank[pa] < rank[pb] {
                Swift.swap(&pa, &pb)
            } else if rank[pa] == rank[pb], pa > pb {
                Swift.swap(&pa, &pb)
            }
            parent[pb] = pa
            if rank[pa] == rank[pb] { rank[pa] += 1 }
        }

        var newSlot: [String: Int] = [:]
        for (offset, id) in newIDs.enumerated() {
            newSlot[id] = clusterCount + offset
        }

        var bestDistance: [String: Float] = [:]
        func noteDistance(_ id: String, _ distance: Float) {
            if distance < (bestDistance[id] ?? .infinity) {
                bestDistance[id] = distance
            }
        }
        for match in matches {
            guard let newPhotoSlot = newSlot[match.new] else { continue }
            if let clusterIndex = memberToCluster[match.old] {
                unionLocal(clusterIndex, newPhotoSlot)
                noteDistance(match.new, match.distance)
            } else if let otherNewSlot = newSlot[match.old] {
                unionLocal(otherNewSlot, newPhotoSlot)
                noteDistance(match.new, match.distance)
                noteDistance(match.old, match.distance)
            }
        }

        // New photos attached to each component root (root itself may be a
        // cached cluster or a new-photo slot for new-only components).
        var newPhotosByRoot: [Int: [String]] = [:]
        for (id, slot) in newSlot {
            let root = findLocal(slot)
            if root != slot {
                newPhotosByRoot[root, default: []].append(id)
            }
        }

        var result: [VisionPhotoCluster] = []
        result.reserveCapacity(cachedClusters.count + newPhotosByRoot.count)
        var consumedRoots = Set<Int>()

        for (index, cluster) in cachedClusters.enumerated() {
            let root = findLocal(index)
            guard consumedRoots.insert(root).inserted else { continue }
            guard let attachedNew = newPhotosByRoot[root], !attachedNew.isEmpty else {
                // Untouched cached cluster.
                result.append(cluster)
                continue
            }
            var members = cluster.members
            for newID in attachedNew {
                members.append(
                    SearchResult(
                        identifier: newID,
                        distance: bestDistance[newID] ?? 0
                    )
                )
            }
            result.append(
                VisionPhotoCluster(
                    representativeId: cluster.representativeId,
                    members: members
                )
            )
        }

        // New-only components: root is a new-photo slot; members are the
        // root photo plus everything attached to it. Singletons are not
        // clusters.
        for (id, slot) in newSlot {
            let root = findLocal(slot)
            guard root == slot, let attached = newPhotosByRoot[root], !attached.isEmpty else { continue }
            var members = [SearchResult(identifier: id, distance: 0)]
            members.append(
                contentsOf: attached.map {
                    SearchResult(identifier: $0, distance: bestDistance[$0] ?? 0)
                }
            )
            result.append(
                VisionPhotoCluster(representativeId: id, members: members)
            )
        }

        return result.sorted { $0.members.count > $1.members.count }
    }

    private func saveGroupsCache(_ result: VisionGroupingResult) {
        groupsState = VisionGroupsDiskPayload(
            revision: Self.currentFeaturePrintRevision(),
            minPercent: VisionSimilarityConfig.minimumPercent,
            maxDistance: VisionSimilarityConfig.maxDistance,
            duplicatePercent: VisionSimilarityConfig.duplicatePercent,
            indexedIds: Array(entries.keys),
            clusters: result.similar.map(encodeCluster(_:)),
            duplicateClusters: result.duplicates.map(encodeCluster(_:))
        )
    }

    private func decodeCluster(_ cluster: VisionGroupsDiskPayload.Cluster) -> VisionPhotoCluster? {
        let members = cluster.members.map {
            SearchResult(identifier: $0.id, distance: $0.distance)
        }
        guard members.count >= 2 else { return nil }
        return VisionPhotoCluster(representativeId: cluster.representativeId, members: members)
    }

    private func encodeCluster(_ cluster: VisionPhotoCluster) -> VisionGroupsDiskPayload.Cluster {
        VisionGroupsDiskPayload.Cluster(
            representativeId: cluster.representativeId,
            members: cluster.members.map {
                VisionGroupsDiskPayload.Member(id: $0.identifier, distance: $0.distance)
            }
        )
    }

    // MARK: - Union-find helpers

    private static func find(_ x: Int, in parent: inout [Int]) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x], in: &parent)
        }
        return parent[x]
    }

    private static func union(_ a: Int, _ b: Int, in parent: inout [Int], rank: inout [Int]) {
        var pa = find(a, in: &parent)
        var pb = find(b, in: &parent)
        if pa == pb { return }
        if rank[pa] < rank[pb] { Swift.swap(&pa, &pb) }
        parent[pb] = pa
        if rank[pa] == rank[pb] { rank[pa] += 1 }
    }
}

#if canImport(UIKit)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
