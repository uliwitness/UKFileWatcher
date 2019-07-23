//
//	UKKQueue.m
//	Filie
//
//	Created by Uli Kusterer on 21.12.2003
//	Copyright 2003 Uli Kusterer.
//
//	This software is provided 'as-is', without any express or implied
//	warranty. In no event will the authors be held liable for any damages
//	arising from the use of this software.
//
//	Permission is granted to anyone to use this software for any purpose,
//	including commercial applications, and to alter it and redistribute it
//	freely, subject to the following restrictions:
//
//	   1. The origin of this software must not be misrepresented; you must not
//	   claim that you wrote the original software. If you use this software
//	   in a product, an acknowledgment in the product documentation would be
//	   appreciated but is not required.
//
//	   2. Altered source versions must be plainly marked as such, and must not be
//	   misrepresented as being the original software.
//
//	   3. This notice may not be removed or altered from any source
//	   distribution.
//

#if !__has_feature(objc_arc)
#error This file requires ARC to compile.
#endif

// -----------------------------------------------------------------------------
//  Headers:
// -----------------------------------------------------------------------------

#import "UKKQueue.h"
#import <unistd.h>
#import <fcntl.h>
#include <sys/stat.h>

#if UKKQ_NOTIFY_NSWORKSPACE_CENTER
#import <Cocoa/Cocoa.h>
#endif

// -----------------------------------------------------------------------------
//  Macros:
// -----------------------------------------------------------------------------

#define DEBUG_LOG_THREAD_LIFETIME		0
#define DEBUG_DETAILED_MESSAGES			0
#if DEBUG && 0
#define DEBUG_LOG_UKKQ(args...)				NSLog(args)
#else
#define DEBUG_LOG_UKKQ(...)                 while(0)
#endif


// -----------------------------------------------------------------------------
//  Helper class:
// -----------------------------------------------------------------------------

@interface UKKQueuePathEntry : NSObject
{
	NSString*		path;
	int				watchedFD;
	u_int			subscriptionFlags;
	int				pathRefCount;
}

-(id)	initWithPath: (NSString*)inPath flags: (u_int)fflags;

-(void)			retainPath;
-(BOOL)			releasePath;

-(NSString*)	path;
-(int)			watchedFD;

-(u_int)		subscriptionFlags;
-(void)			setSubscriptionFlags: (u_int)fflags;

@end

@implementation UKKQueuePathEntry

-(id)	initWithPath: (NSString*)inPath flags: (u_int)fflags;
{
	if(( self = [super init] ))
	{
		path = [inPath copy];
		watchedFD = open( [path fileSystemRepresentation], O_EVTONLY, 0 );
		if( watchedFD < 0 )
		{
			return nil;
		}
		subscriptionFlags = fflags;
		pathRefCount = 1;
	}
	
	return self;
}

-(void)	dealloc
{
	path = nil;
	if( watchedFD >= 0 )
		close(watchedFD);
	watchedFD = -1;
	pathRefCount = 0;
}

-(void)	retainPath
{
	@synchronized( self )
	{
		pathRefCount++;
	}
}

-(BOOL)	releasePath
{
	@synchronized( self )
	{
		pathRefCount--;
		
		return (pathRefCount == 0);
	}
	
	return NO;
}

-(NSString*)	path
{
	return path;
}

-(int)	watchedFD
{
	return watchedFD;
}

-(u_int)	subscriptionFlags
{
	return subscriptionFlags;
}

-(void)	setSubscriptionFlags: (u_int)fflags
{
	subscriptionFlags = fflags;
}


@end



// -----------------------------------------------------------------------------
//  Private stuff:
// -----------------------------------------------------------------------------

@interface UKKQueueCentral : NSObject
{
	int						queueFD;				// The actual queue ID (Unix file descriptor).
	NSMutableDictionary*	watchedFiles;			// List of UKKQueuePathEntries.
	BOOL					keepThreadRunning;
	NSMutableSet*			entriesPendingRelease;
}

-(int)		queueFD;				// I know you unix geeks want this...

// UKFileWatcher protocol methods:
-(void)		addPath: (NSString*)path;
-(void)		addPath: (NSString*)path notifyingAbout: (u_int)fflags;
-(void)		removePath: (NSString*)path;
-(void)		removeAllPaths;

// Main bottleneck for subscribing:
-(UKKQueuePathEntry*)	addPathToQueue: (NSString*)path notifyingAbout: (u_int)fflags;

// Actual work is done here:
-(void)		watcherThread: (id)sender;
-(void)		postNotification: (NSString*)nm forFile: (NSString*)fp; // Message-posting bottleneck.

@end


// -----------------------------------------------------------------------------
//  Globals:
// -----------------------------------------------------------------------------

