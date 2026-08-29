import Testing
import VoxtrCore

@Suite("Event bus")
struct EventBusTests {

    @Test("A subscriber receives an event published after it subscribes")
    func subscriberReceivesEvent() async {
        let bus = EventBus()
        actor Received {
            var events: [AppDidFinishLaunchingEvent] = []
            func record(_ event: AppDidFinishLaunchingEvent) { events.append(event) }
        }
        let received = Received()

        _ = bus.subscribe(to: AppDidFinishLaunchingEvent.self) { event in
            Task { await received.record(event) }
        }

        await bus.publish(AppDidFinishLaunchingEvent())
        // Allow the detached Task above to run.
        try? await Task.sleep(for: .milliseconds(50))

        let count = await received.events.count
        #expect(count == 1)
    }

    @Test("Unsubscribing stops further delivery")
    func unsubscribeStopsDelivery() async {
        let bus = EventBus()
        actor Counter { var count = 0; func increment() { count += 1 } }
        let counter = Counter()

        let token = bus.subscribe(to: AppDidFinishLaunchingEvent.self) { _ in
            Task { await counter.increment() }
        }
        bus.unsubscribe(token, from: AppDidFinishLaunchingEvent.self)
        await bus.publish(AppDidFinishLaunchingEvent())
        try? await Task.sleep(for: .milliseconds(50))

        let count = await counter.count
        #expect(count == 0)
    }
}
