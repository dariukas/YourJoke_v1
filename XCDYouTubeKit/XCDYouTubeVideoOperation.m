//
//  Copyright (c) 2013-2015 Cédric Luthi. All rights reserved.
//

#import "XCDYouTubeVideoOperation.h"

#import <objc/runtime.h>

#import "XCDYouTubeVideo+Private.h"
#import "XCDYouTubeError.h"
#import "XCDYouTubeVideoWebpage.h"
#import "XCDYouTubePlayerScript.h"
#import "XCDYouTubeLogger.h"

typedef NS_ENUM(NSUInteger, XCDYouTubeRequestType) {
	XCDYouTubeRequestTypeGetVideoInfo = 1,
	XCDYouTubeRequestTypeWatchPage,
	XCDYouTubeRequestTypeEmbedPage,
	XCDYouTubeRequestTypeJavaScriptPlayer,
};

@interface XCDYouTubeVideoOperation ()
@property (atomic, copy, readonly) NSString *videoIdentifier;
@property (atomic, copy, readonly) NSString *languageIdentifier;

@property (atomic, assign) NSInteger requestCount;
@property (atomic, assign) XCDYouTubeRequestType requestType;
@property (atomic, strong) NSMutableArray *eventLabels;
@property (atomic, readonly) NSURLSession *session;
@property (atomic, strong) NSURLSessionDataTask *dataTask;

@property (atomic, assign) BOOL isExecuting;
@property (atomic, assign) BOOL isFinished;
@property (atomic, readonly) dispatch_semaphore_t operationStartSemaphore;

@property (atomic, strong) XCDYouTubeVideoWebpage *webpage;
@property (atomic, strong) XCDYouTubeVideoWebpage *embedWebpage;
@property (atomic, strong) XCDYouTubePlayerScript *playerScript;
@property (atomic, strong) XCDYouTubeVideo *noStreamVideo;
@property (atomic, strong) NSError *lastError;
@property (atomic, strong) NSError *youTubeError; // Error actually coming from the YouTube API, i.e. explicit and localized error

@property (atomic, strong, readwrite) NSError *error;
@property (atomic, strong, readwrite) XCDYouTubeVideo *video;
@end

@implementation XCDYouTubeVideoOperation

- (instancetype) init
{
	@throw [NSException exceptionWithName:NSGenericException reason:@"Use the `initWithVideoIdentifier:languageIdentifier:` method instead." userInfo:nil];
} // LCOV_EXCL_LINE

- (instancetype) initWithVideoIdentifier:(NSString *)videoIdentifier languageIdentifier:(NSString *)languageIdentifier
{
	if (!(self = [super init]))
		return nil; // LCOV_EXCL_LINE
	
	_videoIdentifier = videoIdentifier ?: @"";
	_languageIdentifier = languageIdentifier ?: @"en";
	
	_session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
	
	_operationStartSemaphore = dispatch_semaphore_create(0);
	
	return self;
}

#pragma mark - Requests

- (void) startNextRequest
{
	if (self.eventLabels.count == 0)
	{
		if (self.requestType == XCDYouTubeRequestTypeWatchPage || self.webpage)
			[self finishWithError];
		else
			[self startWatchPageRequest];
	}
	else
	{
		NSString *eventLabel = [self.eventLabels objectAtIndex:0];
		[self.eventLabels removeObjectAtIndex:0];
		
		NSDictionary *query = @{ @"video_id": self.videoIdentifier, @"hl": self.languageIdentifier, @"el": eventLabel, @"ps": @"default" };
		NSString *queryString = XCDQueryStringWithDictionary(query);
		NSURL *videoInfoURL = [NSURL URLWithString:[@"https://www.youtube.com/get_video_info?" stringByAppendingString:queryString]];
		[self startRequestWithURL:videoInfoURL type:XCDYouTubeRequestTypeGetVideoInfo];
	}
}

- (void) startWatchPageRequest
{
	NSDictionary *query = @{ @"v": self.videoIdentifier, @"hl": self.languageIdentifier, @"has_verified": @YES };
	NSString *queryString = XCDQueryStringWithDictionary(query);
	NSURL *webpageURL = [NSURL URLWithString:[@"https://www.youtube.com/watch?" stringByAppendingString:queryString]];
	[self startRequestWithURL:webpageURL type:XCDYouTubeRequestTypeWatchPage];
}

