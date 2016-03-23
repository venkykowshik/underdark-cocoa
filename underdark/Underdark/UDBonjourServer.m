/*
 * Copyright (c) 2016 Vladimir L. Shabanov <virlof@gmail.com>
 *
 * Licensed under the Underdark License, Version 1.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://underdark.io/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "UDBonjourServer.h"

#import "UDLogging.h"
#import "UDBonjourChannel.h"
#import "UDAsyncUtils.h"

typedef NS_ENUM(NSUInteger, UDBnjServerState) {
	UDBnjServerStateStopped,
	UDBnjServerStateStarting,
	UDBnjServerStateRunning,
	UDBnjServerStateStopping
};

@interface UDBonjourServer() <NSNetServiceDelegate>
{
	UDBnjServerState _state;
	UDBnjServerState _desiredState;

	NSNetService* _service;
	
}

@property (nonatomic, readonly, weak, nullable) UDBonjourAdapter* adapter;

@end

@implementation UDBonjourServer

- (nullable instancetype) init
{
	return nil;
}

- (nonnull instancetype) initWithAdapter:(nonnull UDBonjourAdapter*)adapter
{
	if(!(self = [super init]))
		return self;
	
	_adapter = adapter;
	_state = UDBnjServerStateStopped;
	_desiredState = UDBnjServerStateStopped;
	
	return self;
}

- (void) checkDesiredState
{
	// Adapter queue.
	if(_desiredState == UDBnjServerStateRunning && _state == UDBnjServerStateStopped)
	{
		[self start];
	}
	else if(_desiredState == UDBnjServerStateStopped && _state == UDBnjServerStateRunning)
	{
		[self stop];
	}
}

- (void) start
{
	// Adapter queue.
	
	_desiredState = UDBnjServerStateRunning;
	
	if(_state != UDBnjServerStateStopped)
		return;
	
	_state = UDBnjServerStateStarting;
	
	[self performSelector:@selector(startImpl) onThread:_adapter.ioThread withObject:nil waitUntilDone:YES];
}

- (void) startImpl
{
	// Service thread.
	
	_service = [[NSNetService alloc] initWithDomain:@"" type:_adapter.serviceType name:@(_adapter.nodeId).description port:0];
	if(!_service)
	{
		LogError(@"NSNetService init() == nil");
		
		sldispatch_async(_adapter.queue, ^{
			_state = UDBnjServerStateStopped;
			_desiredState = UDBnjServerStateStopped;
			[_adapter serverDidFail];
		});
		return;
	}
	
	_service.includesPeerToPeer = _adapter.peerToPeer;
	_service.delegate = self;
	//[_service scheduleInRunLoop:_adapter.ioThread.runLoop forMode:NSDefaultRunLoopMode];
	//[_service startMonitoring];
	
	[_service publishWithOptions:NSNetServiceListenForConnections];
}

- (void) stop
{
	// Adapter queue.

	_desiredState = UDBnjServerStateStopped;
	
	if(_state != UDBnjServerStateRunning)
		return;
	
	_state = UDBnjServerStateStopping;
	
	[self performSelector:@selector(stopImpl) onThread:_adapter.ioThread withObject:nil waitUntilDone:YES];
}

- (void) stopImpl
{
	// Service thread.
	
	//[_service stopMonitoring];
	
	[_service stop];
	
	//[_service removeFromRunLoop:_adapter.ioThread.runLoop forMode:NSDefaultRunLoopMode];
	//_service.delegate = nil;
	//_service = nil;
}

- (void) restart
{	
	[self stop];
	[self start];
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidStop:(NSNetService *)sender
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	LogDebug(@"bnj netServiceDidStop");
	
	_service = nil;

	sldispatch_async(_adapter.queue, ^{
		_state = UDBnjServerStateStopped;
		[self checkDesiredState];
	});
}

- (void)netService:(NSNetService *)sender didUpdateTXTRecordData:(NSData *)data
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	LogDebug(@"bnj didUpdateTXTRecordData");
	
	//[_service publishWithOptions:NSNetServiceListenForConnections];
}

- (void)netService:(NSNetService *)sender didAcceptConnectionWithInputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	//LogDebug(@"bnj didAcceptConnection");
	
	sldispatch_async(_adapter.queue, ^{
		UDBonjourChannel* channel = [[UDBonjourChannel alloc] initWithAdapter:_adapter input:inputStream output:outputStream];
		[_adapter channelConnecting:channel];
		
		[channel connect];
	});
}

- (void)netServiceWillPublish:(NSNetService *)sender
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	//LogDebug(@"bnj netServiceWillPublish");
}

- (void)netServiceDidPublish:(NSNetService *)sender
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	LogDebug(@"bnj netServiceDidPublish");
	
	sldispatch_async(_adapter.queue, ^{
		_state = UDBnjServerStateRunning;
		[self checkDesiredState];
	});
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict
{
	// I/O thread.
	
	if(sender != _service)
		return;
	
	LogDebug(@"bnj netServiceDidNotPublish %@", errorDict[NSNetServicesErrorCode]);
	
	_service = nil;
	
	sldispatch_async(_adapter.queue, ^{
		_state = UDBnjServerStateStopped;
		_desiredState = UDBnjServerStateStopped;
		[_adapter serverDidFail];
	});
}

@end
