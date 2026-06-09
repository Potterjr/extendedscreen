import Foundation
import Network
import CoreMedia

/// Sends encoded frame packets to the Android client over TCP.
class SocketSender {

    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "socket.send", qos: .userInteractive)

    private static let magic: UInt32 = 0x45585444 // 'EXTD'
    private static let typeFrame: UInt8 = 0x01
    private static let headerSize = 17

    func connect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.tcp
        params.defaultProtocolStack.transportProtocol
            .flatMap { $0 as? NWProtocolTCP.Options }
            .map { $0.noDelay = true }

        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { state in
            switch state {
            case .ready:   print("[Socket] Connected to \(host):\(port)")
            case .failed(let e): print("[Socket] Failed: \(e)")
            default: break
            }
        }
        connection?.start(queue: sendQueue)
    }

    func sendFrame(_ nalData: Data, isKeyframe: Bool, pts: CMTime) {
        guard let conn = connection else { return }
        let tsUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        var header = Data(count: SocketSender.headerSize)
        header.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: SocketSender.magic.bigEndian, as: UInt32.self)
            buf.storeBytes(of: SocketSender.typeFrame,       toByteOffset: 4,  as: UInt8.self)
            buf.storeBytes(of: UInt32(nalData.count).bigEndian, toByteOffset: 5, as: UInt32.self)
            buf.storeBytes(of: tsUs.bigEndian,               toByteOffset: 9,  as: Int64.self)
        }
        let packet = header + nalData
        conn.send(content: packet, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