static UKKQueueCentral	*	gUKKQueueSharedQueueSingleton = nil;


@implementation UKKQueueCentral

// -----------------------------------------------------------------------------
//	* CONSTRUCTOR:
//		Creates a new KQueue and starts that thread we use for our
//		notifications.
// -----------------------------------------------------------------------------

-(id)   init
{
	self = [super init];
	if( self )
	{
		queueFD = kqueue();
		if( queueFD == -1 )
		{
			return nil;
		}
		
		watchedFiles = [[NSMutableDictionary alloc] init];
		entriesPendingRelease = [[NSMutableSet alloc] init];
	}
	
	return self;
}


// -----------------------------------------------------------------------------
//	* DESTRUCTOR:
//		Releases the kqueue again.
// -----------------------------------------------------------------------------

-(void) dealloc
{
	keepThreadRunning = NO;
	
	// Close all our file descriptors so the files can be deleted:
	[self removeAllPaths];
	
	watchedFiles = nil;
	entriesPendingRelease = nil;
}


// -----------------------------------------------------------------------------
//	removeAllPaths:
//		Stop listening for changes to all paths. This removes all
//		notifications.
// -----------------------------------------------------------------------------

-(void)	removeAllPaths
{
	@synchronized( self )
    {
		[watchedFiles removeAllObjects];
	}
}


// -----------------------------------------------------------------------------
//	queueFD:
//		Returns a Unix file descriptor for the KQueue this uses. The descriptor
//		is owned by this object. Do not close it!
// -----------------------------------------------------------------------------

-(int)  queueFD
{
	return queueFD;
}

-(void) addPath: (NSString*)path
{
	[self addPath: path notifyingAbout: UKKQueueNotifyDefault];
}


-(void) addPath: (NSString*)path notifyingAbout: (u_int)fflags
{
	[self addPathToQueue: path notifyingAbout: fflags];
}

-(UKKQueuePathEntry*)	addPathToQueue: (NSString*)path notifyingAbout: (u_int)fflags
{
	@synchronized( self )
	{
		UKKQueuePathEntry*	pe = [watchedFiles objectForKey: path];	// Already watching this path?
		if( pe )
		{
			[pe retainPath];	// Just add another subscription to this entry.
			
			if( ([pe subscriptionFlags] & fflags) == fflags )	// All flags already set?
				return pe;
			
			fflags |= [pe subscriptionFlags];
		}
		
		struct timespec		nullts = { 0, 0 };
		struct kevent		ev;
		
		if( !pe )
			pe = [[UKKQueuePathEntry alloc] initWithPath: path flags: fflags];
		
		if( pe )
		{
			EV_SET( &ev, [pe watchedFD], EVFILT_VNODE,
					EV_ADD | EV_ENABLE | EV_CLEAR,
					fflags, 0, (__bridge void *) pe );
			
			[pe setSubscriptionFlags: fflags];
            [watchedFiles setObject: pe forKey: path];
            kevent( queueFD, &ev, 1, NULL, 0, &nullts );
		
			// Start new thread that fetches and processes our events:
			if( !keepThreadRunning )
			{
				keepThreadRunning = YES;
				[NSThread detachNewThreadSelector:@selector(watcherThread:) toTarget:self withObject:nil];
			}
        }
		return pe;
   }
   
   return nil;
}


// -----------------------------------------------------------------------------
//	removePath:
//		Stop listening for changes to the specified path. Use this to balance
//		both addPath:notfyingAbout: as well as addPath:.
// -----------------------------------------------------------------------------

-(void) removePath: (NSString*)path
{
	@synchronized( self )
	{
		UKKQueuePathEntry*	pe = [watchedFiles objectForKey: path];	// Already watching this path?
		if( pe && [pe releasePath] )	// Give up one subscription. Is this the last subscription?
		{
			[entriesPendingRelease addObject:pe];		// delay release of UKKQueuePathEntry until after all associated kevent messages can be dequeued
			[watchedFiles removeObjectForKey: path];	// Unsubscribe from this file.
		}
	}
}

// -----------------------------------------------------------------------------
//	description:
//		This method can be used to help in debugging. It provides the value
//      used by NSLog & co. when you request to print this object using the
//      %@ format specifier.
// -----------------------------------------------------------------------------

-(NSString*)	descriptionWithLocale: (id)locale indent: (NSUInteger)level
{
	NSMutableString*	mutStr = [NSMutableString string];
	NSUInteger			x = 0;
	
	for( x = 0; x < level; x++ )
		[mutStr appendString: @"    "];
	[mutStr appendString: NSStringFromClass([self class])];
	for( x = 0; x < level; x++ )
		[mutStr appendString: @"    "];
	[mutStr appendString: @"{"];
	for( x = 0; x < level; x++ )
		[mutStr appendString: @"    "];
	[mutStr appendFormat: @"watchedFiles = %@", [watchedFiles descriptionWithLocale: locale indent: level +1]];
	for( x = 0; x < level; x++ )
		[mutStr appendString: @"    "];
	[mutStr appendString: @"}"];
	
	return mutStr;
}


