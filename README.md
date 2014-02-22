What is it
----------

A collection of interchangeable classes that notify you when a given file or folder
changes. You can register for notifications, or register as a delegate.


What is what
------------

UKKQueue - Uses the Unix kqueue mechanism in the background. This gives the most immediate
change notifications, whether your application is in the foreground or background.
However, it also is the most low-level and requires your application to be running or it
will miss changes. Also, as safe-saves in modern Cocoa apps generally work by writing
to a new file, then deleting the old file and giving the new one the original's name, it
may report files as deleted that have just been saved, forcing you to unregister and
re-register for change notifications.

UKFSEventsWatcher - Uses FSEvents under the hood. This is the same mechanism as Spotlight
and Time Machine use. It can remember changes across restarts, but will sometimes report
a large number of changes in the same folder as a vague "something in this folder
changed". It is geared towards watching when folder contents change, but that luckily
includes changes to those files' contents.

UKFNSubscribeFileWatcher - This is the mechanism the Finder used for a long time. It is
the least resource-intensive as it coalesces updates that happen while your application is
in the background, or repeated updates to the same file. It was deprecated in Mac OS X
10.8. 

UKFileWatcher - A protocol that all the above classes conform to, allowing you to try
each of them out easily and pick the one you like most.


License
-------

	Copyright 2003-2014 by Uli Kusterer.
	
	This software is provided 'as-is', without any express or implied
	warranty. In no event will the authors be held liable for any damages
	arising from the use of this software.
	
	Permission is granted to anyone to use this software for any purpose,
	including commercial applications, and to alter it and redistribute it
	freely, subject to the following restrictions:
	
	   1. The origin of this software must not be misrepresented; you must not
	   claim that you wrote the original software. If you use this software
	   in a product, an acknowledgment in the product documentation would be
	   appreciated but is not required.
	
	   2. Altered source versions must be plainly marked as such, and must not be
	   misrepresented as being the original software.
	
	   3. This notice may not be removed or altered from any source
	   distribution.
