import Foundation
import Network

/// 이 Mac 안(loopback)에서만 받는 아주 작은 HTTP/1.1 서버. 요청마다 연결 하나를 쓰고 답하면 닫는다.
final class ConnectorServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        /// 이름은 소문자.
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var body: Data

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }

        static func error(_ status: Int, _ message: String) -> Response { json(["error": message], status: status) }
    }

    private enum Parsed {
        case incomplete, invalid
        case request(Request)
    }

    /// PDF를 통째로 받으므로 넉넉히 잡는다.
    private static let maxBody = 300 << 20

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ConnectorServer")
    private let handler: (Request, @escaping (Response) -> Void) -> Void

    init(port: UInt16, handler: @escaping (Request, @escaping (Response) -> Void) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.handler = handler
    }

    /// onState는 메인 스레드에서 불린다.
    func start(onState: @escaping (NWListener.State) -> Void) {
        listener.stateUpdateHandler = { state in DispatchQueue.main.async { onState(state) } }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let request):
                handler(request) { self.send($0, on: connection) }
            case .invalid:
                send(.error(400, "Bad request"), on: connection)
            case .incomplete:
                if error != nil || isComplete { connection.cancel() } else { receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict"][response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 << 10 ? .invalid : .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else { return .invalid }
        let start = end.upperBound
        guard data.count - start >= length else { return .incomplete }
        let target = URLComponents(string: String(requestLine[1]))
        let query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        return .request(Request(method: String(requestLine[0]), path: target?.path ?? "/", query: query, headers: headers,
                                body: data.subdata(in: start..<start + length)))
    }
}
