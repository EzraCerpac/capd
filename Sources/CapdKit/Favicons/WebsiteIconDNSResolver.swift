import Darwin
import Foundation
import dnssd

struct WebsiteIconDNSResolver: Sendable {
    struct Answer: Sendable {
        let address: WebsiteIconAddress
        let added: Bool
        let moreComing: Bool
    }
    typealias Receiver = @Sendable (Result<Answer, any Error>) -> Void
    typealias Start =
        @Sendable (String, DispatchQueue, @escaping Receiver) throws -> (@Sendable () -> Void)
    private let start: Start

    init() { start = NativeService.start }
    init(start: @escaping Start) { self.start = start }

    func resolve(_ host: String, deadline: ContinuousClock.Instant) async throws
        -> [WebsiteIconAddress]
    {
        let query = Query(host: host, deadline: deadline, start: start)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { query.begin($0) }
        } onCancel: {
            query.cancel()
        }
    }

    private final class NativeService: @unchecked Sendable {
        private var service: DNSServiceRef?
        private let receive: Receiver
        init(receive: @escaping Receiver) { self.receive = receive }
        static func start(_ host: String, queue: DispatchQueue, receive: @escaping Receiver) throws
            -> (@Sendable () -> Void)
        {
            let query = NativeService(receive: receive)
            let status = DNSServiceGetAddrInfo(
                &query.service, 0, 0,
                DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host,
                { _, flags, _, error, _, address, _, context in
                    guard let context else { return }
                    let query = Unmanaged<NativeService>.fromOpaque(context).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError, let address,
                        let parsed = WebsiteIconAddress(socketAddress: address)
                    else {
                        query.receive(.failure(WebsiteIconTransportError.dns))
                        return
                    }
                    query.receive(
                        .success(
                            Answer(
                                address: parsed,
                                added: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                                moreComing: flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
                            )))
                }, Unmanaged.passUnretained(query).toOpaque())
            guard status == kDNSServiceErr_NoError, let service = query.service,
                DNSServiceSetDispatchQueue(service, queue) == kDNSServiceErr_NoError
            else {
                query.close()
                throw WebsiteIconTransportError.dns
            }
            return { query.close() }
        }
        private func close() {
            if let service {
                DNSServiceRefDeallocate(service)
                self.service = nil
            }
        }
    }

    private final class Query: @unchecked Sendable {
        private let queue = DispatchQueue(label: "capd.website-icon.dns")
        private let host: String
        private let deadline: ContinuousClock.Instant
        private let start: Start
        private var stop: (@Sendable () -> Void)?
        private var addresses: [WebsiteIconAddress] = []
        private var continuation: CheckedContinuation<[WebsiteIconAddress], any Error>?
        private var cancelled = false
        private var timeout: DispatchWorkItem?

        init(host: String, deadline: ContinuousClock.Instant, start: @escaping Start) {
            self.host = host
            self.deadline = deadline
            self.start = start
        }
        func begin(_ continuation: CheckedContinuation<[WebsiteIconAddress], any Error>) {
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else {
                    self.finish(.failure(CancellationError()))
                    return
                }
                guard ContinuousClock.now < self.deadline else {
                    self.finish(.failure(WebsiteIconTransportError.deadline))
                    return
                }
                do {
                    self.stop = try self.start(self.host, self.queue) { result in
                        self.queue.async { self.received(result) }
                    }
                } catch {
                    self.finish(.failure(error))
                    return
                }
                let timeout = DispatchWorkItem {
                    self.finish(.failure(WebsiteIconTransportError.deadline))
                }
                self.timeout = timeout
                let value = ContinuousClock.now.duration(to: self.deadline).components
                let seconds = max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
                self.queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
            }
        }
        func cancel() {
            queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
        private func received(_ result: Result<Answer, any Error>) {
            guard continuation != nil else { return }
            guard ContinuousClock.now < deadline else {
                finish(.failure(WebsiteIconTransportError.deadline))
                return
            }
            guard case .success(let answer) = result,
                WebsiteIconAddressPolicy.isPublic(answer.address)
            else {
                finish(.failure(WebsiteIconTransportError.dns))
                return
            }
            if answer.added, !addresses.contains(answer.address) {
                guard addresses.count < 16 else {
                    finish(.failure(WebsiteIconTransportError.dns))
                    return
                }
                addresses.append(answer.address)
            }
            if !answer.moreComing, !addresses.isEmpty { finish(.success(addresses)) }
        }
        private func finish(_ result: Result<[WebsiteIconAddress], any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            stop?()
            stop = nil
            continuation.resume(with: result)
        }
    }
}
