import Foundation
import Network

/// Finds WLED controllers via Bonjour (`_wled._tcp`), so the user never has to
/// type an IP or sweep a subnet.
///
/// NWBrowser hands back opaque service endpoints, not addresses. We resolve each
/// one by opening a short-lived TCP connection and reading the resolved remote
/// endpoint off its path, then cancelling. That gives a stable IP literal, which
/// is what we persist — `.local` names depend on mDNS being healthy at every
/// later launch.
final class Discovery {

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "local.wled.discovery")

    /// Called on the main queue for every controller found.
    var onFound: ((_ host: String, _ serviceName: String) -> Void)?
    var onStateChange: ((_ running: Bool, _ message: String?) -> Void)?

    func start() {
        stop()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_wled._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.onStateChange?(true, nil)
                case .failed(let error):
                    self?.onStateChange?(false, error.localizedDescription)
                case .cancelled:
                    self?.onStateChange?(false, nil)
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                self?.resolve(result.endpoint, serviceName: name)
            }
        }

        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func resolve(_ endpoint: NWEndpoint, serviceName: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let host = connection.currentPath
                    .flatMap { Self.ipLiteral(from: $0.remoteEndpoint) }
                connection.cancel()
                if let host {
                    DispatchQueue.main.async { self?.onFound?(host, serviceName) }
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    /// Pull a plain address string out of a resolved endpoint, dropping the
    /// interface suffix that IPv6 link-local addresses carry (`fe80::1%en0`).
    private static func ipLiteral(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first
        case .ipv6(let address):
            guard let plain = "\(address)".components(separatedBy: "%").first else { return nil }
            return "[\(plain)]"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}
