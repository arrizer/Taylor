//
//  Socket.swift
//  Taylor
//
//  Created by Jorge Izquierdo on 9/14/15.
//  Copyright © 2015 Jorge Izquierdo. All rights reserved.
//

typealias ReceivedRequestCallback = ((Request, Socket) -> Bool)

enum SocketErrors: ErrorType {
    case ListenError
    case PortUsedError
}

protocol SocketServer {

    func startOnPort(p: Int) throws
    func disconnect()
    
    var receivedRequestCallback: ReceivedRequestCallback? { get set }
}

protocol Socket {
    func sendData(data: NSData)
}

// Mark: SwiftSocket Implementation of the Socket and SocketServer protocol


import SwiftSockets
import Dispatch
import Foundation


private struct SwiftSocket: Socket, Hashable {
    
    private enum State: Int {
        case ReceivingHeaders
        case ReceivingBody
        case PendingResponse
    }
    
    let socket: ActiveSocketIPv4
    let UUID = NSUUID()
    
    private var state: State = .ReceivingHeaders
    private unowned var server: SwiftSocketServer
    private var headerData: NSMutableData!
    private var pendingRequest: Request!
    private var bodyLength: UInt = 0
    
    init(socket: ActiveSocketIPv4, server: SwiftSocketServer) {
        
        self.server = server
        self.socket = socket
        
        socket.onRead { nsocket, length in
            let (size, bytes, error) = nsocket.read()
            
            if error == 0 && size > 0 {
                let data = NSData(bytes: bytes, length: size)
                self.receiveData(data)
            }
        }
        
        socket.onClose { _ in
            self.server.socketIsDone(self)
        }
    }
    
    private mutating func receiveData(data: NSData) {
        switch state {
        case .ReceivingHeaders:
            if headerData == nil {
                headerData = NSMutableData()
            }
            headerData.appendData(data)
            
            let string = String(data: headerData, encoding: NSASCIIStringEncoding)!
            if string.containsString("\r\n\r\n") {
                // Headers contain a blank line, headers are complete
                let request = Request(headerData: headerData)
                pendingRequest = request
                if let contentLength = request.headers["Content-Length"],
                    let bodyLength = UInt(contentLength)
                    where (request.method == .POST || request.method == .PUT) && bodyLength > 0 {
                    // The request has a body
                    self.bodyLength = bodyLength
                    if let bodyData = request.bodyData where UInt(bodyData.length) >= bodyLength {
                        // The body is already complete
                        receivedRequest()
                    } else {
                        // Wait for additional segments until the body is complete
                        state = .ReceivingBody
                    }
                } else {
                    // No body expected, so we are done
                    receivedRequest()
                }
            }
        case .ReceivingBody:
            pendingRequest.parseBodyData(data)
            if UInt(pendingRequest.bodyData!.length) >= bodyLength {
                receivedRequest()
            }
        default:
            break
        }
    }
    
    private mutating func receivedRequest() {
        headerData = nil
        state = .PendingResponse
        if let request = self.pendingRequest {
            server.receivedRequestCallback?(request, self)
            pendingRequest = nil
        }
    }
    
    func sendData(data: NSData) {
        if state == .PendingResponse {
            socket.write(dispatch_data_create(data.bytes, data.length, dispatch_get_main_queue(), nil))
            socket.close()
            server.socketIsDone(self)
        }
    }
    
    var hashValue: Int {
        return UUID.hashValue
    }
}

private func ==(lhs: SwiftSocket, rhs: SwiftSocket) -> Bool {
    return lhs.hashValue == rhs.hashValue
}

func synchronize(lock: AnyObject, @noescape closure: () -> Void) {
    objc_sync_enter(lock)
    defer { objc_sync_exit(lock) }
    closure()
}

class SwiftSocketServer: SocketServer {
    
    var socket: PassiveSocketIPv4!
    var receivedRequestCallback: ReceivedRequestCallback?
    private var activeSockets = Set<SwiftSocket>()
    private let queue = dispatch_queue_create("TaylorSocketServerQueue", DISPATCH_QUEUE_CONCURRENT)
    
    func startOnPort(p: Int) throws {
        
        guard let socket = PassiveSocketIPv4(address: sockaddr_in(port: p)) else { throw SocketErrors.ListenError }
        
        socket.listen(queue, backlog: 100) {
            socket in
            
            socket.isNonBlocking = true
            
            let connection = SwiftSocket(socket: socket, server: self)
            synchronize(self) {
                self.activeSockets.insert(connection)
            }
        }
        
        self.socket = socket
    }
    
    private func socketIsDone(socket: SwiftSocket) {
        synchronize(self) {
            self.activeSockets.remove(socket)
        }
    }
    
    func disconnect() {
        self.socket.close()
    }
}
