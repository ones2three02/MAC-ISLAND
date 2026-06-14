import Foundation
import Network

final class MessageWebhookServer: @unchecked Sendable {
    private let port: UInt16
    private let onMessageReceived: @Sendable (String, String, AppMessage.MessageAppType) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.openisland.message.webhook")

    init(port: UInt16, onMessageReceived: @escaping @Sendable (String, String, AppMessage.MessageAppType) -> Void) {
        self.port = port
        self.onMessageReceived = onMessageReceived
        
        let parameters = NWParameters.tcp
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else {
            fatalError("Could not create NWListener")
        }
        self.listener = listener
    }

    func start() throws {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Message Webhook Server ready on port \(self.port)")
            case .failed(let error):
                print("Message Webhook Server failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.processRequest(data: data, connection: connection)
            }
            if error != nil || isComplete {
                connection.cancel()
            } else {
                // 请求不完整时，继续接收 data
                self.receiveData(on: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection, statusCode: 400, body: #"{"error":"Invalid encoding"}"#)
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, firstLine.contains("POST") && (firstLine.contains("/api/message") || firstLine.contains("/api/messages")) else {
            sendResponse(connection, statusCode: 404, body: #"{"error":"Not Found"}"#)
            return
        }

        let parts = requestString.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else {
            sendResponse(connection, statusCode: 400, body: #"{"error":"Bad Request - Missing Body"}"#)
            return
        }
        
        let bodyString = parts[1]
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection, statusCode: 400, body: #"{"error":"Invalid body encoding"}"#)
            return
        }

        struct WebhookMessagePayload: Decodable {
            let sender: String
            let content: String
            let source: String?
        }

        do {
            let payload = try JSONDecoder().decode(WebhookMessagePayload.self, from: bodyData)
            let appType: AppMessage.MessageAppType
            switch payload.source?.lowercased() {
            case "wechat", "wx":
                appType = .wechat
            case "lark", "feishu", "fs":
                appType = .lark
            case "slack":
                appType = .slack
            default:
                appType = .system
            }

            self.onMessageReceived(payload.sender, payload.content, appType)
            sendResponse(connection, statusCode: 200, body: #"{"status":"success"}"#)
        } catch {
            sendResponse(connection, statusCode: 400, body: #"{"error":"JSON decoding failed: \#(error.localizedDescription)"}"#)
        }
    }

    private func sendResponse(_ connection: NWConnection, statusCode: Int, body: String) {
        let statusPhrase = statusCode == 200 ? "OK" : (statusCode == 400 ? "Bad Request" : (statusCode == 404 ? "Not Found" : "Internal Server Error"))
        let responseString = """
        HTTP/1.1 \(statusCode) \(statusPhrase)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """
        
        if let responseData = responseString.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        } else {
            connection.cancel()
        }
    }
}