// -----------------------------------------------------------------------------
//	watcherThread:
//		This method is called by our NSThread to loop and poll for any file
//		changes that our kqueue wants to tell us about. This sends separate
//		notifications for the different kinds of changes that can happen.
//		All messages are sent via the postNotification:forFile: main bottleneck.
//
//      To terminate this method (and its thread), set keepThreadRunning to NO.
// -----------------------------------------------------------------------------

-(void)		watcherThread: (id)sender
{
	int					n;
    struct kevent		ev;
    struct timespec     timeout = { 1, 0 }; // 1 second timeout. Should be longer, but we need this thread to exit when a kqueue is dealloced, so 1 second timeout is quite a while to wait.
	int					theFD = queueFD;	// So we don't have to risk accessing iVars when the thread is terminated.
	NSMutableSet*		removedEntries = entriesPendingRelease;
    
	#if DEBUG_LOG_THREAD_LIFETIME
	DEBUG_LOG_UKKQ(@"watcherThread started.");
	#endif
	
	while( keepThreadRunning )
	{
		@autoreleasepool
		{
			@try
			{
				n = kevent( queueFD, NULL, 0, &ev, 1, &timeout );
				if( n > 0 )
				{
					DEBUG_LOG_UKKQ( @"KEVENT returned %d", n );
					if( ev.filter == EVFILT_VNODE )
					{
						DEBUG_LOG_UKKQ( @"KEVENT filter is EVFILT_VNODE" );
						if( ev.fflags )
						{
							DEBUG_LOG_UKKQ( @"KEVENT flags are set" );
							UKKQueuePathEntry*	pe = (__bridge UKKQueuePathEntry*)ev.udata;    // In case one of the notified folks removes the path.
							NSString*	fpath = [pe path];
							
							if( (ev.fflags & NOTE_RENAME) == NOTE_RENAME )
								[self postNotification: UKFileWatcherRenameNotification forFile: fpath];
							if( (ev.fflags & NOTE_WRITE) == NOTE_WRITE )
								[self postNotification: UKFileWatcherWriteNotification forFile: fpath];
							if( (ev.fflags & NOTE_DELETE) == NOTE_DELETE )
								[self postNotification: UKFileWatcherDeleteNotification forFile: fpath];
							if( (ev.fflags & NOTE_ATTRIB) == NOTE_ATTRIB )
								[self postNotification: UKFileWatcherAttributeChangeNotification forFile: fpath];
							if( (ev.fflags & NOTE_EXTEND) == NOTE_EXTEND )
								[self postNotification: UKFileWatcherSizeIncreaseNotification forFile: fpath];
							if( (ev.fflags & NOTE_LINK) == NOTE_LINK )
								[self postNotification: UKFileWatcherLinkCountChangeNotification forFile: fpath];
							if( (ev.fflags & NOTE_REVOKE) == NOTE_REVOKE )
								[self postNotification: UKFileWatcherAccessRevocationNotification forFile: fpath];
						}
					}
				}
				else
				{
					// kevent queue has been emptied, can safely release the stashed UKKQueuePathEntry user data
					@synchronized (self)
					{
						[removedEntries removeAllObjects];
					}
				}
			}
			@catch( NSException *localException )
			{
				NSLog(@"Error in UKKQueue watcherThread: %@",localException);
			}
		}
	}
    
	// Close our kqueue's file descriptor:
	if( close( theFD ) == -1 )
		DEBUG_LOG_UKKQ(@"watcherThread: Couldn't close main kqueue (%d)", errno);
   
	#if DEBUG_LOG_THREAD_LIFETIME
	DEBUG_LOG_UKKQ(@"watcherThread finished.");
	#endif
}


// -----------------------------------------------------------------------------
//	postNotification:forFile:
//		This is the main bottleneck for posting notifications.
// -----------------------------------------------------------------------------

-(void) postNotification: (NSString*)nm forFile: (NSString*)fp
{
	#if DEBUG_DETAILED_MESSAGES
	DEBUG_LOG_UKKQ( @"%@: %@", nm, fp );
	#endif
	
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSNotificationCenter.defaultCenter postNotificationName: nm object: self
															userInfo: [NSDictionary dictionaryWithObjectsAndKeys: fp, @"path", nil]];
		
	});
}

@end


@implementation UKKQueue

