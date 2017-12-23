/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 This file contains the ClientTunnelConnection class. The ClientTunnelConnection class handles the encapsulation and decapsulation of IP packets in the client side of the SimpleTunnel tunneling protocol.
 */

import NetworkExtension
import SimpleTunnelServices

/// A packet tunnel provider object.
class PacketTunnelProvider: NEPacketTunnelProvider, TunnelDelegate, ClientTunnelConnectionDelegate {
    
    // MARK: Properties
    
    /// A reference to the tunnel object.
    var tunnel: ClientTunnel?
    
    /// The single logical flow of packets through the tunnel.
    var tunnelConnection: ClientTunnelConnection?
    
    /// The completion handler to call when the tunnel is fully established.
    var pendingStartCompletion: ((Error?) -> Void)?
    
    /// The completion handler to call when the tunnel is fully disconnected.
    var pendingStopCompletion: (() -> Void)?
    
    // MARK: NEPacketTunnelProvider
    
    /// Begin the process of establishing the tunnel.
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let newTunnel = ClientTunnel()
        newTunnel.delegate = self
        
        if let error = newTunnel.startTunnel(self) {
            completionHandler(error as Error)
        }
        else {
            // Save the completion handler for when the tunnel is fully established.
            pendingStartCompletion = completionHandler
            tunnel = newTunnel
        }
    }
    
    /// Begin the process of stopping  the tunnel.
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Clear out any pending start completion handler.
        pendingStartCompletion = nil
        
        // Save the completion handler for when the tunnel is fully disconnected.
        pendingStopCompletion = completionHandler
        tunnel?.closeTunnel()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let messageString = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        
        simpleTunnelLog("Got a message from the app: \(messageString)")
        
        let responseData = "Hello app".data(using: .utf8)
        completionHandler?(responseData)
    }
    
    // MARK: TunnelDelegate
    
    /// Handle the event of the tunnel connection being established.
    func tunnelDidOpen(_ targetTunnel: Tunnel) {
        // Open the logical flow of packets through the tunnel.
        let newConnection = ClientTunnelConnection(tunnel: tunnel!, clientPacketFlow: packetFlow, connectionDelegate: self)
        newConnection.open()
        tunnelConnection = newConnection
    }
    
    /// Handle the event of the tunnel connection being closed.
    func tunnelDidClose(_ targetTunnel: Tunnel) {
        if pendingStartCompletion != nil {
            // Closed while starting, call the start completion handler with the appropriate error.
            pendingStartCompletion?(tunnel?.lastError)
            pendingStartCompletion = nil
        }
        else if pendingStopCompletion != nil {
            // Closed as the result of a call to stopTunnel, call the stop completion handler.
            pendingStopCompletion?()
            pendingStopCompletion = nil
        }
        else {
            // Closed as the result of an error on the tunnel connection, cancel the tunnel.
            cancelTunnelWithError(tunnel?.lastError)
        }
        
        tunnel = nil
    }
    
    /// Handle the server sending a configuration.
    func tunnelDidSendConfiguration(_ targetTunnel: Tunnel, configuration: [String : AnyObject]) {
    }
    
    // MARK: ClientTunnelConnectionDelegate
    
    /// Handle the event of logical flow of packets being established through the tunnel.
    func tunnelConnectionDidOpen(_ connection: ClientTunnelConnection, configuration: [String : AnyObject]) {
       
        // Create the virtual interface settings.
        guard let settings = createTunnelSettings(with: configuration) else {
            pendingStartCompletion?(SimpleTunnelError.internalError)
            pendingStartCompletion = nil
            return
        }
        
        // Set the virtual interface settings.
        setTunnelNetworkSettings(settings) { error in
            var startError: Error?
            if let error = error {
                simpleTunnelLog("Failed to set the tunnel network settings: \(error)")
                startError = SimpleTunnelError.badConfiguration
            }
            else {
                // Now we can start reading and writing packets to/from the virtual interface.
                self.tunnelConnection?.startHandlingPackets()
            }
            
            // Now the tunnel is fully established, call the start completion handler.
            self.pendingStartCompletion?(startError)
            self.pendingStartCompletion = nil
        }
    }
    
    /// Handle the event of the logical flow of packets being torn down.
    func tunnelConnectionDidClose(_ connection: ClientTunnelConnection, error: Error?) {
        tunnelConnection = nil
        tunnel?.closeTunnelWithError(error)
    }
    
    /// Create the tunnel network settings to be applied to the virtual interface.
    func createTunnelSettings(with configuration: [String: AnyObject]) -> NEPacketTunnelNetworkSettings? {
        guard let tunnelAddress = tunnel?.remoteHost,
            let address = getValueFromPlist(configuration, keyArray: [.IPv4, .Address]) as? String,
            let netmask = getValueFromPlist(configuration, keyArray: [.IPv4, .Netmask]) as? String
            else { return nil }
        
        let newSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelAddress)
        var fullTunnel = true
        
        newSettings.ipv4Settings = NEIPv4Settings(addresses: [address], subnetMasks: [netmask])
        
        if let routes = getValueFromPlist(configuration, keyArray: [.IPv4, .Routes]) as? [[String: AnyObject]] {
            var includeRoutes = [NEIPv4Route]()
            for route in routes {
                if let netAddress = route[SettingsKey.Address.rawValue] as? String,
                    let netMask = route[SettingsKey.Netmask.rawValue] as? String
                {
                        includeRoutes.append(NEIPv4Route(destinationAddress: netAddress, subnetMask: netMask))
                }
            }
            newSettings.ipv4Settings?.includedRoutes = includeRoutes
            fullTunnel = false
        }
        else {
            // No routes specified, use the default route.
            newSettings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        }
        
        if let DNSDictionary = configuration[SettingsKey.DNS.rawValue] as? [String: AnyObject],
            let DNSServers = DNSDictionary[SettingsKey.Servers.rawValue] as? [String]
        {
            newSettings.dnsSettings = NEDNSSettings(servers: DNSServers)
            if let DNSSearchDomains = DNSDictionary[SettingsKey.SearchDomains.rawValue] as? [String] {
                newSettings.dnsSettings?.searchDomains = DNSSearchDomains
                if !fullTunnel {
                    newSettings.dnsSettings?.matchDomains = DNSSearchDomains
                }
            }
        }
        
        newSettings.tunnelOverheadBytes = 150
        return newSettings
    }
}
