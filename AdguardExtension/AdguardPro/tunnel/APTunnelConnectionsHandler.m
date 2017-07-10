/**
    This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
    Copyright © 2015-2016 Performix LLC. All rights reserved.
 
    Adguard for iOS is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
 
    Adguard for iOS is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
 
    You should have received a copy of the GNU General Public License
    along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "ACommons/ACLang.h"
#import "ACommons/ACSystem.h"
#import "APTUdpProxySession.h"
#import "APTunnelConnectionsHandler.h"
#import "PacketTunnelProvider.h"
#import "APUDPPacket.h"
#include <netinet/ip.h>
#import <sys/socket.h>

#import "APDnsResourceType.h"
#import "APDnsRequest.h"
#import "APDnsDatagram.h"
#import "APSharedResources.h"
#import "AERDomainFilter.h"

#define DEFAULT_DNS_SERVER_IP           @"208.67.222.222" // opendns.com

/////////////////////////////////////////////////////////////////////
#pragma mark - APTunnelConnectionsHandler

@implementation APTunnelConnectionsHandler {

    NSMutableSet<APTUdpProxySession *> *_sessions;
    
    BOOL _loggingEnabled;
    
    OSSpinLock _dnsAddressLock;
    OSSpinLock _globalWhitelistLock;
    OSSpinLock _globalBlacklistLock;
    OSSpinLock _userWhitelistLock;
    OSSpinLock _userBlacklistLock;
    
    NSDictionary *_whitelistDnsAddresses;
    NSDictionary *_remoteDnsAddresses;
    
    AERDomainFilter *_globalWhitelist;
    AERDomainFilter *_globalBlacklist;
    
    AERDomainFilter *_userWhitelist;
    AERDomainFilter *_userBlacklist;
    
    BOOL _packetFlowObserver;
    
    dispatch_queue_t _readQueue;
    dispatch_block_t _closeCompletion;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Init and Class methods

- (id)initWithProvider:(PacketTunnelProvider *)provider {

    if (!provider) {
        return nil;
    }

    self = [super init];
    if (self) {

        _provider = provider;
        _sessions = [NSMutableSet set];
        _globalWhitelistLock = _globalBlacklistLock = _userWhitelistLock = _userBlacklistLock = OS_SPINLOCK_INIT;
        _loggingEnabled = NO;
        
        _closeCompletion = nil;
        
        _readQueue = dispatch_queue_create("com.adguard.AdguardPro.tunnel.read", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {

    if (_packetFlowObserver) {
        [_provider removeObserver:self forKeyPath:@"packetFlow"];
    }
}

/////////////////////////////////////////////////////////////////////
#pragma mark Properties and public methods

- (void)setDeviceDnsAddresses:(NSArray<NSString *> *)deviceDnsAddresses
    adguardRemoteDnsAddresses:(NSArray<NSString *> *)remoteDnsAddresses
      adguardFakeDnsAddresses:(NSArray<NSString *> *)fakeDnsAddresses {
    
    DDLogInfo(@"(APTunnelConnectionsHandler) set device DNS addresses:\n%@remote DNS addresses:\n%@Adguard internal DNS addresses:\n%@",
              deviceDnsAddresses, remoteDnsAddresses, fakeDnsAddresses);
    
    @autoreleasepool {
    
        NSMutableDictionary* whiteListDnsDictionary = [NSMutableDictionary dictionary];
    
        NSUInteger deviceDnsIndex = 0;
        
        for(NSString* fakeDns in fakeDnsAddresses) {
            if(deviceDnsAddresses.count) {
                whiteListDnsDictionary[fakeDns] = deviceDnsAddresses[deviceDnsIndex];
                
                ++deviceDnsIndex;
                if(deviceDnsIndex >= deviceDnsAddresses.count)
                    deviceDnsIndex = 0;

            }
            else {
                whiteListDnsDictionary[fakeDns] = DEFAULT_DNS_SERVER_IP;
            }
        }
        
        NSMutableDictionary *remoteDnsDictionary = [NSMutableDictionary dictionary];
        NSUInteger remoteDnsIndex = 0;
        
        for (NSString* fakeDns in fakeDnsAddresses) {
            if(remoteDnsAddresses.count) {
                remoteDnsDictionary[fakeDns] = remoteDnsAddresses[remoteDnsIndex];
                
                ++remoteDnsIndex;
                if(remoteDnsIndex >= remoteDnsAddresses.count)
                    remoteDnsIndex = 0;
            }
            else {
                remoteDnsDictionary[fakeDns] = DEFAULT_DNS_SERVER_IP;
            }
        }
        
        OSSpinLockLock(&_dnsAddressLock);
        
        _whitelistDnsAddresses = [whiteListDnsDictionary copy];
        _remoteDnsAddresses = [remoteDnsDictionary copy];
        
        OSSpinLockUnlock(&_dnsAddressLock);
    }
}

- (void)setGlobalWhitelistFilter:(AERDomainFilter *)filter {
    
    OSSpinLockLock(&_globalWhitelistLock);
        _globalWhitelist = filter;
    OSSpinLockUnlock(&_globalWhitelistLock);
}

- (void)setGlobalBlacklistFilter:(AERDomainFilter *)filter {
    
    OSSpinLockLock(&_globalBlacklistLock);
    _globalBlacklist = filter;
    OSSpinLockUnlock(&_globalBlacklistLock);
}

- (void)setUserWhitelistFilter:(AERDomainFilter *)filter {
    
    OSSpinLockLock(&_userWhitelistLock);
    _userWhitelist = filter;
    OSSpinLockUnlock(&_userWhitelistLock);
}

- (void)setUserBlacklistFilter:(AERDomainFilter *)filter {
    
    OSSpinLockLock(&_userBlacklistLock);
    _userBlacklist = filter;
    OSSpinLockUnlock(&_userBlacklistLock);
}

- (void)startHandlingPackets {

    if (_provider.packetFlow) {

        [self startHandlingPacketsInternal];
    } else {

        DDLogWarn(@"(APTunnelConnectionsHandler) - startHandlingPackets PacketFlow empty!");

        [_provider addObserver:self forKeyPath:@"packetFlow" options:0 context:NULL];
        _packetFlowObserver = YES;
    }
}

- (void)removeSession:(APTUdpProxySession *)session {

    dispatch_block_t closeCompletion = nil;
    @synchronized(self) {

        [_sessions removeObject:session];
        
        if (_closeCompletion && _sessions.count == 0) {
            closeCompletion = _closeCompletion;
            _closeCompletion = nil;
        }
    }
    if (closeCompletion) {
        DDLogInfo(@"(APTunnelConnectionsHandler) closeAllConnections completion will be run.");
        [ACSSystemUtils callOnMainQueue:closeCompletion];
    }
}

- (void)setDnsActivityLoggingEnabled:(BOOL)enabled {

    _loggingEnabled = enabled;
}

- (BOOL)isGlobalWhitelistDomain:(NSString *)domainName {
    
    BOOL result = NO;
    OSSpinLockLock(&_globalWhitelistLock);
    
    result = [_globalWhitelist filteredDomain:domainName];
    
    OSSpinLockUnlock(&_globalWhitelistLock);
    
    return result;
}

- (BOOL)isGlobalBlacklistDomain:(NSString *)domainName {
    
    BOOL result = NO;
    OSSpinLockLock(&_globalBlacklistLock);
    
    result = [_globalBlacklist filteredDomain:domainName];
    
    OSSpinLockUnlock(&_globalBlacklistLock);
    
    return result;
}

- (BOOL)isUserWhitelistDomain:(NSString *)domainName {
    
    BOOL result = NO;
    OSSpinLockLock(&_userWhitelistLock);
    
    result = [_userWhitelist filteredDomain:domainName];
    
    OSSpinLockUnlock(&_userWhitelistLock);
    
    return result;
}

- (BOOL)isUserBlacklistDomain:(NSString *)domainName {
    
    BOOL result = NO;
    OSSpinLockLock(&_userBlacklistLock);
    
    result = [_userBlacklist filteredDomain:domainName];
    
    OSSpinLockUnlock(&_userBlacklistLock);
    
    return result;
}

- (NSString *)whitelistServerAddressForAddress:(NSString *)serverAddress {
    
    if (!serverAddress) {
        serverAddress = [NSString new];
    }
    
    OSSpinLockLock(&_dnsAddressLock);

    NSString *address = _whitelistDnsAddresses[serverAddress];
    
    if (!address) {
        address = DEFAULT_DNS_SERVER_IP;
    }
    
    OSSpinLockUnlock(&_dnsAddressLock);

    return address;
}

- (NSString *)serverAddressForFakeDnsAddress:(NSString *)serverAddress {
    
    if (!serverAddress) {
        serverAddress = [NSString new];
    }
    
    OSSpinLockLock(&_dnsAddressLock);
    
    NSString *address = _remoteDnsAddresses[serverAddress];
    
    if (!address) {
        address = DEFAULT_DNS_SERVER_IP;
    }
    
    OSSpinLockUnlock(&_dnsAddressLock);
    
    return address;
}

- (void)closeAllConnections:(void (^)(void))completion {
    
    @synchronized (self) {
        NSArray <APTUdpProxySession *> *sessions = [_sessions allObjects];
        if(_sessions.count == 0) {
            
            if (completion) {
                DDLogInfo(@"(APTunnelConnectionsHandler) no open sessions. closeAllConnections completion will be run.");
                [ACSSystemUtils callOnMainQueue:completion];
            }
        }
        else {
            
            _closeCompletion = completion;
            
            for (APTUdpProxySession *item in sessions) {
                
                [item close];
            }
        }
        DDLogInfo(@"(APTunnelConnectionsHandler) closeAllConnections method completed.");
    }
}
/////////////////////////////////////////////////////////////////////
#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {

    if ([keyPath isEqual:@"packetFlow"]) {

        DDLogDebug(@"(APTunnelConnectionsHandler) KVO _provider.packetFlow: %@", _provider.packetFlow);
        if (_provider.packetFlow) {

            if (_packetFlowObserver) {
                
                [_provider removeObserver:self forKeyPath:@"packetFlow"];
                _packetFlowObserver = NO;
            }
            [self startHandlingPacketsInternal];
        }
    }
}

/////////////////////////////////////////////////////////////////////
#pragma mark - Helper Methods

- (void)startHandlingPacketsInternal {
    
    __typeof__(self) __weak wSelf = self;

    DDLogDebug(@"(APTunnelConnectionsHandler) startHandlingPacketsInternal");
    
    dispatch_async(_readQueue, ^{
        
        [_provider.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *_Nonnull packets, NSArray<NSNumber *> *_Nonnull protocols) {
            
            __typeof__(self) sSelf = wSelf;
            
#ifdef DEBUG
            [sSelf handlePackets:packets protocols:protocols counter:0];
#else
            [sSelf handlePackets:packets protocols:protocols];
#endif
            
        }];
    });

}

/// Handle packets coming from the packet flow.
#ifdef DEBUG

- (void)handlePackets:(NSArray<NSData *> *_Nonnull)packets protocols:(NSArray<NSNumber *> *_Nonnull)protocols counter:(NSUInteger)packetCounter{
#else
- (void)handlePackets:(NSArray<NSData *> *_Nonnull)packets protocols:(NSArray<NSNumber *> *_Nonnull)protocols {
#endif

    DDLogTrace();

#ifdef DEBUG
    packetCounter++;
#endif
    
    // Work here

    //    DDLogInfo(@"----------- Packets %lu ---------------", packets.count);
    //    [packets enumerateObjectsUsingBlock:^(NSData * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
    //
    //        DDLogInfo(@"Packet %lu length %lu protocol %@", idx, obj.length, protocols[idx]);
    //        NSMutableString *out = [NSMutableString string];
    //        Byte *bytes = (Byte *)[obj bytes];
    //        for (int i = 0; i < obj.length; i++) {
    //
    //            if (i > 0) {
    //                [out appendFormat:@",%d", *(bytes+i)];
    //            }
    //            else{
    //                [out appendFormat:@"%d", *(bytes+i)];
    //            }
    //        }
    //        DDLogInfo(@"Data:\n%@", out);
    //    }];
    //
    //    DDLogInfo(@"---- End Packets -------------");

    NSMutableDictionary *packetsBySessions = [NSMutableDictionary dictionary];
    [packets enumerateObjectsUsingBlock:^(NSData *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {

        APUDPPacket *udpPacket = [[APUDPPacket alloc] initWithData:obj af:protocols[idx]];
        if (udpPacket) {
            //performs only PIv4 UPD packets

            APTUdpProxySession *session = [[APTUdpProxySession alloc] initWithUDPPacket:udpPacket delegate:self];

            if (session) {

                NSMutableArray *packetForSession = packetsBySessions[session];
                if (!packetForSession) {
                    packetForSession = [NSMutableArray new];
                    packetsBySessions[session] = packetForSession;
                }

                [packetForSession addObject:udpPacket.payload];
            }
            
            session = nil;
        }
    }];

    //Create remote endpoint sessions if neeed it and send data to remote endpoint
    [self performSend:packetsBySessions];

#ifdef DEBUG
    DDLogDebug(@"Before readPacketsWithCompletionHandler: %lu", packetCounter);
#endif
    // Read more
    __typeof__(self) __weak wSelf = self;
    
    dispatch_async(_readQueue, ^{
        
        [_provider.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *_Nonnull packets, NSArray<NSNumber *> *_Nonnull protocols) {
            
            __typeof__(self) sSelf = wSelf;
#ifdef DEBUG
            DDLogDebug(@"In readPacketsWithCompletionHandler (before handlePackets): %lu", packetCounter);
            
            [sSelf handlePackets:packets protocols:protocols counter:packetCounter];
#else
            [sSelf handlePackets:packets protocols:protocols];
            
#endif
#ifdef DEBUG
            DDLogDebug(@"In readPacketsWithCompletionHandler (after handlePackets): %lu", packetCounter);
#endif
            
        }];
    });
    
#ifdef DEBUG
    DDLogDebug(@"After readPacketsWithCompletionHandler : %lu", packetCounter);
#endif
}

- (void)performSend:(NSDictionary<APTUdpProxySession *, NSArray *> *)packetsBySessions {

    @synchronized(self) {

        DDLogTrace();
        [packetsBySessions enumerateKeysAndObjectsUsingBlock:^(APTUdpProxySession *_Nonnull key, NSArray *_Nonnull obj, BOOL *_Nonnull stop) {

          APTUdpProxySession *session = [_sessions member:key];
          if (!session) {
              //create session
              session = key;
              if ([session createSession]) {
                  
                  [session setLoggingEnabled:_loggingEnabled];
                  [_sessions addObject:session];
              }
              else
                  session = nil;
          }

          [session appendPackets:obj];
        }];
    }
}

- (BOOL)checkDomain:(__unsafe_unretained NSString *)domainName withList:(__unsafe_unretained NSArray <NSString *> *)domainList {
    
    BOOL result = NO;
    
    for (NSString *item in domainList) {
        
        if ([item hash] == [domainName hash]) {
            if ([domainName isEqualToString:item]) {
                result = YES;
                break;
            }
        }
        
        NSString *domain = [@"." stringByAppendingString:item];
        if ([domainName hasSuffix:domain]) {
            result = YES;
            break;
        }
    }

    return result;
}

@end