- (void) startRequestWithURL:(NSURL *)url type:(XCDYouTubeRequestType)requestType
{
	if (self.isCancelled)
		return;
	
	// Max (age-restricted VEVO) = 2×GetVideoInfo + 1×WatchPage + 1×EmbedPage + 1×JavaScriptPlayer + 1×GetVideoInfo
	if (++self.requestCount > 6)
	{
		// This condition should never happen but the request flow is quite complex so better abort here than go into an infinite loop of requests
		[self finishWithError];
		return;
	}
	
	XCDYouTubeLogDebug(@"Starting request: %@", url);
	
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
	[request setValue:self.languageIdentifier forHTTPHeaderField:@"Accept-Language"];
	
	self.dataTask = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
	{
		if (self.isCancelled)
			return;
		
		if (error)
			[self handleConnectionError:error];
		else
			[self handleConnectionSuccessWithData:data response:response requestType:requestType];
	}];
	[self.dataTask resume];
	
	self.requestType = requestType;
}

#pragma mark - Response Dispatch

- (void) handleConnectionSuccessWithData:(NSData *)data response:(NSURLResponse *)response requestType:(XCDYouTubeRequestType)requestType
{
	switch (requestType)
	{
		case XCDYouTubeRequestTypeGetVideoInfo:
		{
			NSString *videoQuery = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
			NSDictionary *info = XCDDictionaryWithQueryString(videoQuery);
			[self handleVideoInfoResponseWithInfo:info response:response];
		}
			break;
		case XCDYouTubeRequestTypeWatchPage:
			[self handleWebPageWithData:data response:response];
			break;
		case XCDYouTubeRequestTypeEmbedPage:
			[self handleEmbedWebPageWithData:data response:response];
			break;
		case XCDYouTubeRequestTypeJavaScriptPlayer:
			[self handleJavaScriptPlayerWithData:data response:response];
			break;
	}
}

- (void) handleConnectionError:(NSError *)connectionError
{
	NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: connectionError.localizedDescription,
	                            NSUnderlyingErrorKey: connectionError };
	self.lastError = [NSError errorWithDomain:XCDYouTubeVideoErrorDomain code:XCDYouTubeErrorNetwork userInfo:userInfo];
	
	[self startNextRequest];
}

#pragma mark - Response Parsing

- (void) handleVideoInfoResponseWithInfo:(NSDictionary *)info response:(NSURLResponse *)response
{
	XCDYouTubeLogDebug(@"Handling video info response");
	XCDYouTubeLogVerbose(@"Video info: %@", info);
	
	NSError *error = nil;
	XCDYouTubeVideo *video = [[XCDYouTubeVideo alloc] initWithIdentifier:self.videoIdentifier info:info playerScript:self.playerScript response:response error:&error];
	if (video)
	{
		[video mergeVideo:self.noStreamVideo];
		[self finishWithVideo:video];
	}
	else
	{
		if ([error.domain isEqual:XCDYouTubeVideoErrorDomain] && error.code == XCDYouTubeErrorUseCipherSignature)
		{
			self.noStreamVideo = error.userInfo[XCDYouTubeNoStreamVideoUserInfoKey];
			
			[self startWatchPageRequest];
		}
		else
		{
			self.lastError = error;
			if (error.code > 0)
				self.youTubeError = error;
			
			[self startNextRequest];
		}
	}
}

- (void) handleWebPageWithData:(NSData *)data response:(NSURLResponse *)response
{
	XCDYouTubeLogDebug(@"Handling web page response");
	
	self.webpage = [[XCDYouTubeVideoWebpage alloc] initWithData:data response:response];
	
	if (self.webpage.javaScriptPlayerURL)
	{
		[self startRequestWithURL:self.webpage.javaScriptPlayerURL type:XCDYouTubeRequestTypeJavaScriptPlayer];
	}
	else
	{
		if (self.webpage.isAgeRestricted)
		{
			NSString *embedURLString = [NSString stringWithFormat:@"https://www.youtube.com/embed/%@", self.videoIdentifier];
			[self startRequestWithURL:[NSURL URLWithString:embedURLString] type:XCDYouTubeRequestTypeEmbedPage];
		}
		else
		{
			[self startNextRequest];
		}
	}
}

