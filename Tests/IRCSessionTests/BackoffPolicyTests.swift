import Testing

@testable import IRCSession

/// The schedule is arithmetic, so it is tested as arithmetic. Waiting five minutes to
/// observe a five-minute delay is not a test anyone runs twice.
@Suite("Backoff")
struct BackoffPolicyTests {
    private let policy = BackoffPolicy(
        initialDelay: .seconds(2),
        multiplier: 2,
        maximumDelay: .seconds(60),
        jitterFraction: 0
    )

    @Test("doubles each attempt until the ceiling")
    func schedule() {
        let delays = (1...8).map { policy.delay(forAttempt: $0, randomness: 0.5).seconds }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test("the first attempt waits the initial delay, not zero")
    func firstAttempt() {
        #expect(policy.delay(forAttempt: 1, randomness: 0.5).seconds == 2)
    }

    @Test("an attempt below one has no delay")
    func nonPositiveAttempt() {
        #expect(policy.delay(forAttempt: 0, randomness: 0.5) == .zero)
        #expect(policy.delay(forAttempt: -3, randomness: 0.5) == .zero)
    }

    @Test("jitter spreads symmetrically around the base delay")
    func jitter() {
        let jittered = BackoffPolicy(
            initialDelay: .seconds(10),
            multiplier: 2,
            maximumDelay: .seconds(600),
            jitterFraction: 0.2
        )
        #expect(jittered.delay(forAttempt: 1, randomness: 0.5).seconds == 10)
        #expect(jittered.delay(forAttempt: 1, randomness: 0).seconds == 8)
        #expect(jittered.delay(forAttempt: 1, randomness: 1).seconds == 12)
    }

    @Test("a random delay stays inside the jitter band")
    func randomStaysInBand() {
        let jittered = BackoffPolicy(
            initialDelay: .seconds(4),
            multiplier: 2,
            maximumDelay: .seconds(600),
            jitterFraction: 0.25
        )
        for _ in 0..<200 {
            let seconds = jittered.delay(forAttempt: 3).seconds  // base 16, ±4
            #expect(seconds >= 12 && seconds <= 20)
        }
    }

    /// Jitter must never produce a negative delay, whatever the fraction.
    @Test("an absurd jitter fraction still yields a non-negative delay")
    func neverNegative() {
        let wild = BackoffPolicy(
            initialDelay: .seconds(5),
            multiplier: 2,
            maximumDelay: .seconds(60),
            jitterFraction: 4
        )
        #expect(wild.delay(forAttempt: 1, randomness: 0).seconds >= 0)
    }

    @Test("the ceiling applies before jitter, so the band sits around it")
    func ceilingWithJitter() {
        let capped = BackoffPolicy(
            initialDelay: .seconds(1),
            multiplier: 10,
            maximumDelay: .seconds(30),
            jitterFraction: 0.1
        )
        #expect(capped.delay(forAttempt: 9, randomness: 1).seconds == 33)
    }
}
