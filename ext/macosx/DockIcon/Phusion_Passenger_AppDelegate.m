//
//  Phusion_Passenger_AppDelegate.m
//  Phusion Passenger OS X integration
//
//  Created by Ninh Bui on 1/12/10.
//  Copyright 2010 Phusion v.o.f.. All rights reserved.
//

#import "Phusion_Passenger_AppDelegate.h"

#include <crt_externs.h>
#include <sys/select.h>
#include <sys/types.h>
#include <signal.h>

@implementation Phusion_Passenger_AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	// Initialize about window controller singleton
	aboutWindowController = [AboutWindowController sharedInstance];
	
	exitThread = [[NSThread alloc] initWithTarget:self
										 selector:@selector(exitIfFileDescriptorIsReadable:) 
										   object:nil];
	[exitThread start];
}

/**
 * This method is responsible for performing a select system call and wait
 * for the file descriptor that was given to it via the argv[1] to become
 * readable. Due to the blocking nature of select, this method is meant to run
 * in a seperate thread as to not block the Cocoa Event loop.
 *
 * Once this is the case, it will terminate the this application.
 */
- (void)exitIfFileDescriptorIsReadable:(id)arg {
	char **argv = *_NSGetArgv();
	
	int fd   = atoi(argv[PhusionPassengerLiteFD]);
	int nfds = fd + 1;
	
	fd_set fdSet;
	FD_ZERO(&fdSet);
	FD_SET(fd, &fdSet);
	
	select(nfds, &fdSet, NULL, NULL, NULL);
	exit(0);
}

/**
 * Upon termination, this application delegate should send a SIGTERM signal
 * to its Phusion Passenger Lite PID.
 */
- (void)applicationWillTerminate:(NSNotification *)notification {
	// Application will be launched through launchd so getppid() will return
	// that ppid instead of Phusion Passenger Lite PID
	char **argv = *_NSGetArgv();
	pid_t ppid  = atoi(argv[PhusionPassengerLitePID]);
	
	kill(ppid, SIGTERM);
}

- (IBAction)orderFrontAboutWindow:(id)sender {
	[aboutWindowController showWindow:sender];
}

@end
