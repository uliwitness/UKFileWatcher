//
//  ULIAppDelegate.h
//  UKFileWatcherDemo
//
//  Created by Uli Kusterer on 2014-02-22.
//  Copyright (c) 2014 Uli Kusterer. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "UKFileWatcher.h"

@interface ULIAppDelegate : NSObject <NSApplicationDelegate,UKFileWatcherDelegate>
{
	NSArray*		filesList;
	NSString*		currFolderPath;
}


@property (assign) IBOutlet NSWindow *window;
@property (weak) IBOutlet NSTableView *filesTable;

@end