- (void) handleEmbedWebPageWithData:(NSData *)data response:(NSURLResponse *)response
{
	XCDYouTubeLogDebug(@"Handling embed web page response");
	
	self.embedWebpage = [[XCDYouTubeVideoWebpage alloc] initWithData:data response:response];
	
	if (self.embedWebpage.javaScriptPlayerURL)
	{
		[self startRequestWithURL:self.embedWebpage.javaScriptPlayerURL type:XCDYouTubeRequestTypeJavaScriptPlayer];
	}
	else
	{
		[self startNextRequest];
	}
}

- (void) handleJavaScriptPlayerWithData:(NSData *)data response:(NSURLResponse *)response
{
	XCDYouTubeLogDebug(@"Handling JavaScript player response");
	
	NSString *script = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
	self.playerScript = [[XCDYouTubePlayerScript alloc] initWithString:script];
	
	if (self.webpage.isAgeRestricted)
	{
		NSString *eurl = [@"https://youtube.googleapis.com/v/" stringByAppendingString:self.videoIdentifier];
		NSString *sts = [self.embedWebpage.playerConfiguration[@"sts"] description] ?: [self.webpage.playerConfiguration[@"sts"] description] ?: @"";
		NSDictionary *query = @{ @"video_id": self.videoIdentifier, @"hl": self.languageIdentifier, @"eurl": eurl, @"sts": sts};
		NSString *queryString = XCDQueryStringWithDictionary(query);
		NSURL *videoInfoURL = [NSURL URLWithString:[@"https://www.youtube.com/get_video_info?" stringByAppendingString:queryString]];
		[self startRequestWithURL:videoInfoURL type:XCDYouTubeRequestTypeGetVideoInfo];
	}
	else
	{
		[self handleVideoInfoResponseWithInfo:self.webpage.videoInfo response:response];
	}
}

#pragma mark - Finish Operation

- (void) finishWithVideo:(XCDYouTubeVideo *)video
{
	self.video = video;
	XCDYouTubeLogInfo(@"Video operation finished with success: %@", video);
	XCDYouTubeLogDebug(@"%@", video.debugDescription);
	[self finish];
}

- (void) finishWithError
{
	self.error = self.youTubeError ?: self.lastError;
	XCDYouTubeLogError(@"Video operation finished with error: %@\nDomain: %@\nCode:   %@\nUser Info: %@", self.error.localizedDescription, self.error.domain, @(self.error.code), self.error.userInfo);
	[self finish];
}

- (void) finish
{
	self.isExecuting = NO;
	self.isFinished = YES;
}

#pragma mark - NSOperation

+ (BOOL) automaticallyNotifiesObserversForKey:(NSString *)key
{
	SEL selector = NSSelectorFromString(key);
	return selector == @selector(isExecuting) || selector == @selector(isFinished) || [super automaticallyNotifiesObserversForKey:key];
}

- (BOOL) isConcurrent
{
	return YES;
}

- (void) start
{
	dispatch_semaphore_signal(self.operationStartSemaphore);
	
	if (self.isCancelled)
		return;
	
	if (self.videoIdentifier.length != 11)
	{
		XCDYouTubeLogWarning(@"Video identifier length should be 11. [%@]", self.videoIdentifier);
	}
	
	XCDYouTubeLogInfo(@"Starting video operation: %@", self);
	
	self.isExecuting = YES;
	
	self.eventLabels = [[NSMutableArray alloc] initWithArray:@[ @"embedded", @"detailpage" ]];
	[self startNextRequest];
}

- (void) cancel
{
	if (self.isCancelled || self.isFinished)
		return;
	
	XCDYouTubeLogInfo(@"Canceling video operation: %@", self);
	
	[super cancel];
	
	[self.dataTask cancel];
	
	// Wait for `start` to be called in order to avoid this warning: *** XCDYouTubeVideoOperation 0x7f8b18c84880 went isFinished=YES without being started by the queue it is in
	dispatch_semaphore_wait(self.operationStartSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
	[self finish];
}

#pragma mark - NSObject

- (NSString *) description
{
	return [NSString stringWithFormat:@"<%@: %p> %@ (%@)", self.class, self, self.videoIdentifier, self.languageIdentifier];
}

@end
