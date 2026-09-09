import Testing
import Foundation
@testable import VoxtrAppShell

// PR #84 follow-up (QR scan orchestration testability): `AthleteConnectionScanCoordinator
// .handleScannedText(_:transport:session:)` — the ONE production adapter —
// performs real CloudKit network I/O and, on success, the real
// B2.2 → B2.3 → B2.4 acceptance chain, so it is never exercised here,
// matching this codebase's established B1/B2 XCTEST-SAFETY convention.
// What IS fully unit-testable is the generic `handleScannedText(_:
// resolveShareMetadata:handleAcceptedShare:)` overload this seam adds —
// exercised below with injected closures and a tiny local placeholder
// type standing in for `CKShare.Metadata` (which has no public
// initializer reachable without a real accepted share). These tests
// prove routing/call-count/re-entrance semantics only — never Apple's
// own CKShare.Metadata implementation.
@Suite("AthleteConnectionScanCoordinator (PR #84 follow-up: QR scan orchestration testability)")
@MainActor
struct AthleteConnectionScanCoordinatorTests {

    /// Stands in for `CKShare.Metadata` — deliberately NOT CloudKit-typed
    /// at all, so these tests can never be accused of fabricating real
    /// CloudKit business identity. Only its own identity (`token`)
    /// matters for these tests.
    private struct FakeMetadata: Equatable {
        let token: Int
    }

    private enum FakeError: Error {
        case metadataFetchFailed
    }

    /// Plain actor-isolated counter — safe to mutate from concurrently-
    /// interleaved closures under `@MainActor`/structured concurrency,
    /// mirroring `AthleteConnectAppInProgressStateTests.InvocationCounter`'s
    /// own established precedent in this repository.
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// Coordinates a suspended resolver closure with the test — real
    /// Swift Concurrency suspension via `withCheckedContinuation`, never
    /// a sleep/delay/`Task.yield()` guess. Mirrors
    /// `AthleteConnectAppInProgressStateTests.Gate`'s own established
    /// precedent in this repository exactly.
    private actor Gate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var proceedContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func markEntered() {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func waitToProceed() async {
            if released { return }
            await withCheckedContinuation { proceedContinuation = $0 }
        }

        func release() {
            released = true
            proceedContinuation?.resume()
            proceedContinuation = nil
        }
    }

    @Test("A valid, supported QR resolves metadata exactly once and hands the exact resolved metadata to the acceptance handler exactly once")
    func validQRRoutesExactlyOnceWithUnchangedMetadata() async {
        let coordinator = AthleteConnectionScanCoordinator()
        let resolveCounter = Counter()
        let acceptCounter = Counter()
        let expected = FakeMetadata(token: 42)
        var receivedMetadata: FakeMetadata?

        let outcome = await coordinator.handleScannedText(
            "https://www.icloud.com/share/abc",
            resolveShareMetadata: { _ in
                await resolveCounter.increment()
                return expected
            },
            handleAcceptedShare: { metadata in
                await acceptCounter.increment()
                receivedMetadata = metadata
            }
        )

        #expect(outcome == nil)
        #expect(await resolveCounter.count == 1)
        #expect(await acceptCounter.count == 1)
        #expect(receivedMetadata == expected)
    }

    @Test("An unsupported/invalid QR is rejected with .invalidCode before EITHER the metadata resolver or the acceptance handler is ever called")
    func invalidQRNeverReachesResolverOrAcceptance() async {
        let coordinator = AthleteConnectionScanCoordinator()
        let resolveCounter = Counter()
        let acceptCounter = Counter()

        let outcome = await coordinator.handleScannedText(
            "not a supported connection code",
            resolveShareMetadata: { _ in
                await resolveCounter.increment()
                return FakeMetadata(token: 1)
            },
            handleAcceptedShare: { _ in
                await acceptCounter.increment()
            }
        )

        #expect(outcome == .invalidCode)
        #expect(await resolveCounter.count == 0)
        #expect(await acceptCounter.count == 0)
    }

    @Test("A metadata-resolution failure is reported as .shareMetadataFetchFailed, the resolver is called exactly once, and the acceptance handler is never invoked")
    func metadataResolutionFailureNeverReachesAcceptance() async {
        let coordinator = AthleteConnectionScanCoordinator()
        let resolveCounter = Counter()
        let acceptCounter = Counter()

        let outcome = await coordinator.handleScannedText(
            "https://www.icloud.com/share/abc",
            resolveShareMetadata: { (_: URL) -> FakeMetadata in
                await resolveCounter.increment()
                throw FakeError.metadataFetchFailed
            },
            handleAcceptedShare: { _ in
                await acceptCounter.increment()
            }
        )

        #expect(outcome == .shareMetadataFetchFailed)
        #expect(await resolveCounter.count == 1)
        #expect(await acceptCounter.count == 0)
    }

    @Test("A second scan reported on the SAME coordinator instance while the first is still resolving is rejected with .alreadyInFlight, so one emitted scan event never invokes canonical acceptance twice")
    func overlappingScansNeverDoubleAccept() async {
        let coordinator = AthleteConnectionScanCoordinator()
        let resolveCounter = Counter()
        let acceptCounter = Counter()
        let gate = Gate()

        let firstTask = Task { @MainActor in
            await coordinator.handleScannedText(
                "https://www.icloud.com/share/abc",
                resolveShareMetadata: { _ in
                    await resolveCounter.increment()
                    await gate.markEntered()
                    await gate.waitToProceed()
                    return FakeMetadata(token: 1)
                },
                handleAcceptedShare: { _ in
                    await acceptCounter.increment()
                }
            )
        }

        // Guaranteed (via real suspension, never a timing guess) that the
        // first call's resolver has actually started before the second
        // call below is issued.
        await gate.waitUntilEntered()

        let secondOutcome = await coordinator.handleScannedText(
            "https://www.icloud.com/share/abc",
            resolveShareMetadata: { _ in
                await resolveCounter.increment()
                return FakeMetadata(token: 2)
            },
            handleAcceptedShare: { _ in
                await acceptCounter.increment()
            }
        )

        #expect(secondOutcome == .alreadyInFlight)
        // Only the FIRST call's resolver has run so far — the second
        // call's own resolver closure was never invoked at all.
        #expect(await resolveCounter.count == 1)
        #expect(await acceptCounter.count == 0)

        await gate.release()
        let firstOutcome = await firstTask.value

        #expect(firstOutcome == nil)
        #expect(await resolveCounter.count == 1)
        #expect(await acceptCounter.count == 1)
    }

    @Test("After a scan settles (success or failure), the coordinator accepts a genuinely new scan again — the re-entrance guard is not permanently stuck")
    func guardResetsAfterCompletion() async {
        let coordinator = AthleteConnectionScanCoordinator()
        let acceptCounter = Counter()

        let firstOutcome = await coordinator.handleScannedText(
            "https://www.icloud.com/share/abc",
            resolveShareMetadata: { (_: URL) -> FakeMetadata in FakeMetadata(token: 1) },
            handleAcceptedShare: { _ in await acceptCounter.increment() }
        )
        let secondOutcome = await coordinator.handleScannedText(
            "https://www.icloud.com/share/abc",
            resolveShareMetadata: { (_: URL) -> FakeMetadata in FakeMetadata(token: 2) },
            handleAcceptedShare: { _ in await acceptCounter.increment() }
        )

        #expect(firstOutcome == nil)
        #expect(secondOutcome == nil)
        #expect(await acceptCounter.count == 2)
    }
}