// -----------------------------------------------------------------------------
//  sharedFileWatcher:
//		Returns a singleton queue object. In many apps (especially those that
//      subscribe to the notifications) there will only be one kqueue instance,
//      and in that case you can use this.
//
//      For all other cases, feel free to create additional instances to use
//      independently.
// -----------------------------------------------------------------------------

+(id) sharedFileWatcher
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		if( !gUKKQueueSharedQueueSingleton )
			gUKKQueueSharedQueueSingleton = [[UKKQueueCentral alloc] init];	// This is a singleton, and thus an intentional "leak".
	});
	
    return gUKKQueueSharedQueueSingleton;
}


-(id)	init
{
	if(( self = [super init] ))
	{
		watchedFiles = [[NSMutableDictionary alloc] init];
		NSNotificationCenter*	nc = [NSNotificationCenter defaultCenter];
		UKKQueueCentral*		kqc = [[self class] sharedFileWatcher];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherRenameNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherWriteNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherDeleteNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherAttributeChangeNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherSizeIncreaseNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherLinkCountChangeNotification object: kqc];
		[nc addObserver: self selector: @selector(fileChangeNotification:)
				name: UKFileWatcherAccessRevocationNotification object: kqc];
	}
	
	return self;
}


-(void)	finalize
{
	[self removeAllPaths];
	
	[super finalize];
}


-(void) dealloc
{
	delegate = nil;
	
	// Close all our file descriptors so the files can be deleted:
	[self removeAllPaths];
	
	watchedFiles = nil;
	
	NSNotificationCenter*	nc = [NSNotificationCenter defaultCenter];
	UKKQueueCentral*		kqc = [[self class] sharedFileWatcher];
	[nc removeObserver: self
			name: UKFileWatcherRenameNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherWriteNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherDeleteNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherAttributeChangeNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherSizeIncreaseNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherLinkCountChangeNotification object: kqc];
	[nc removeObserver: self
			name: UKFileWatcherAccessRevocationNotification object: kqc];
}


-(int)		queueFD
{
	return [[UKKQueue sharedFileWatcher] queueFD];	// We're all one big, happy family now.
}

// -----------------------------------------------------------------------------
//	addPath:
//		Tell this queue to listen for all interesting notifications sent for
//		the object at the specified path. If you want more control, use the
//		addPath:notifyingAbout: variant instead.
// -----------------------------------------------------------------------------

-(void) addPath: (NSString*)path
{
	[self addPath: path notifyingAbout: UKKQueueNotifyDefault];
}


// -----------------------------------------------------------------------------
//	addPath:notfyingAbout:
//		Tell this queue to listen for the specified notifications sent for
//		the object at the specified path.
// -----------------------------------------------------------------------------

-(void) addPath: (NSString*)path notifyingAbout: (u_int)fflags
{
	UKKQueuePathEntry*		entry = [watchedFiles objectForKey: path];
	if( entry )
		return;	// Already have this one.
	
	entry = [[UKKQueue sharedFileWatcher] addPathToQueue: path notifyingAbout: fflags];
	[watchedFiles setObject: entry forKey: path];
}


-(void)	removePath: (NSString*)fpath
{
	UKKQueuePathEntry*		entry = [watchedFiles objectForKey: fpath];
	if( entry )	// Don't have this one, do nothing.
	{
		[watchedFiles removeObjectForKey: fpath];
		[[UKKQueue sharedFileWatcher] removePath: fpath];
	}
}


-(id)	delegate
{
    return delegate;
}


-(void)	setDelegate: (id)newDelegate
{
	delegate = newDelegate;
}


-(BOOL)	alwaysNotify
{
	return alwaysNotify;
}


-(void)	setAlwaysNotify: (BOOL)state
{
	alwaysNotify = state;
}


-(void)	removeAllPaths
{
	NSEnumerator*			enny = [watchedFiles objectEnumerator];
	UKKQueuePathEntry*		entry = nil;
	UKKQueueCentral*		sfw = [UKKQueue sharedFileWatcher];
	
	// Unsubscribe all:
	while(( entry = [enny nextObject] ))
		[sfw removePath: [entry path]];

	[watchedFiles removeAllObjects];	// Empty the list now we don't have any subscriptions anymore.
}


-(void)	fileChangeNotification: (NSNotification*)notif
{
	NSString*	fp = [[notif userInfo] objectForKey: @"path"];
	NSString*	nm = [notif name];
	if( [watchedFiles objectForKey: fp] == nil )	// Don't notify about files we don't care about.
		return;
	[delegate watcher: self receivedNotification: nm forPath: fp];
	if( !delegate || alwaysNotify )
	{
		[[NSNotificationCenter defaultCenter] postNotificationName: nm object: self
												userInfo: [notif userInfo]];	// Send the notification on to *our* clients only.
	}
}

@end


