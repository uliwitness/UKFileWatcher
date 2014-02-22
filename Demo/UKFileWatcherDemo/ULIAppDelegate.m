//
//  ULIAppDelegate.m
//  UKFileWatcherDemo
//
//  Created by Uli Kusterer on 2014-02-22.
//  Copyright (c) 2014 Uli Kusterer. All rights reserved.
//

#import "ULIAppDelegate.h"
#import "UKKQueue.h"
#import "UKFSEventsWatcher.h"


static NSObject<UKFileWatcher>*		sCurrFileWatcher = nil;


NSString	*	ULIUseFSEventsNotKQueue = @"ULIUseFSEventsNotKQueue";


@implementation ULIAppDelegate

-(id)	init
{
	self = [super init];
	if( self )
	{
		currFolderPath = [@"~/Downloads" stringByExpandingTildeInPath];
	}
	
	return self;
}

-(void)	applicationDidFinishLaunching: (NSNotification *)aNotification
{
	[self makeFileWatcher];
}


-(void)	setUseFSEventsNotKQueue: (BOOL)inUseFSEvents
{
	[[NSUserDefaults standardUserDefaults] setBool: inUseFSEvents forKey: ULIUseFSEventsNotKQueue];
	[self makeFileWatcher];
}


-(void)	makeFileWatcher
{
	if( sCurrFileWatcher )
	{
		[sCurrFileWatcher removeAllPaths];
		sCurrFileWatcher = nil;
	}
	if( [[NSUserDefaults standardUserDefaults] boolForKey: ULIUseFSEventsNotKQueue] )
		sCurrFileWatcher = [[UKFSEventsWatcher alloc] init];
	else
		sCurrFileWatcher = [[UKKQueue alloc] init];
	[sCurrFileWatcher addPath: currFolderPath];
	
	[sCurrFileWatcher setDelegate: self];
}


-(void) watcher: (id<UKFileWatcher>)kq receivedNotification: (NSString*)nm forPath: (NSString*)fpath
{
	self.filesList = nil;
	[self.filesTable reloadData];
}


-(void)	setFilesList: (NSArray*)inList
{
	filesList = inList;
}


-(NSArray*)	filesList
{
	if( !filesList )
	{
		NSError*	err = nil;
		filesList = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath: currFolderPath error: &err] sortedArrayUsingSelector: @selector(caseInsensitiveCompare:)];
		if( !filesList )
			NSLog(@"Error listing files: %@", err);
	}
	
	return filesList;
}


-(NSInteger)	numberOfRowsInTableView:(NSTableView *)tableView
{
	return self.filesList.count;
}

/* This method is required for the "Cell Based" TableView, and is optional for the "View Based" TableView. If implemented in the latter case, the value will be set to the view at a given row/column if the view responds to -setObjectValue: (such as NSControl and NSTableCellView).
 */
-(id)	tableView: (NSTableView *)tableView objectValueForTableColumn: (NSTableColumn *)tableColumn row: (NSInteger)row
{
	if( [tableColumn.identifier isEqualToString: @"name"] )
		return [self.filesList objectAtIndex: row];
	else
		return [[NSWorkspace sharedWorkspace] iconForFile: [currFolderPath stringByAppendingPathComponent: [self.filesList objectAtIndex: row]]];
}

@end
